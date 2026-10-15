"""Stream macOS system audio and/or the microphone to Deepgram live STT.

System audio is captured with ScreenCaptureKit via the small `syscap` Swift helper
(built automatically on first run), so no virtual audio device is needed. The `overhear-ui`
app (another Swift helper) starts sessions from its Home window, shows live captions in a
floating, transparent overlay, and replays saved recordings. The overlay turns system audio
and the mic on and off independently; whatever is on is mixed into one stream.

Usage:
    export DEEPGRAM_API_KEY=...
    .venv/bin/python stream_system_audio.py                   # with the app
    .venv/bin/python stream_system_audio.py --no-overlay      # terminal only, system audio
    .venv/bin/python stream_system_audio.py --list            # list input devices
    .venv/bin/python stream_system_audio.py --device "MacBook Pro Microphone"   # mic to use
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

from inputs import Inputs
from recording import RECORDINGS_DIR, Recording, cleanup_partials
from youtube import YOUTUBE_DIR, Importer

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER_SRC = os.path.join(HERE, "syscap.swift")
HELPER_BIN = os.path.join(HERE, "syscap")
UI_SRCS = sorted(glob.glob(os.path.join(HERE, "ui", "*.swift")))
UI_BIN = os.path.join(HERE, "overhear-ui")
UI_PLIST = os.path.join(HERE, "ui", "Info.plist")  # names the app "Overhear" in the menu bar
SYSTEM_RATE = 48000  # every input is captured at this rate, so they can be mixed
LABELS = {"system": "system audio", "mic": "microphone"}
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


def build_helper(srcs: list[str], binary: str, plist: str | None = None):
    """Compiles `srcs` into `binary` unless it's newer than all of them (and `plist`).

    `plist` is linked into the binary as its Info.plist, which gives an executable that isn't an
    .app bundle a name and identifier.
    """
    inputs = srcs + ([plist] if plist else [])
    if os.path.exists(binary) and os.path.getmtime(binary) >= max(map(os.path.getmtime, inputs)):
        return
    print(f"Building {os.path.basename(binary)} helper (one-time)...")
    link = ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
            "-Xlinker", plist] if plist else []
    subprocess.run(["swiftc", "-O", "-swift-version", "5", "-o", binary, *link, *srcs], check=True)


class UI:
    """The overhear-ui app: Home window, live caption overlay, and Replay.

    Python → UI (stdin):  {"type": "status" | "interim" | "final" | "error" | "ended", "text": ...}
                          {"type": "input", "text": "mic", "on": false}  (an input failed)
                          {"type": "import" | "import_error", "text": ...}  (a YouTube import)
                          {"type": "imported", "text": "Added “Title”", "folder": "<path>"}
    UI → Python (stdout): {"type": "start", "system": true, "mic": false}
                          {"type": "input", "name": "mic", "on": true}  (a toggle was clicked)
                          {"type": "save" | "discard"}
                          {"type": "import", "url": "https://youtu.be/..."}; EOF means the app quit.
    """

    def __init__(self, proc: asyncio.subprocess.Process):
        self.proc = proc

    @classmethod
    async def start(cls) -> "UI":
        return cls(await asyncio.create_subprocess_exec(
            UI_BIN, str(RECORDINGS_DIR), str(YOUTUBE_DIR),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE))

    async def send(self, kind: str, text: str, **extra):
        if self.proc.returncode is not None:
            return
        try:
            self.proc.stdin.write((json.dumps({"type": kind, "text": text, **extra}) + "\n").encode())
            await self.proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass  # the app quit; next_event() notices

    async def next_event(self) -> dict | None:
        """The next thing the user clicked, e.g. {"type": "save"}, or None once the app quit."""
        while line := await self.proc.stdout.readline():
            try:
                event = json.loads(line)
            except ValueError:
                continue  # not a protocol line
            if isinstance(event, dict) and "type" in event:
                return event
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
    # ~20 ms chunks of 16-bit mono PCM from an input device (None: the system default)
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[bytes] = asyncio.Queue()

    def on_audio(indata, frames, time_info, status):
        loop.call_soon_threadsafe(queue.put_nowait, bytes(indata))

    with sd.RawInputStream(device=device, samplerate=sample_rate, channels=1,
                           dtype="int16", blocksize=sample_rate // 50,
                           callback=on_audio):
        while True:
            yield await queue.get()


def make_inputs(device, on: set[str], on_failure) -> Inputs:
    """A session's inputs: system audio from syscap, and the mic from `device`."""
    return Inputs(SYSTEM_RATE, {
        "system": lambda: system_audio(SYSTEM_RATE),
        "mic": lambda: device_audio(device, SYSTEM_RATE),
    }, on, on_failure)


def describe(on: set[str]) -> str:
    """E.g. {"system", "mic"} → "Listening to system audio and microphone"."""
    if not on:
        return "System audio and microphone are off"
    return "Listening to " + " and ".join(LABELS[name] for name in LABELS if name in on)


async def run(device, use_ui: bool):
    key = load_key()
    if not key:
        sys.exit("Set DEEPGRAM_API_KEY (env var or .env file next to this script).")

    if not use_ui:
        # Terminal only: one input, and the stream ends if it fails.
        on = {"system"} if device is None else {"mic"}
        stop = asyncio.Event()

        async def ended(name, error):
            print(f"\r\033[KError: {LABELS[name]} stopped: {error}")
            stop.set()

        print(f"{describe(on)} — Ctrl+C to stop\n")
        inputs = make_inputs(device, on, ended)
        await stream(key, inputs.chunks(), SYSTEM_RATE, describe(on), no_show, stop=stop)
        return

    cleanup_partials()
    cleanup_partials(YOUTUBE_DIR)
    ui = await UI.start()
    importer = Importer(YOUTUBE_DIR, key, ui.send)
    try:
        print("Waiting for Start in the Overhear window…")
        while (event := await ui.next_event()) is not None:
            if event["type"] == "import" and event.get("url"):
                importer.add(event["url"])
            if event["type"] != "start":
                continue

            async def failed(name, error):
                print(f"\r\033[KError: {LABELS[name]} stopped: {error}")
                await ui.send("error", f"{LABELS[name].capitalize()} stopped: {error}")
                await ui.send("input", name, on=False)

            inputs = make_inputs(device, {name for name in LABELS if event.get(name)}, failed)
            rec = Recording(RECORDINGS_DIR, SYSTEM_RATE)
            stop = asyncio.Event()
            capture = stream(key, inputs.chunks(), SYSTEM_RATE, describe(inputs.on), ui.send,
                             rec, stop)
            await session(ui, rec, capture, stop, inputs)
            print("Waiting for Start in the Overhear window…")
    finally:
        await importer.close()
        await ui.close()


async def no_show(kind: str, text: str):
    pass


async def next_choice(ui, inputs: Inputs | None) -> str | None:
    """Waits for Save or Discard (None if the app quit), turning inputs on and off meanwhile."""
    while (event := await ui.next_event()) is not None:
        if event["type"] in ("save", "discard"):
            return event["type"]
        if event["type"] == "input" and inputs:
            inputs.set(event.get("name"), bool(event.get("on")))
            await ui.send("status", describe(inputs.on))
    return None


async def session(ui, rec: Recording, capture, stop: asyncio.Event, inputs: Inputs | None = None):
    """Runs one session from Start until Save, Discard or quit, then keeps or deletes `rec`.

    `capture` streams audio and captions into `rec` until `stop` is set. If it fails first (network
    error, audio capture died), the error stays on screen and the user's Save/Discard still
    decides. If the app quits or Ctrl+C hits mid-session, `rec` is kept when it's worth keeping.

    E.g. Start, 10 min of captions, Save → <recordings>/2026-10-09_14-30-05/, then "ended" tells
    the UI to go back to Home.
    """
    capture_task = asyncio.create_task(capture)
    choice_task = asyncio.create_task(next_choice(ui, inputs))
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


async def stream(key, source, sample_rate, status, show, rec: Recording | None = None,
                 stop: asyncio.Event | None = None):
    """Streams audio to Deepgram and shows captions until the audio ends or `stop` is set.

    `source` yields (chunk, the mic heard speech). With `rec`, every chunk sent and every final
    line also go into the recording; Deepgram's line times count seconds of audio sent, so they
    match positions in rec's audio.
    """
    await show("status", "Connecting…")
    async with websockets.connect(
        build_url(sample_rate),
        additional_headers={"Authorization": f"Token {key}"},
        # python.org builds on macOS ship without system CA certs
        ssl=ssl.create_default_context(cafile=certifi.where()),
    ) as ws:
        await show("status", status)

        async def sender():
            async for chunk, mic in source:
                if rec:
                    rec.write(chunk, mic)
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
                   help="microphone to use (name substring or index; default: the system input). "
                        "With --no-overlay, captions it instead of system audio")
    p.add_argument("--list", action="store_true", help="list audio devices and exit")
    p.add_argument("--no-overlay", action="store_true",
                   help="terminal only: no app window and no recording")
    args = p.parse_args()
    if args.list:
        print(sd.query_devices())
        return
    device = args.device
    if device is not None and device.isdigit():
        device = int(device)
    if device is None or not args.no_overlay:
        build_helper([HELPER_SRC], HELPER_BIN)
    if not args.no_overlay:
        build_helper(UI_SRCS, UI_BIN, UI_PLIST)
    try:
        asyncio.run(run(device, not args.no_overlay))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
