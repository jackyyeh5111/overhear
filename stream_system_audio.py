"""Stream macOS system audio to Deepgram live STT.

System audio is captured with ScreenCaptureKit via the small `syscap` Swift helper
(built automatically on first run), so no virtual audio device is needed. Transcripts
also appear in a floating, transparent `overlay` window (another Swift helper).

Usage:
    export DEEPGRAM_API_KEY=...
    .venv/bin/python stream_system_audio.py                   # system audio
    .venv/bin/python stream_system_audio.py --no-overlay      # terminal only
    .venv/bin/python stream_system_audio.py --list            # list input devices
    .venv/bin/python stream_system_audio.py --device "MacBook Pro Microphone"
"""
import argparse
import asyncio
import json
import os
import ssl
import subprocess
import sys
from urllib.parse import urlencode

import certifi
import sounddevice as sd
import websockets

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER_SRC = os.path.join(HERE, "syscap.swift")
HELPER_BIN = os.path.join(HERE, "syscap")
OVERLAY_SRC = os.path.join(HERE, "overlay.swift")
OVERLAY_BIN = os.path.join(HERE, "overlay")
SYSTEM_RATE = 48000


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


def build_helper(src: str, binary: str):
    if os.path.exists(binary) and os.path.getmtime(binary) >= os.path.getmtime(src):
        return
    print(f"Building {os.path.basename(binary)} helper (one-time)...")
    subprocess.run(["swiftc", "-O", "-swift-version", "5", "-o", binary, src], check=True)


class Overlay:
    """The floating transcript window; fed JSON lines on stdin, quits when stdin closes."""

    def __init__(self, proc: asyncio.subprocess.Process):
        self.proc = proc

    @classmethod
    async def start(cls) -> "Overlay":
        return cls(await asyncio.create_subprocess_exec(OVERLAY_BIN, stdin=asyncio.subprocess.PIPE))

    async def send(self, kind: str, text: str):
        if self.proc.returncode is not None:
            return
        try:
            self.proc.stdin.write((json.dumps({"type": kind, "text": text}) + "\n").encode())
            await self.proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass  # the window was closed; run() notices the exit

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


async def run(device, use_overlay: bool):
    key = load_key()
    if not key:
        sys.exit("Set DEEPGRAM_API_KEY (env var or .env file next to this script).")

    if device is None:
        sample_rate = SYSTEM_RATE
        source = system_audio(sample_rate)
        label = "system audio"
        print(f"Capturing system audio @ {sample_rate} Hz — Ctrl+C to stop\n")
    else:
        info = sd.query_devices(device, "input")
        sample_rate = int(info["default_samplerate"])
        source = device_audio(device, sample_rate)
        label = f"'{info['name']}'"
        print(f"Capturing '{info['name']}' @ {sample_rate} Hz — Ctrl+C to stop\n")

    overlay = await Overlay.start() if use_overlay else None

    async def show(kind: str, text: str):
        if overlay:
            await overlay.send(kind, text)

    try:
        await show("status", "Connecting…")
        await stream(sample_rate, key, source, label, show, overlay)
    except Exception as e:
        await show("error", f"Error: {e}")
        raise
    finally:
        if overlay:
            await overlay.close()


async def stream(sample_rate, key, source, label, show, overlay):
    async with websockets.connect(
        build_url(sample_rate),
        additional_headers={"Authorization": f"Token {key}"},
        # python.org builds on macOS ship without system CA certs
        ssl=ssl.create_default_context(cafile=certifi.where()),
    ) as ws:
        await show("status", f"Listening to {label}")

        async def sender():
            async for chunk in source:
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
                    await show("final", text)
                else:
                    print("\r\033[K\033[2m" + text + "\033[0m", end="", flush=True)
                    await show("interim", text)

        send_task = asyncio.create_task(sender())
        ending = [recv_task := asyncio.create_task(receiver())]
        if overlay:
            # Closing the overlay window ends the session too
            ending.append(asyncio.create_task(overlay.proc.wait()))
        try:
            done, _ = await asyncio.wait(ending, return_when=asyncio.FIRST_COMPLETED)
            if recv_task in done:
                recv_task.result()  # re-raise receiver errors
            else:
                print("\r\033[KOverlay closed.")
        finally:
            for task in [send_task, *ending]:
                task.cancel()
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
                   help="don't show the floating transcript window")
    args = p.parse_args()
    if args.list:
        print(sd.query_devices())
        return
    device = args.device
    if device is None:
        build_helper(HELPER_SRC, HELPER_BIN)
    elif device.isdigit():
        device = int(device)
    if not args.no_overlay:
        build_helper(OVERLAY_SRC, OVERLAY_BIN)
    try:
        asyncio.run(run(device, not args.no_overlay))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
