import asyncio
import io
import json
import os
import subprocess

import pytest

import stream_system_audio
from recording import Recording
from stream_system_audio import stream

RATE = 16000
CHUNK = bytes(RATE // 10 * 2)  # 100 ms


class FakeDeepgram:
    """Takes audio, answers one final line once 5 chunks arrived, closes on CloseStream."""

    def __init__(self):
        self.audio: list[bytes] = []
        self.closed = asyncio.Event()

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        pass

    async def send(self, data):
        if isinstance(data, bytes):
            self.audio.append(data)
        elif json.loads(data)["type"] == "CloseStream":
            self.closed.set()

    async def close(self):
        self.closed.set()

    async def _messages(self):
        while len(self.audio) < 5:
            await asyncio.sleep(0.01)
        yield json.dumps({"type": "Results", "is_final": True, "start": 0.0, "duration": 0.5,
                          "channel": {"alternatives": [{"transcript": "hello there"}]}})
        await self.closed.wait()

    def __aiter__(self):
        return self._messages()


def test_stream_records_mixed_chunks_and_marks_mic_lines(tmp_path, monkeypatch):
    deepgram = FakeDeepgram()
    monkeypatch.setattr(stream_system_audio.websockets, "connect", lambda *a, **k: deepgram)

    async def source():
        while True:
            yield CHUNK, True  # the mic hears speech throughout
            await asyncio.sleep(0.01)

    async def show(kind, text):
        shown.append((kind, text))

    async def go():
        stop = asyncio.Event()
        task = asyncio.create_task(stream("key", source(), RATE, "Listening", show, rec, stop))
        while not rec.lines:
            await asyncio.sleep(0.01)
        stop.set()
        await task

    shown = []
    rec = Recording(tmp_path, RATE)
    asyncio.run(go())
    assert len(deepgram.audio) >= 5 and rec.duration >= 0.5
    assert rec.lines == [{"start": 0.0, "end": 0.5, "text": "hello there", "mic": True}]
    assert ("final", "hello there") in shown


def test_build_helper_links_plist_and_rebuilds_when_it_changes(tmp_path, monkeypatch):
    src, plist, binary = tmp_path / "a.swift", tmp_path / "Info.plist", tmp_path / "app"
    for path, mtime in [(src, 100), (binary, 200), (plist, 300)]:
        path.write_text("")
        os.utime(path, (mtime, mtime))
    runs = []
    monkeypatch.setattr(stream_system_audio.subprocess, "Popen", fake_swiftc(runs, []))

    stream_system_audio.build_helper([str(src)], str(binary))  # binary newer than the source
    assert runs == []
    stream_system_audio.build_helper([str(src)], str(binary), str(plist))  # plist newer
    [args] = runs
    assert args[-1] == str(src)
    assert ["-sectcreate", "__TEXT", "__info_plist", str(plist)] == [
        a for a in args if a != "-Xlinker"][-5:-1]


def fake_swiftc(runs, messages, code=0):
    """A stand-in for subprocess.Popen running `swiftc -parseable-output`: records its arguments,
    sends `messages` (dicts, or str lines) on stderr the way swiftc does, and exits with `code`."""
    def encode(message):
        if isinstance(message, str):
            return message.encode()
        body = json.dumps(message).encode()
        return str(len(body)).encode() + b"\n" + body + b"\n"

    class Popen:
        def __init__(self, args, stderr):
            runs.append(args)
            self.stderr = io.BytesIO(b"".join(map(encode, messages)))

        def wait(self):
            return code
    return Popen


def finished(name, output=""):
    return {"kind": "finished", "name": name, "exit-status": 0, "output": output}


def test_build_helper_shows_progress_and_compiler_output(tmp_path, monkeypatch, capsys):
    srcs = [str(tmp_path / f"{name}.swift") for name in "abc"]
    messages = [{"kind": "began", "name": "compile"}, finished("compile"),
                finished("compile", "a.swift:1:5: warning: unused\n"), finished("compile"),
                finished("link")]
    monkeypatch.setattr(stream_system_audio.subprocess, "Popen", fake_swiftc([], messages))

    stream_system_audio.build_helper(srcs, str(tmp_path / "app"))
    out = capsys.readouterr().out
    assert [part.rsplit(" ", 1)[1] for part in out.split("\r")[:-1]] == ["0%", "25%", "50%", "75%", "99%"]
    assert out.split("\r")[-1] == "Building app helper (one-time)... 100%\na.swift:1:5: warning: unused\n"


def test_build_helper_fails_with_the_errors(tmp_path, monkeypatch, capsys):
    messages = ["<unknown>:0: error: no such file\n",
                {**finished("compile", "a.swift:1:9: error: bad\n"), "exit-status": 1}]
    monkeypatch.setattr(stream_system_audio.subprocess, "Popen", fake_swiftc([], messages, code=1))

    with pytest.raises(subprocess.CalledProcessError):
        stream_system_audio.build_helper([str(tmp_path / "a.swift")], str(tmp_path / "app"))
    assert capsys.readouterr().out.endswith(
        "\n<unknown>:0: error: no such file\na.swift:1:9: error: bad\n")
