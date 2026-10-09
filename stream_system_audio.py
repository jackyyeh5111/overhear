"""Stream macOS system audio (via a loopback device) to Deepgram live STT.

Usage:
    export DEEPGRAM_API_KEY=...
    .venv/bin/python stream_system_audio.py --list
    .venv/bin/python stream_system_audio.py --device "iShowU Audio Capture"
"""
import argparse
import asyncio
import json
import os
import ssl
import sys
from urllib.parse import urlencode

import certifi
import sounddevice as sd
import websockets


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
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                name, _, value = line.strip().removeprefix("export ").partition("=")
                if name == "DEEPGRAM_API_KEY" and value:
                    return value.strip("'\"")
    return None


async def run(device: str):
    key = load_key()
    if not key:
        sys.exit("Set DEEPGRAM_API_KEY (env var or .env file next to this script).")

    info = sd.query_devices(device, "input")
    sample_rate = int(info["default_samplerate"])
    print(f"Capturing '{info['name']}' @ {sample_rate} Hz — Ctrl+C to stop\n")

    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[bytes] = asyncio.Queue()

    def on_audio(indata, frames, time_info, status):
        loop.call_soon_threadsafe(queue.put_nowait, bytes(indata))

    async with websockets.connect(
        build_url(sample_rate),
        additional_headers={"Authorization": f"Token {key}"},
        # python.org builds on macOS ship without system CA certs
        ssl=ssl.create_default_context(cafile=certifi.where()),
    ) as ws:

        async def sender():
            # ~100 ms chunks of 16-bit mono PCM
            with sd.RawInputStream(device=device, samplerate=sample_rate, channels=1,
                                   dtype="int16", blocksize=sample_rate // 10,
                                   callback=on_audio):
                while True:
                    await ws.send(await queue.get())

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
    p.add_argument("--device", default="iShowU Audio Capture",
                   help="input device name (substring ok) or index")
    p.add_argument("--list", action="store_true", help="list audio devices and exit")
    args = p.parse_args()
    if args.list:
        print(sd.query_devices())
        return
    device = int(args.device) if args.device.isdigit() else args.device
    try:
        asyncio.run(run(device))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
