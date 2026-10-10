"""One live-caption session on disk: the audio sent to Deepgram plus its final captions.

While recording, everything lives in `<root>/.partial/<stamp>/`. Saving converts the WAV to AAC
and moves the folder to `<root>/<stamp>/`:

    <stamp>/audio.m4a       the exact audio Deepgram heard (audio.wav if conversion failed)
    <stamp>/captions.json   {"started_at", "duration", "lines": [{"start", "end", "text"}, ...]}

Line times come straight from Deepgram, which counts seconds of audio received, so they are
positions in audio.m4a. That's what keeps replay in lockstep.
"""
import json
import shutil
import subprocess
import sys
import wave
from datetime import datetime
from pathlib import Path

RECORDINGS_DIR = Path.home() / "Library" / "Application Support" / "Overhear" / "recordings"
PARTIAL = ".partial"
MIN_KEEP_SECONDS = 3


def cleanup_partials(root: Path = RECORDINGS_DIR):
    """Deletes sessions left half-written by a crash or hard kill."""
    shutil.rmtree(root / PARTIAL, ignore_errors=True)


class Recording:
    def __init__(self, root: Path, sample_rate: int):
        self.root = root
        started = datetime.now().astimezone()
        self.started_at = started.isoformat(timespec="seconds")
        self.stamp = started.strftime("%Y-%m-%d_%H-%M-%S")
        self.dir = root / PARTIAL / self.stamp
        self.dir.mkdir(parents=True)
        self.sample_rate = sample_rate
        self.lines: list[dict] = []
        self._frames = 0
        self._wav = wave.open(str(self.dir / "audio.wav"), "wb")
        self._wav.setnchannels(1)
        self._wav.setsampwidth(2)
        self._wav.setframerate(sample_rate)

    def write(self, chunk: bytes):
        self._wav.writeframes(chunk)
        self._frames += len(chunk) // 2

    def add_line(self, start: float, duration: float, text: str):
        self.lines.append({"start": round(start, 3), "end": round(start + duration, 3), "text": text})

    @property
    def duration(self) -> float:
        return self._frames / self.sample_rate

    def worth_keeping(self) -> bool:
        """Whether an unasked-for ending (Ctrl+C, UI quit) should still save this session."""
        return bool(self.lines) or self.duration >= MIN_KEEP_SECONDS

    def save(self) -> Path | None:
        """Finishes the recording and returns its folder, or None if no audio was captured.

        For example, 90 s of audio and two lines end up as
        <root>/2026-10-09_14-30-05/{audio.m4a, captions.json}.
        """
        self._wav.close()
        if self._frames == 0:
            self.discard()
            return None
        wav = self.dir / "audio.wav"
        try:
            # Default bitrate: ~64 kbps at 48 kHz; a fixed -b fails at low device rates.
            subprocess.run(["afconvert", "-f", "m4af", "-d", "aac",
                            str(wav), str(self.dir / "audio.m4a")],
                           check=True, capture_output=True)
            wav.unlink()
        except (OSError, subprocess.CalledProcessError) as e:
            # Replay plays the WAV instead; it's just larger.
            (self.dir / "audio.m4a").unlink(missing_ok=True)
            print(f"Could not convert audio to AAC, keeping WAV: {e}", file=sys.stderr)
        (self.dir / "captions.json").write_text(json.dumps({
            "started_at": self.started_at,
            "duration": round(self.duration, 3),
            "lines": self.lines,
        }, indent=1))
        # Two sessions within the same second get distinct folders.
        dest = self.root / self.stamp
        n = 2
        while dest.exists():
            dest = self.root / f"{self.stamp}-{n}"
            n += 1
        self.dir.rename(dest)
        return dest

    def discard(self):
        self._wav.close()
        shutil.rmtree(self.dir, ignore_errors=True)
