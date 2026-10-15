import asyncio
import json

import pytest

from recording import PARTIAL
from youtube import ImportFailed, Importer, import_video, lines_from_deepgram, lines_from_vtt

UPLOADER_VTT = """WEBVTT
Kind: captions
Language: en

00:00:01.200 --> 00:00:03.360
All right, so here we are, in front of the
elephants

00:00:05.318 --> 00:00:07.974
the cool thing &amp; such

1:00:07.974 --> 1:00:12.616 align:start
really long trunks
"""

# YouTube's auto-generated captions: word timing tags, and each cue repeats the line before.
AUTO_VTT = "\n".join([
    "WEBVTT", "Kind: captions", "Language: en", "",
    "00:00:00.000 --> 00:00:02.000 align:start position:0%", " ",
    "hello<00:00:00.500><c> world</c>", "",
    "00:00:02.000 --> 00:00:02.010 align:start position:0%", "hello world", " ", "",
    "00:00:02.010 --> 00:00:04.000 align:start position:0%", "hello world",
    "next<00:00:02.500><c> words</c>", "",
    "00:00:04.000 --> 00:00:04.010 align:start position:0%", "next words", " ", "",
])


def test_uploader_cues_become_one_line_each():
    assert lines_from_vtt(UPLOADER_VTT) == [
        {"start": 1.2, "end": 3.36, "text": "All right, so here we are, in front of the elephants"},
        {"start": 5.318, "end": 7.974, "text": "the cool thing & such"},
        {"start": 3607.974, "end": 3612.616, "text": "really long trunks"},
    ]


def test_auto_captions_drop_rolling_repeats_and_tags():
    assert lines_from_vtt(AUTO_VTT) == [
        {"start": 0.0, "end": 2.0, "text": "hello world"},
        {"start": 2.01, "end": 4.0, "text": "next words"},
    ]


def test_deepgram_utterances_become_lines():
    response = {"results": {"utterances": [
        {"start": 0.51234, "end": 2.0, "transcript": "Hi there."},
        {"start": 2.5, "end": 3.0, "transcript": ""},
    ]}}
    assert lines_from_deepgram(response) == [{"start": 0.512, "end": 2.0, "text": "Hi there."}]


def fake_download(*, video_id="abc123", captions=UPLOADER_VTT, error=None):
    async def download(url, folder, show):
        if error:
            (folder / "audio.m4a.part").write_bytes(b"half")
            raise ImportFailed(error)
        (folder / "audio.m4a").write_bytes(b"aac")
        (folder / "audio.info.json").write_text(json.dumps({
            "id": video_id, "title": "Me at the zoo", "channel": "jawed", "duration": 19,
            "webpage_url": f"https://www.youtube.com/watch?v={video_id}"}))
        if captions:
            (folder / "audio.en.vtt").write_text(captions)
        await show("import", "Downloading “Me at the zoo”… 100.0%")
    return download


def run_import(root, key=None, **kwargs):
    sent = []

    async def show(kind, text, **extra):
        sent.append((kind, text))

    async def go():
        return await import_video("https://youtu.be/abc123", root, key, show, **kwargs)
    return asyncio.run(go()), sent


def test_import_saves_audio_and_captions(tmp_path):
    (folder, text), sent = run_import(tmp_path, download=fake_download())
    assert folder == tmp_path / "abc123"
    assert text == "Added “Me at the zoo”"
    assert sorted(p.name for p in folder.iterdir()) == ["audio.m4a", "captions.json"]
    saved = json.loads((folder / "captions.json").read_text())
    assert saved["name"] == "Me at the zoo"
    assert saved["duration"] == 19
    assert saved["channel"] == "jawed"
    assert saved["source"] == "youtube"
    assert saved["url"] == "https://www.youtube.com/watch?v=abc123"
    assert saved["lines"][0]["text"].startswith("All right")
    assert list((tmp_path / PARTIAL).iterdir()) == []
    assert ("import", "Downloading “Me at the zoo”… 100.0%") in sent


def test_no_captions_uses_deepgram(tmp_path):
    calls = []

    def transcribe(audio, key):
        calls.append((audio.name, key))
        return [{"start": 0, "end": 1, "text": "Hi."}]

    (folder, _), sent = run_import(tmp_path, key="k", download=fake_download(captions=None),
                                   transcribe=transcribe)
    assert calls == [("audio.m4a", "k")]
    assert json.loads((folder / "captions.json").read_text())["lines"] == [
        {"start": 0, "end": 1, "text": "Hi."}]
    assert sent[-1] == ("import", "Transcribing “Me at the zoo” with Deepgram…")


def test_no_captions_and_no_key_fails_and_cleans_up(tmp_path):
    with pytest.raises(ImportFailed, match="No English captions"):
        run_import(tmp_path, download=fake_download(captions=None))
    assert list(tmp_path.iterdir()) == [tmp_path / PARTIAL]
    assert list((tmp_path / PARTIAL).iterdir()) == []


def test_download_failure_cleans_up(tmp_path):
    with pytest.raises(ImportFailed, match="This video is unavailable"):
        run_import(tmp_path, download=fake_download(error="This video is unavailable"))
    assert list((tmp_path / PARTIAL).iterdir()) == []


def test_already_imported_keeps_existing(tmp_path):
    existing = tmp_path / "abc123"
    existing.mkdir()
    (existing / "captions.json").write_text("{}")
    (folder, text), _ = run_import(tmp_path, download=fake_download())
    assert folder == existing
    assert text == "Already added “Me at the zoo”"
    assert (existing / "captions.json").read_text() == "{}"
    assert list((tmp_path / PARTIAL).iterdir()) == []


def test_importer_reports_each_import_in_turn(tmp_path):
    sent = []

    async def show(kind, text, **extra):
        sent.append((kind, text, extra))

    async def go():
        importer = Importer(tmp_path, None, show, download=fake_download())
        importer.add("https://youtu.be/abc123")
        importer.add("https://youtu.be/abc123")
        while len([s for s in sent if s[0] == "imported"]) < 2:
            await asyncio.sleep(0)
        await importer.close()

    asyncio.run(go())
    done = [s for s in sent if s[0] == "imported"]
    assert [text for _, text, _ in done] == ["Added “Me at the zoo”", "Already added “Me at the zoo”"]
    assert done[0][2] == {"folder": str(tmp_path / "abc123")}


def test_importer_reports_failures_and_keeps_going(tmp_path):
    sent = []

    async def show(kind, text, **extra):
        sent.append((kind, text))

    async def go():
        importer = Importer(tmp_path, None, show, download=fake_download(error="Bad link"))
        importer.add("nope")
        while not any(kind == "import_error" for kind, _ in sent):
            await asyncio.sleep(0)
        await importer.close()

    asyncio.run(go())
    assert ("import_error", "Bad link") in sent
