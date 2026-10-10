# Overhear

Live captions for everything your Mac plays. Overhear captures system audio (meetings, videos,
podcasts, anything coming out of the speakers), streams it to [Deepgram](https://deepgram.com)'s
real-time speech-to-text API, and shows the transcript in a floating, transparent window that stays
on top of every app, including full-screen ones. Sessions can be saved and replayed later, with the
captions following the audio line by line.

No virtual audio device (BlackHole, iShowU, Loopback…) is needed: audio is captured directly with
Apple's ScreenCaptureKit.

## How it works

```
 system audio ──► syscap ──PCM──► stream_system_audio.py ──WebSocket──► Deepgram (nova-3)
                                     │         ▲
                     captions (stdin)│         │clicks: start / save / discard (stdout)
                                     ▼         │
                                  overhear-ui (Home · caption overlay · Replay)

 Save ──► ~/Library/Application Support/Overhear/recordings/<date>/{audio.m4a, captions.json}
```

| Piece | What it does |
| --- | --- |
| `syscap.swift` | Captures system audio with ScreenCaptureKit and writes raw 16-bit mono PCM to stdout. |
| `ui/` | The `overhear-ui` app: a Home window (Run live captioning, recordings list), the transparent always-on-top caption overlay, and the Replay window. |
| `recording.py` | Writes one session to disk: the exact audio sent to Deepgram plus its final captions. |
| `stream_system_audio.py` | The main program: starts `overhear-ui`, and for each session runs `syscap`, streams the audio to Deepgram, prints transcripts in the terminal, forwards them to the overlay, and saves or discards the recording. |

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

On first run, the script compiles the `syscap` and `overhear-ui` helpers with `swiftc`. It rebuilds
them whenever their `.swift` sources change. The **Overhear** window opens:

1. Click **Run live captioning** (or press **⌥⇧R** in any app). The window hides, the floating
   overlay appears, and captions show up there and in the terminal as audio plays.
2. End the session from the overlay toolbar with **Save** or **Discard**, or press **⌥⇧S** /
   **⌥⇧D** in any app. Both ask you to confirm with a second click or press within 3 seconds.
   Either way you return to the Overhear window.
3. Saved sessions are listed newest first, named `recording1`, `recording2`, … Double-click one
   (or select it and press Return) to replay it. Right-click → *Rename* to give it a better name
   (Return saves, Esc cancels). To remove recordings, select one or more (⌘-click, ⇧-click or ⌘A)
   and press Delete, click the trash button, or right-click → *Move to Trash*.

Close the Overhear window, press **⌘Q**, or press **Ctrl+C** in the terminal to quit.

The first time, macOS asks for **Screen & System Audio Recording** permission for your terminal
app. Grant it in *System Settings → Privacy & Security → Screen & System Audio Recording*, then
restart the terminal.

### Options

```sh
.venv/bin/python stream_system_audio.py --no-overlay       # terminal only: no windows, no recording
.venv/bin/python stream_system_audio.py --list             # list audio input devices
.venv/bin/python stream_system_audio.py --device "MacBook Pro Microphone"   # transcribe a mic instead
```

`--device` accepts a name substring or the index shown by `--list`.

Deepgram settings (`nova-3`, English, interim results, smart formatting) are set in `build_url()`
in `stream_system_audio.py`.

### The overlay window

- **Move** it by dragging anywhere inside; **resize** it by dragging its border.
- Toolbar buttons (hover one to see its name): smaller/larger text, cycle background opacity, clear the screen, **lock** (makes
  the window click-through, so it never gets in the way), **Save** and **Discard**.
- It never takes keyboard focus. Position, size, font size and opacity are remembered between runs.
- Interim (in-progress) text is shown until Deepgram finalizes it. The last 50 lines are shown;
  a saved recording keeps every line.

### Recordings

Each saved session is a folder in `~/Library/Application Support/Overhear/recordings/`:

```
2026-10-09_14-30-05/
  audio.m4a       the audio Deepgram heard, as AAC (about 30 MB per hour)
  captions.json   {"name": "recording3", "started_at": "...", "duration": 3612.4,
                   "lines": [{"start": 0.84, "end": 4.1, "text": "..."}, ...]}
```

Line times come from Deepgram and are positions in `audio.m4a`, which is what keeps Replay in
step. While recording, audio goes to a WAV in the hidden `.partial/` folder; it's converted on
save (if conversion fails, `audio.wav` is kept instead).

- If something fails mid-session (network, audio capture), the error shows in red and Save /
  Discard still decide what happens to what was recorded so far.
- Quitting or pressing Ctrl+C mid-session saves automatically, unless there's nothing worth
  keeping (no captions and under 3 seconds of audio).
- Half-written sessions left by a crash are deleted on the next launch.

In **Replay**, the line being spoken is highlighted and kept in view (scrolling by hand pauses
that for a few seconds). Click any line to play from there. **Space** plays and pauses, and the
slider seeks.

## Running the helpers on their own

The Python script builds and launches both helpers for you. You can also build them yourself:

```sh
swiftc -O -swift-version 5 -o syscap syscap.swift
swiftc -O -swift-version 5 -o overhear-ui ui/*.swift
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

### `overhear-ui`

```sh
./overhear-ui <recordings_dir>
```

Lists and replays the recordings in `recordings_dir`. Reads one JSON object per line from stdin
and quits when stdin closes:

```json
{"type": "status" | "interim" | "final" | "error" | "ended", "text": "..."}
```

`final` lines are added to the overlay. `interim` replaces the line still in progress. `status` and
`error` show a message (errors in red). `ended` hides the overlay and brings back the Overhear
window, once a saved or discarded session has been handled.

It writes the user's clicks to stdout, one per line: `{"type": "start"}`, `{"type": "save"}` or
`{"type": "discard"}`. To try it by hand, click Run live captioning, then:

```sh
(sleep 5; printf '%s\n' '{"type":"status","text":"Hello"}' '{"type":"final","text":"Overhear works."}'; sleep 30) \
  | ./overhear-ui /tmp/overhear-test
```

## Tests

```sh
uv run --with pytest pytest
```

The tests cover `recording.py` and the session lifecycle (Save, Discard, failures, quitting) with a
fake UI and capture, so they need no network or Deepgram key.
