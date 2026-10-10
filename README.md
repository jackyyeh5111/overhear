# Overhear

Live captions for everything your Mac plays. Overhear captures system audio (meetings, videos,
podcasts, anything coming out of the speakers), streams it to [Deepgram](https://deepgram.com)'s
real-time speech-to-text API, and shows the transcript in a floating, transparent window that stays
on top of every app, including full-screen ones.

No virtual audio device (BlackHole, iShowU, Loopback…) is needed: audio is captured directly with
Apple's ScreenCaptureKit.

## How it works

```
 system audio ──► syscap ──PCM──► stream_system_audio.py ──WebSocket──► Deepgram (nova-3)
                                          │
                                          └──JSON lines──► overlay (floating caption window)
```

| Piece | What it does |
| --- | --- |
| `syscap.swift` | Captures system audio with ScreenCaptureKit and writes raw 16-bit mono PCM to stdout. |
| `overlay.swift` | A transparent, always-on-top panel that shows transcripts it reads as JSON lines on stdin. |
| `stream_system_audio.py` | The main program: runs `syscap`, streams the audio to Deepgram, prints transcripts in the terminal and forwards them to `overlay`. |

## Requirements

- macOS 13 or later (ScreenCaptureKit audio capture)
- Xcode Command Line Tools, for `swiftc` (`xcode-select --install`)
- Python 3.11+
- [uv](https://docs.astral.sh/uv/) (`brew install uv`)
- A Deepgram API key: create one at <https://console.deepgram.com>

## Setup

```sh
uv venv
uv pip install -r requirements.txt
```

Provide your API key either as an environment variable:

```sh
export DEEPGRAM_API_KEY=your-key
```

or in a `.env` file next to the script (it's git-ignored):

```sh
DEEPGRAM_API_KEY=your-key
```

## Usage

```sh
.venv/bin/python stream_system_audio.py
```

On first run, the script compiles the `syscap` and `overlay` helpers with `swiftc`. It rebuilds
them whenever their `.swift` source changes. Play some audio and captions appear in the terminal
and in the overlay window. Stop with **Ctrl+C**, or close the overlay window.

The first time, macOS asks for **Screen & System Audio Recording** permission for your terminal
app. Grant it in *System Settings → Privacy & Security → Screen & System Audio Recording*, then
restart the terminal.

### Options

```sh
.venv/bin/python stream_system_audio.py --no-overlay       # terminal only, no floating window
.venv/bin/python stream_system_audio.py --list             # list audio input devices
.venv/bin/python stream_system_audio.py --device "MacBook Pro Microphone"   # transcribe a mic instead
```

`--device` accepts a name substring or the index shown by `--list`.

Deepgram settings (`nova-3`, English, interim results, smart formatting) are set in `build_url()`
in `stream_system_audio.py`.

### The overlay window

- **Move** it by dragging anywhere inside; **resize** it by dragging its border.
- Toolbar buttons: smaller/larger text, cycle background opacity, clear, **lock** (makes the window
  click-through, so it never gets in the way), and close.
- It never takes keyboard focus. Position, size, font size and opacity are remembered between runs.
- Interim (in-progress) text is shown until Deepgram finalizes it. The last 50 lines are kept.

## Running the helpers on their own

The Python script builds and launches both helpers for you. You can also build them yourself:

```sh
swiftc -O -swift-version 5 -o syscap syscap.swift
swiftc -O -swift-version 5 -o overlay overlay.swift
```

### `syscap`

```sh
./syscap [sample_rate]    # 8000, 16000, 24000 or 48000 (default 48000)
```

Writes raw signed 16-bit little-endian mono PCM to stdout until it's killed. All channels are
downmixed to mono, and Overhear's own audio is excluded. For example, to record 10 seconds and play
it back with [SoX](https://sox.sourceforge.net):

```sh
./syscap 16000 > out.raw & sleep 10; kill $!
play -t raw -r 16000 -e signed -b 16 -c 1 out.raw
```

### `overlay`

```sh
./overlay
```

Reads one JSON object per line from stdin and quits when stdin closes:

```json
{"type": "status" | "interim" | "final" | "error", "text": "..."}
```

`final` lines are added to the history. `interim` replaces the line still in progress. `status`
and `error` show a message (errors in red). To try it by hand:

```sh
printf '%s\n' '{"type":"status","text":"Hello"}' '{"type":"final","text":"Overhear works."}' \
  | (cat; sleep 5) | ./overlay
```
