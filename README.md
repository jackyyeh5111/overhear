# Overhear

Live captions for everything your Mac plays, and for you. Overhear captures system audio (meetings,
videos, podcasts, anything coming out of the speakers) and, when you turn it on, your microphone.
It streams them to [Deepgram](https://deepgram.com)'s real-time speech-to-text API and shows the
transcript in a floating, transparent window that stays on top of every app, including full-screen
ones. Sessions can be saved and replayed later, with the captions following the audio line by line
and the lines you spoke marked.

No virtual audio device (BlackHole, iShowU, Loopback…) is needed: audio is captured directly with
Apple's ScreenCaptureKit.

## How it works

```
 system audio ──► syscap ──PCM──┐
                                ├─► mixed in stream_system_audio.py ──WebSocket──► Deepgram (nova-3)
 microphone ──► sounddevice ────┘         │         ▲
                         captions (stdin) │         │ clicks: start / toggles / save / discard
                                          ▼         │ (stdout)
                                       overhear-ui (Home · caption overlay · Replay)

 Save ──► ~/Library/Application Support/Overhear/recordings/<date>/{audio.m4a, captions.json}

 YouTube link ──► yt-dlp (audio + captions) ──► ~/Library/Application Support/Overhear/youtube/<video id>/{…}
```

| Piece | What it does |
| --- | --- |
| `syscap.swift` | Captures system audio with ScreenCaptureKit and writes raw 16-bit mono PCM to stdout. |
| `ui/` | The `overhear-ui` app: a Home window (Start live captions, searchable recordings list), the transparent always-on-top caption overlay, and the Replay window, which picks up where you left off (`LeftOff.swift`). Its Dock icon is drawn in code (`Icon.swift`), and `Info.plist` is linked into the binary so it's named Overhear. |
| `inputs.py` | Mixes whichever inputs are on (system audio, mic) into one steady stream, and notes when the mic hears speech. |
| `recording.py` | Writes one session to disk: the exact audio sent to Deepgram plus its final captions. |
| `youtube.py` | Imports a YouTube video: downloads its audio and English captions with yt-dlp (or has Deepgram transcribe it) and saves them in the recordings' format. |
| `stream_system_audio.py` | The main program: starts `overhear-ui`, and for each session captures the inputs, streams the mix to Deepgram, prints transcripts in the terminal, forwards them to the overlay, and saves or discards the recording. |

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

1. Pick what to caption with the **System audio** and **Microphone** checkboxes, then click
   **Start live captions** (or press **⌥⇧R** in any app). The window hides, the floating overlay
   appears, and captions show up there and in the terminal as audio plays. Use the **microphone**
   and **system audio** toggles at the left of the overlay toolbar to turn each input on or off at
   any time (**⌥⇧M** toggles the mic from any app, and the overlay briefly shows "Microphone on"
   or "off"); the choice is remembered for the next session (the first one starts with system
   audio only).
2. End the session from the overlay toolbar with **Save** or **Discard**, or press **⌥⇧S** /
   **⌥⇧D** in any app. Both ask you to confirm with a second click or press within 3 seconds.
   Either way you return to the Overhear window, with the recording you just saved selected.
3. Saved sessions are listed newest first, named `recording1`, `recording2`, …, each with its
   date, length, first caption, and an orange mic if you spoke in it. Type in the search field
   (**⌘F**) to filter them by name or by anything said in them. Double-click one
   (or select it and press Return) to replay it. Right-click → *Rename* to give it a better name
   (Return saves, Esc cancels). To remove recordings, select one or more (⌘-click, ⇧-click or ⌘A)
   and press Delete, click the trash button, or right-click → *Move to Trash*.
   Changed your mind? Press **⌘Z** (Edit → *Undo Move to Trash*) or click **Undo** in the banner
   that appears, and they come back. Until you quit, you can undo several deletes in a row, and
   **⇧⌘Z** trashes them again. After that, they're still in the Finder Trash.

Close the Overhear window, press **⌘Q**, or press **Ctrl+C** in the terminal to quit.

The first time, macOS asks for **Screen & System Audio Recording** permission for your terminal
app. Grant it in *System Settings → Privacy & Security → Screen & System Audio Recording*, then
restart the terminal. The first time you turn the mic on, macOS also asks for **Microphone**
permission for the terminal.

With both inputs on, wear headphones: otherwise the mic also hears the speakers, which doubles
that audio in the transcript and can mark lines as yours that weren't.

### Options

```sh
.venv/bin/python stream_system_audio.py --no-overlay       # terminal only: system audio, no recording
.venv/bin/python stream_system_audio.py --list             # list audio input devices
.venv/bin/python stream_system_audio.py --device "MacBook Pro Microphone"   # which mic to use
```

`--device` picks the microphone behind the overlay's mic toggle (default: the system input device).
It accepts a name substring or the index shown by `--list`. With `--no-overlay`, it captions that
mic instead of system audio.

Deepgram settings (`nova-3`, English, interim results, smart formatting) are set in `build_url()`
in `stream_system_audio.py`.

### The overlay window

- **Move** it by dragging anywhere inside; **resize** it by dragging its border.
- A pill in the top-left corner shows the session is live: a pulsing red dot, the time since it
  started, and a slashed icon for each input that's off. The dot turns gray while both are off.
- The toolbar fades in while the pointer is over the overlay. Buttons (hover one to see its name): **microphone** and **system audio** on/off
  (slashed while off), smaller/larger text, cycle how dark the frosted background is, clear the screen, **lock**
  (makes the window click-through, so it never gets in the way), **Save** and **Discard**.
- Whatever is on is mixed into one transcript. With both off the session keeps running silently,
  so you can turn an input back on without starting over. If an input fails (say, the mic is
  unplugged), the error shows in red and its toggle turns off.
- It never takes keyboard focus. Position, size, font size and opacity are remembered between runs.
- The newest line is brightest. Interim (in-progress) text is shown, fainter, until Deepgram
  finalizes it. The last 50 lines are shown;
  a saved recording keeps every line.

### Recordings

Each saved session is a folder in `~/Library/Application Support/Overhear/recordings/`:

```
2026-10-09_14-30-05/
  audio.m4a       the audio Deepgram heard, as AAC (about 30 MB per hour)
  captions.json   {"name": "recording3", "started_at": "...", "duration": 3612.4,
                   "lines": [{"start": 0.84, "end": 4.1, "text": "..."},
                             {"start": 4.3, "end": 6.0, "text": "...", "mic": true}, ...]}
```

Line times come from Deepgram and are positions in `audio.m4a`, which is what keeps Replay in
step. `"mic": true` marks a line during which the mic heard at least 0.3 s of speech-level sound,
i.e. you were (also) talking. While recording, audio goes to a WAV in the hidden `.partial/` folder; it's converted on
save (if conversion fails, `audio.wav` is kept instead).

- If something fails mid-session (network, audio capture), the error shows in red and Save /
  Discard still decide what happens to what was recorded so far.
- Quitting or pressing Ctrl+C mid-session saves automatically, unless there's nothing worth
  keeping (no captions and under 3 seconds of audio).
- Half-written sessions left by a crash are deleted on the next launch.

**Replay** remembers where you left off in each recording and video. Reopen one and it starts
there, paused, with a bookmark on that line and *Left off at 12:34* in the corner; Home shows it
as *🔖 12:34 of 45:00*. Stopping in the first or last 5 seconds isn't remembered, so a finished
one opens from the start again.

In **Replay**, the line being spoken is highlighted and kept in view (scrolling by hand pauses
that for a few seconds), and lines already played are dimmed. Click any line to play from there. **Space** plays and pauses, and the
slider seeks. **←** / **→** skip back / forward by the step shown next to the clock (3 s to
start; change it with the arrows beside it, and it's remembered). A hint above the clock shows how far you've
skipped. **↑** / **↓** restart the line being played; pressed again within a second, they go to
the previous / next line. **C** covers or uncovers the line being played, and **Shift+C** covers or uncovers the
whole transcript (handy for listening first). Covered lines are shown again the next time you
open the recording. **[** / **]** slow down / speed up playback (0.75× to 2×, also in the menu
next to the clock, and remembered). The **Lines** menu beside it rebuilds the transcript into lines
of about 3 to 30 seconds each, splitting long lines and merging short ones; a line ends at a
sentence end where it can, and never runs across a pause of 2 s or more. Word times inside a line
are estimated from its length, so a split can land a word off. *Original lines* shows Deepgram's
lines as they were saved; the choice is remembered, and the saved recording isn't changed.
**⌘+** / **⌘-** make the transcript text bigger / smaller (10 to 36 pt, remembered); **⌘0** goes
back to the default size. **⌘F** finds text in the transcript: matches are highlighted,
Return / Shift+Return go to the next / previous one, and Esc clears the search. **⌘C** copies the
selected lines (⌘-click or ⇧-click to select, ⌘A for all), or the playing line when none are
selected, as `[m:ss] text`. To copy just some of the text, drag over it, across lines if you like
(double-click selects a word, triple-click a line), then press **⌘C**; it's copied as shown, a
line per line, without times. **Copy transcript** copies them all. A line under the playback bar
lists these keys. An orange mic icon marks the lines you spoke in, so you can jump straight to
them.

### YouTube videos

Switch Home to the **YouTube** tab (click it, or press **→** in the list; **←** goes back), paste
a link into *Paste a YouTube link…* and press Return or **Add**. The line under it shows the
download's progress. When it's done, the video is listed and selected; open it in Replay like any
recording. Videos have their own list, so they never mix
with your recordings. Search, rename and trash work the same way, and you can keep using the app
(or start live captions) while a download runs. Links pasted meanwhile wait their turn.

Each video is a folder in `~/Library/Application Support/Overhear/youtube/`, named by its video ID:

```
jNQXAC9IVRw/
  audio.m4a       YouTube's AAC audio stream, as downloaded
  captions.json   like a recording's, named after the video, plus
                  "source": "youtube", "url" and "channel"
```

Lines are the video's English captions: the uploader's when there are any, else YouTube's
auto-generated ones (which have no punctuation, so the **Lines** menu can only split them by
length). A video with neither is sent to Deepgram's prerecorded API instead. Pasting a video that's
already there just selects it. If yt-dlp warns that it has no JavaScript runtime and a download
fails, install [deno](https://deno.com) (`brew install deno`). `curl_cffi` (in requirements.txt)
lets yt-dlp download captions as a browser would; without it, YouTube is quicker to refuse them
with "HTTP Error 429: Too Many Requests".

## Running the helpers on their own

The Python script builds and launches both helpers for you. You can also build them yourself:

```sh
swiftc -O -swift-version 5 -o syscap syscap.swift
swiftc -O -swift-version 5 -o overhear-ui \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker ui/Info.plist ui/*.swift
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
./overhear-ui <recordings_dir> <youtube_dir>
```

Lists and replays the recordings in `recordings_dir` and the videos in `youtube_dir`. Reads one JSON object per line from stdin
and quits when stdin closes:

```json
{"type": "status" | "interim" | "final" | "error" | "ended", "text": "..."}
{"type": "input", "text": "mic" | "system", "on": false}
{"type": "import" | "import_error", "text": "..."}
{"type": "imported", "text": "Added “Title”", "folder": "<path>"}
```

`final` lines are added to the overlay. `interim` replaces the line still in progress. `status` and
`error` show a message (errors in red). `input` sets a toggle (Python turns one off when that input
fails). `ended` hides the overlay and brings back the Overhear window, once a saved or discarded
session has been handled. `import` and `import_error` show a YouTube import's progress or failure
under the link field; `imported` shows it's done and selects `folder` in the YouTube tab.

It writes the user's clicks to stdout, one per line: `{"type": "start", "system": true, "mic":
false}` (with the toggles' state), `{"type": "input", "name": "mic", "on": true}`,
`{"type": "save"}`, `{"type": "discard"}` or `{"type": "import", "url": "..."}` (a pasted
YouTube link). To try it by hand, click Start live captions, then:

```sh
(sleep 5; printf '%s\n' '{"type":"status","text":"Hello"}' '{"type":"final","text":"Overhear works."}'; sleep 30) \
  | ./overhear-ui /tmp/overhear-test /tmp/overhear-youtube
```

## Tests

```sh
uv run --with pytest pytest
```

The tests cover `recording.py`, YouTube imports (caption parsing, and importing with a fake
yt-dlp), the input mixer, streaming (against a fake Deepgram socket) and the
session lifecycle (Save, Discard, toggles, failures, quitting) with a fake UI and capture, so they
need no network, audio devices or Deepgram key.
