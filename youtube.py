"""Imports a YouTube video as something Replay can play: its audio plus a timed transcript.

Each import is a folder in YOUTUBE_DIR, laid out like a recording (see recording.py):

    <video id>/audio.m4a       YouTube's AAC audio stream, as downloaded
    <video id>/captions.json   {"name", "started_at", "duration", "lines": [{"start", "end", "text"}],
                                "source": "youtube", "url", "channel"}

"name" is the video's title and "started_at" is when it was imported, so the newest import is
listed first. Lines come from the video's English captions: the uploader's when there are any,
else YouTube's auto-generated ones. A video with neither is transcribed by Deepgram instead.

While downloading, everything lives in `<root>/.partial/<random>/`, so cleanup_partials() clears
what a crash leaves behind.
"""
import asyncio
import html
import json
import re
import shutil
import ssl
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode

import certifi

from recording import PARTIAL, RECORDINGS_DIR

YOUTUBE_DIR = RECORDINGS_DIR.parent / "youtube"
LANGS = ["en", "en-US", "en-GB"]  # caption languages, most preferred first
TIME = re.compile(r"(?:(\d+):)?(\d+):(\d+)\.(\d+)")
TAG = re.compile(r"<[^>]*>")


class ImportFailed(Exception):
    pass


def seconds(stamp: str) -> float:
    """A VTT timestamp in seconds: "01:02:03.500" → 3723.5, "02:03.500" → 123.5."""
    h, m, s, frac = TIME.fullmatch(stamp).groups()
    return int(h or 0) * 3600 + int(m) * 60 + int(s) + int(frac) / 10 ** len(frac)


def lines_from_vtt(vtt: str) -> list[dict]:
    """One line per caption cue, with the cue's start and end.

    A cue's wrapped lines are joined into one. Auto-generated captions roll: each cue first
    repeats the last line of the cue before, so a line the previous cue ended with is dropped.
    E.g. cues "hello world" (0–2 s), then "hello world" + "next words" (2–4 s) →
    "hello world" 0–2 s and "next words" 2–4 s.
    """
    out = []
    previous_last = None
    # Cues are separated by empty lines; auto captions also have lines of just a space inside cues.
    for block in re.split(r"\n{2,}", vtt.replace("\r\n", "\n")):
        rows = block.strip("\n").split("\n")
        timing = next((i for i, row in enumerate(rows) if "-->" in row), None)
        if timing is None:
            continue  # the WEBVTT header, a NOTE or a STYLE block
        start, _, rest = rows[timing].partition("-->")
        end = rest.split()[0] if rest.split() else ""
        texts = [html.unescape(TAG.sub("", row)).strip() for row in rows[timing + 1:]]
        texts = [t for t in texts if t]
        if not texts:
            continue
        last = texts[-1]
        while texts and texts[0] == previous_last:
            texts.pop(0)
        previous_last = last
        if texts:
            out.append({"start": round(seconds(start.strip()), 3), "end": round(seconds(end), 3),
                        "text": " ".join(texts)})
    return out


def lines_from_deepgram(response: dict) -> list[dict]:
    """Deepgram's utterances as lines, e.g. {"start": 0.5, "end": 2, "transcript": "Hi."} → one."""
    return [{"start": round(u["start"], 3), "end": round(u["end"], 3), "text": u["transcript"]}
            for u in response.get("results", {}).get("utterances", []) if u["transcript"]]


def transcribe(audio: Path, key: str) -> list[dict]:
    """Sends `audio` to Deepgram's prerecorded API and returns its lines. Blocks."""
    params = {"model": "nova-3", "language": "en", "smart_format": "true", "utterances": "true"}
    request = urllib.request.Request(
        "https://api.deepgram.com/v1/listen?" + urlencode(params), data=audio.read_bytes(),
        headers={"Authorization": f"Token {key}", "Content-Type": "audio/mp4"})
    try:
        with urllib.request.urlopen(
                request, context=ssl.create_default_context(cafile=certifi.where())) as response:
            return lines_from_deepgram(json.load(response))
    except urllib.error.URLError as e:
        raise ImportFailed(f"Deepgram failed: {e}") from e


async def download(url: str, folder: Path, show):
    """Runs yt-dlp to put audio.m4a, audio.info.json and English captions (audio.<lang>.vtt) in
    `folder`, reporting progress as it goes. Raises ImportFailed with yt-dlp's error."""
    proc = await asyncio.create_subprocess_exec(
        sys.executable, "-m", "yt_dlp", "--no-playlist", "--match-filter", "!is_live",
        "-f", "bestaudio[ext=m4a]",
        "--write-subs", "--write-auto-subs", "--sub-langs", ",".join(LANGS), "--sub-format", "vtt",
        "--write-info-json", "--newline", "--no-warnings",
        "--progress-template", "download:progress\t%(info.title)s\t%(progress._percent_str)s",
        "-o", "audio.%(ext)s", url,
        cwd=folder, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    error = None
    try:
        while raw := await proc.stdout.readline():
            line = raw.decode(errors="replace").strip()
            if line.startswith("progress\t"):
                _, title, percent = line.split("\t")
                await show("import", f"Downloading “{title}”… {percent.strip()}")
            elif line.startswith("ERROR:"):
                # E.g. "ERROR: [youtube] abc: This video is unavailable" → "This video is unavailable"
                error = re.sub(r"^ERROR:\s*(\[[^]]*\]\s*[^:]*:\s*)?", "", line)
        await proc.wait()
    finally:
        if proc.returncode is None:
            proc.terminate()
            await proc.wait()
    if proc.returncode != 0 or not (folder / "audio.m4a").exists():
        raise ImportFailed(error or "Download failed")


async def import_video(url: str, root: Path, key: str | None, show,
                       download=download, transcribe=transcribe) -> tuple[Path, str]:
    """Downloads `url` into `root`; returns its folder and what to tell the user.

    E.g. https://youtu.be/jNQXAC9IVRw → (<root>/jNQXAC9IVRw, "Added “Me at the zoo”"). A video
    already imported keeps its folder, and nothing new is saved.
    """
    started_at = datetime.now().astimezone().isoformat(timespec="seconds")
    folder = root / PARTIAL / uuid.uuid4().hex
    folder.mkdir(parents=True)
    try:
        await show("import", "Getting the video…")
        await download(url, folder, show)
        info = json.loads((folder / "audio.info.json").read_text())
        title = info.get("title") or info["id"]
        dest = root / info["id"]
        if dest.exists():
            return dest, f"Already added “{title}”"
        captions = next((folder / f"audio.{lang}.vtt" for lang in LANGS
                         if (folder / f"audio.{lang}.vtt").exists()), None)
        if captions:
            lines = lines_from_vtt(captions.read_text())
        elif key:
            await show("import", f"Transcribing “{title}” with Deepgram…")
            lines = await asyncio.to_thread(transcribe, folder / "audio.m4a", key)
        else:
            raise ImportFailed("No English captions, and no Deepgram key to transcribe it")
        (folder / "captions.json").write_text(json.dumps({
            "name": title,
            "started_at": started_at,
            "duration": info.get("duration") or (lines[-1]["end"] if lines else 0),
            "lines": lines,
            "source": "youtube",
            "url": info.get("webpage_url") or url,
            "channel": info.get("channel") or info.get("uploader"),
        }, indent=1))
        for extra in folder.iterdir():
            if extra.name not in ("audio.m4a", "captions.json"):
                extra.unlink()
        folder.rename(dest)
        return dest, f"Added “{title}”"
    finally:
        shutil.rmtree(folder, ignore_errors=True)


class Importer:
    """Imports links one at a time, in the background, telling the UI how each one goes:

    {"type": "import", "text": "Downloading “Title”… 42%"}            progress
    {"type": "imported", "text": "Added “Title”", "folder": "<path>"}  done
    {"type": "import_error", "text": "This video is unavailable"}
    """

    def __init__(self, root: Path, key: str | None, show, **import_kwargs):
        self.root = root
        self.key = key
        self.show = show
        self.import_kwargs = import_kwargs
        self.queue: asyncio.Queue[str] = asyncio.Queue()
        self.task = asyncio.create_task(self._work())

    def add(self, url: str):
        self.queue.put_nowait(url)

    async def close(self):
        self.task.cancel()
        await asyncio.gather(self.task, return_exceptions=True)

    async def _work(self):
        while True:
            url = await self.queue.get()
            try:
                folder, text = await import_video(url, self.root, self.key, self.show,
                                                  **self.import_kwargs)
            except ImportFailed as e:
                await self.show("import_error", str(e))
            except Exception as e:  # anything unexpected still ends this import, not the queue
                await self.show("import_error", f"Import failed: {e}")
            else:
                print(f"\r\033[KImported → {folder}")
                await self.show("imported", text, folder=str(folder))
