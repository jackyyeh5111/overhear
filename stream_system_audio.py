"""Stream macOS system audio to Deepgram live STT.

System audio is captured with ScreenCaptureKit via the small `syscap` Swift helper
(built automatically on first run), so no virtual audio device is needed.

Usage:
    export DEEPGRAM_API_KEY=...
    .venv/bin/python stream_system_audio.py                   # system audio
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


def build_helper():
    if os.path.exists(HELPER_BIN) and os.path.getmtime(HELPER_BIN) >= os.path.getmtime(HELPER_SRC):
        return
    print("Building syscap helper (one-time)...")
    subprocess.run(["swiftc", "-O", "-swift-version", "5", "-o", HELPER_BIN, HELPER_SRC], check=True)


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


async def run(device):
    key = load_key()
    if not key:
        sys.exit("Set DEEPGRAM_API_KEY (env var or .env file next to this script).")

    if device is None:
        sample_rate = SYSTEM_RATE
        source = system_audio(sample_rate)
        print(f"Capturing system audio @ {sample_rate} Hz — Ctrl+C to stop\n")
    else:
        info = sd.query_devices(device, "input")
        sample_rate = int(info["default_samplerate"])
        source = device_audio(device, sample_rate)
        print(f"Capturing '{info['name']}' @ {sample_rate} Hz — Ctrl+C to stop\n")

    async with websockets.connect(
        build_url(sample_rate),
        additional_headers={"Authorization": f"Token {key}"},
        # python.org builds on macOS ship without system CA certs
        ssl=ssl.create_default_context(cafile=certifi.where()),
    ) as ws:

        async def sender():
            async for chunk in source:
                await ws.send(chunk)
            # Audio source ended (e.g. helper exited) — stop the session
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
                else:
                    print("\r\033[K\033[2m" + text + "\033[0m", end="", flush=True)

        send_task = asyncio.create_task(sender())
        try:
            await receiver()
        finally:
            send_task.cancel()
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
    args = p.parse_args()
    if args.list:
        print(sd.query_devices())
        return
    device = args.device
    if device is None:
        build_helper()
    elif device.isdigit():
        device = int(device)
    try:
        asyncio.run(run(device))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
