import json
import subprocess
import wave

from recording import PARTIAL, Recording, cleanup_partials

RATE = 16000


def tone(seconds: float) -> bytes:
    # Not silence, so afconvert has something real to encode
    n = int(RATE * seconds)
    return b"".join((((i % 40) - 20) * 800).to_bytes(2, "little", signed=True) for i in range(n))


def test_write_produces_wav_with_right_rate_and_length(tmp_path):
    rec = Recording(tmp_path, RATE)
    rec.write(tone(0.5))
    rec.write(tone(0.25))
    assert rec.duration == 0.75
    rec._wav.close()
    with wave.open(str(rec.dir / "audio.wav")) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (RATE, 1, 2)
        assert w.getnframes() == int(RATE * 0.75)


def test_add_line_stores_end_time():
    rec = Recording.__new__(Recording)
    rec.lines = []
    rec.add_line(1.5, 2.25, "hello")
    assert rec.lines == [{"start": 1.5, "end": 3.75, "text": "hello"}]


def test_save_writes_m4a_and_captions(tmp_path):
    rec = Recording(tmp_path, RATE)
    rec.write(tone(1))
    rec.add_line(0.1, 0.8, "first")
    path = rec.save()

    assert path == tmp_path / rec.stamp
    assert sorted(p.name for p in path.iterdir()) == ["audio.m4a", "captions.json"]
    captions = json.loads((path / "captions.json").read_text())
    assert captions == {"started_at": rec.started_at, "duration": 1.0,
                        "lines": [{"start": 0.1, "end": 0.9, "text": "first"}]}
    assert list((tmp_path / PARTIAL).iterdir()) == []


def test_save_without_audio_leaves_nothing(tmp_path):
    rec = Recording(tmp_path, RATE)
    assert rec.save() is None
    assert list(tmp_path.iterdir()) == [tmp_path / PARTIAL]
    assert list((tmp_path / PARTIAL).iterdir()) == []


def test_save_keeps_wav_when_conversion_fails(tmp_path, monkeypatch):
    def fail(*args, **kwargs):
        raise subprocess.CalledProcessError(1, "afconvert")
    monkeypatch.setattr(subprocess, "run", fail)
    rec = Recording(tmp_path, RATE)
    rec.write(tone(0.5))
    path = rec.save()
    assert sorted(p.name for p in path.iterdir()) == ["audio.wav", "captions.json"]


def test_discard_leaves_nothing(tmp_path):
    rec = Recording(tmp_path, RATE)
    rec.write(tone(0.5))
    rec.discard()
    assert list((tmp_path / PARTIAL).iterdir()) == []


def test_worth_keeping(tmp_path):
    rec = Recording(tmp_path, RATE)
    assert not rec.worth_keeping()
    rec.write(tone(2))
    assert not rec.worth_keeping()
    rec.write(tone(1))
    assert rec.worth_keeping()
    rec.discard()

    rec = Recording(tmp_path, RATE)
    rec.add_line(0, 1, "short but captioned")
    assert rec.worth_keeping()


def test_cleanup_partials_keeps_finished_recordings(tmp_path):
    done = Recording(tmp_path, RATE)
    done.write(tone(0.5))
    saved = done.save()
    Recording(tmp_path, RATE).write(tone(0.5))  # never saved, like after a crash

    cleanup_partials(tmp_path)
    assert list(tmp_path.iterdir()) == [saved]


def test_same_second_recordings_get_distinct_folders(tmp_path):
    rec = Recording(tmp_path, RATE)
    rec.write(tone(0.2))
    (tmp_path / rec.stamp).mkdir()  # an earlier recording from the same second
    assert rec.save() == tmp_path / f"{rec.stamp}-2"
