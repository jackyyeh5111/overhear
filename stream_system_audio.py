"""Stream macOS system audio to Deepgram live STT.

System audio is captured with ScreenCaptureKit via the small `syscap` Swift helper
(built automatically on first run), so no virtual audio device is needed. The `overhear-ui`
app (another Swift helper) starts sessions from its Home window, shows live captions in a
floating, transparent overlay, and replays saved recordings.

Usage:
    export DEEPGRAM_API_KEY=...
    .venv/bin/python stream_system_audio.py                   # system audio, with the app
    .venv/bin/python stream_system_audio.py --no-overlay      # terminal only, no recording
    .venv/bin/python stream_system_audio.py --list            # list input devices
    .venv/bin/python stream_system_audio.py --device "MacBook Pro Microphone"
"""
import argparse
import asyncio
import glob
import json
import os
import ssl
import subprocess
import sys
from urllib.parse import urlencode

import certifi
import sounddevice as sd
import websockets

from recording import RECORDINGS_DIR, Recording, cleanup_partials

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER_SRC = os.path.join(HERE, "syscap.swift")
HELPER_BIN = os.path.join(HERE, "syscap")
UI_SRCS = sorted(glob.glob(os.path.join(HERE, "ui", "*.swift")))
UI_BIN = os.path.join(HERE, "overhear-ui")
SYSTEM_RATE = 48000
# How long Save/Discard waits for Deepgram to finalize the audio it already heard
DRAIN_TIMEOUT = 3


def build_url(sample_rate: int) -> str:
    # Mirrors the playground settings: model=nova-3, language=en, endpointing=false
    params = {
        "model": "nova-3",
        "language": "en",
        "endpointing": "false",
        "interim_results": "true",
        "smart_format": "true",
        "encoding": "linear16",
        "sample_rate": sample_rate,
        "channels": 1,
    }
    return "wss://api.deepgram.com/v1/listen?" + urlencode(params)


def load_key() -> str | None:
    if key := os.environ.get("DEEPGRAM_API_KEY"):
        return key
    # Fall back to a .env file next to this script (DEEPGRAM_API_KEY=...)
    env_path = os.path.join(HERE, ".env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                name, _, value = line.strip().removeprefix("export ").partition("=")
                if name == "DEEPGRAM_API_KEY" and value:
                    return value.strip("'\"")
    return None


def build_helper(srcs: list[str], binary: str):
    if os.path.exists(binary) and os.path.getmtime(binary) >= max(map(os.path.getmtime, srcs)):
        return
    print(f"Building {os.path.basename(binary)} helper (one-time)...")
    subprocess.run(["swiftc", "-O", "-swift-version", "5", "-o", binary, *srcs], check=True)


class UI:
    """The overhear-ui app: Home window, live caption overlay, and Replay.

    Python → UI (stdin):  {"type": "status" | "interim" | "final" | "error" | "ended", "text": ...}
    UI → Python (stdout): {"type": "start" | "save" | "discard"}; EOF means the app quit.
    """

    def __init__(self, proc: asyncio.subprocess.Process):
        self.proc = proc

    @classmethod
    async def start(cls) -> "UI":
        return cls(await asyncio.create_subprocess_exec(
            UI_BIN, str(RECORDINGS_DIR),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE))

    async def send(self, kind: str, text: str):
        if self.proc.returncode is not None:
            return
        try:
            self.proc.stdin.write((json.dumps({"type": kind, "text": text}) + "\n").encode())
            await self.proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass  # the app quit; next_event() notices

    async def next_event(self) -> str | None:
        """The next button the user clicked ("start", "save", "discard"), or None once the app quit."""
        while line := await self.proc.stdout.readline():
            try:
                return json.loads(line)["type"]
            except (ValueError, KeyError, TypeError):
                continue  # not a protocol line
        return None

    async def close(self):
        if self.proc.returncode is None:
            self.proc.stdin.close()
            try:
                # Gives the window time to show a final error before it quits
                await asyncio.wait_for(self.proc.wait(), 5)
            except TimeoutError:
                self.proc.terminate()
                await self.proc.wait()


async def system_audio(sample_rate: int):
    # ~100 ms chunks of 16-bit mono PCM from the ScreenCaptureKit helper
    proc = await asyncio.create_subprocess_exec(
        HELPER_BIN, str(sample_rate), stdout=asyncio.subprocess.PIPE)
    try:
        while chunk := await proc.stdout.read(sample_rate // 10 * 2):
            yield chunk
    finally:
        if proc.returncode is None:
            proc.terminate()
            await proc.wait()


async def device_audio(device, sample_rate: int):
    # ~100 ms chunks of 16-bit mono PCM from an input device
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[bytes] = asyncio.Queue()

    def on_audio(indata, frames, time_info, status):
        loop.call_soon_threadsafe(queue.put_nowait, bytes(indata))

    with sd.RawInputStream(device=device, samplerate=sample_rate, channels=1,
                           dtype="int16", blocksize=sample_rate // 10,
                           callback=on_audio):
        while True:
            yield await queue.get()


def audio_source(device):
    """Picks the input once; returns (open_source, sample_rate, label).

    Each session calls open_source() for a fresh capture, e.g. a new syscap process.
    """
    if device is None:
        return lambda: system_audio(SYSTEM_RATE), SYSTEM_RATE, "system audio"
    info = sd.query_devices(device, "input")
    sample_rate = int(info["default_samplerate"])
    return lambda: device_audio(device, sample_rate), sample_rate, f"'{info['name']}'"


async def run(device, use_ui: bool):
    key = load_key()
    if not key:
        sys.exit("Set DEEPGRAM_API_KEY (env var or .env file next to this script).")

    open_source, sample_rate, label = audio_source(device)
    print(f"Capturing {label} @ {sample_rate} Hz — Ctrl+C to stop\n")
    if not use_ui:
        await stream(key, open_source(), sample_rate, label, no_show)
        return

    cleanup_partials()
    ui = await UI.start()
    try:
        print("Waiting for Start in the Overhear window…")
        while (event := await ui.next_event()) is not None:
            if event != "start":
                continue
            rec = Recording(RECORDINGS_DIR, sample_rate)
            stop = asyncio.Event()
            await session(ui, rec, stream(key, open_source(), sample_rate, label, ui.send, rec, stop),
                          stop)
            print("Waiting for Start in the Overhear window…")
    finally:
        await ui.close()


async def no_show(kind: str, text: str):
    pass


async def next_choice(ui) -> str | None:
    while (event := await ui.next_event()) not in ("save", "discard", None):
        pass
    return event


async def session(ui, rec: Recording, capture, stop: asyncio.Event):
    """Runs one session from Start until Save, Discard or quit, then keeps or deletes `rec`.

    `capture` streams audio and captions into `rec` until `stop` is set. If it fails first (network
    error, audio capture died), the error stays on screen and the user's Save/Discard still
    decides. If the app quits or Ctrl+C hits mid-session, `rec` is kept when it's worth keeping.

    E.g. Start, 10 min of captions, Save → <recordings>/2026-10-09_14-30-05/, then "ended" tells
    the UI to go back to Home.
    """
    capture_task = asyncio.create_task(capture)
    choice_task = asyncio.create_task(next_choice(ui))
    choice = None
    try:
        await asyncio.wait([capture_task, choice_task], return_when=asyncio.FIRST_COMPLETED)
        if capture_task.done() and (error := capture_task.exception()):
            print(f"\r\033[KError: {error}")
            await ui.send("error", f"Error: {error}")
        choice = await choice_task
        # Stop gracefully so Deepgram's last lines still land in rec
        stop.set()
        await asyncio.wait([capture_task], timeout=DRAIN_TIMEOUT + 2)
    finally:
        capture_task.cancel()
        choice_task.cancel()
        if choice == "save" or (choice is None and rec.worth_keeping()):
            path = rec.save()
            print(f"\r\033[KSaved → {path}" if path else "\r\033[KNothing recorded.")
        else:
            rec.discard()
        if choice:
            await ui.send("ended", "")


async def stream(key, source, sample_rate, label, show, rec: Recording | None = None,
                 stop: asyncio.Event | None = None):
    """Streams audio to Deepgram and shows captions until the audio ends or `stop` is set.

    With `rec`, every chunk sent and every final line also go into the recording; Deepgram's
    line times count seconds of audio sent, so they match positions in rec's audio.
    """
    await show("status", "Connecting…")
    async with websockets.connect(
        build_url(sample_rate),
        additional_headers={"Authorization": f"Token {key}"},
        # python.org builds on macOS ship without system CA certs
        ssl=ssl.create_default_context(cafile=certifi.where()),
    ) as ws:
        await show("status", f"Listening to {label}")

        async def sender():
            async for chunk in source:
                if rec:
                    rec.write(chunk)
                await ws.send(chunk)
            # Audio source ended (e.g. helper exited) — stop the session
            await show("error", "Audio capture stopped")
            await ws.close()

        async def receiver():
            async for raw in ws:
                msg = json.loads(raw)
                if msg.get("type") != "Results":
                    continue
                text = msg["channel"]["alternatives"][0]["transcript"]
                if not text:
                    continue
                if msg["is_final"]:
                    print("\r\033[K" + text)
                    if rec:
                        rec.add_line(msg["start"], msg["duration"], text)
                    await show("final", text)
                else:
                    print("\r\033[K\033[2m" + text + "\033[0m", end="", flush=True)
                    await show("interim", text)

        send_task = asyncio.create_task(sender())
        recv_task = asyncio.create_task(receiver())
        stop_task = asyncio.create_task((stop or asyncio.Event()).wait())
        try:
            await asyncio.wait([recv_task, stop_task], return_when=asyncio.FIRST_COMPLETED)
            if not recv_task.done():
                # Stopped: send no more audio, then let Deepgram finalize what it already heard.
                # It closes the socket when done, which ends receiver().
                send_task.cancel()
                await close_stream(ws)
                await asyncio.wait([recv_task], timeout=DRAIN_TIMEOUT)
            if recv_task.done():
                recv_task.result()  # re-raise receiver errors
        finally:
            for task in (send_task, recv_task, stop_task):
                task.cancel()
            await close_stream(ws)


async def close_stream(ws):
    try:
        await ws.send(json.dumps({"type": "CloseStream"}))
    except websockets.ConnectionClosed:
        pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--device",
                   help="capture this input device (name substring or index) "
                        "instead of system audio")
    p.add_argument("--list", action="store_true", help="list audio devices and exit")
    p.add_argument("--no-overlay", action="store_true",
                   help="terminal only: no app window and no recording")
    args = p.parse_args()
    if args.list:
        print(sd.query_devices())
        return
    device = args.device
    if device is None:
        build_helper([HELPER_SRC], HELPER_BIN)
    elif device.isdigit():
        device = int(device)
    if not args.no_overlay:
        build_helper(UI_SRCS, UI_BIN)
    try:
        asyncio.run(run(device, not args.no_overlay))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
