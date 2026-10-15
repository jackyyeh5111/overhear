"""Replay's line regrouping (ui/Lines.swift), run through a small Swift driver."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "ui" / "Recordings.swift", ROOT / "ui" / "Lines.swift",
           ROOT / "tests" / "lines_driver" / "main.swift"]


@pytest.fixture(scope="session")
def driver(tmp_path_factory):
    if not shutil.which("swiftc"):
        pytest.skip("swiftc not installed")
    binary = tmp_path_factory.mktemp("lines") / "lines_driver"
    subprocess.run(["swiftc", "-swift-version", "5", "-o", str(binary), *map(str, SOURCES)],
                   check=True, capture_output=True)
    return binary


@pytest.fixture
def regroup(driver):
    def run(lines: list[dict], seconds: float | None) -> list[dict]:
        out = subprocess.run([str(driver)], input=json.dumps({"lines": lines, "seconds": seconds}),
                             check=True, capture_output=True, text=True).stdout
        return [{**line, "start": round(line["start"], 2), "end": round(line["end"], 2)}
                for line in json.loads(out)]
    return run


def line(start, end, text, mic=False):
    return {"start": start, "end": end, "text": text, **({"mic": True} if mic else {})}


def texts(lines):
    return [line["text"] for line in lines]


def test_none_keeps_the_original_lines(regroup):
    lines = [line(0.5, 1.5, "Hello there."), line(1.5, 9, "A long line.", mic=True)]
    assert regroup(lines, None) == lines


def test_word_times_are_spread_by_length(regroup):
    assert regroup([line(0, 8, "aaa bbbbbbb")], 1) == [line(0, 2.67, "aaa"), line(2.67, 8, "bbbbbbb")]


def test_short_lines_merge(regroup):
    lines = [line(0, 2, "a"), line(2, 4, "b"), line(4, 6, "c")]
    assert regroup(lines, 5) == [line(0, 6, "a b c")]


def test_long_line_splits_at_one_and_a_half_times_without_sentence_ends(regroup):
    words = " ".join(f"w{i}" for i in range(10))  # each word 3 characters with its space: 1 s
    assert regroup([line(0, 10, words)], 3) == [line(0, 5, "w0 w1 w2 w3 w4"), line(5, 10, "w5 w6 w7 w8 w9")]


def test_a_sentence_end_past_the_target_ends_the_line(regroup):
    # 0.5 s per character: "aaaaaa." ends at 3.5 s, before the 4.5 s limit
    lines = [line(0, 3.5, "aaaaaa."), line(3.5, 10, "bbbb cccc dddd")]
    assert texts(regroup(lines, 3)) == ["aaaaaa.", "bbbb cccc dddd"]


def test_a_sentence_end_before_the_target_does_not(regroup):
    lines = [line(0, 1, "Hi."), line(1, 3, "Again.")]
    assert texts(regroup(lines, 3)) == ["Hi. Again."]


def test_closing_quotes_still_end_a_sentence(regroup):
    lines = [line(0, 4, 'She said "stop."'), line(4, 6, "Then left.")]
    assert texts(regroup(lines, 3)) == ['She said "stop."', "Then left."]


def test_a_pause_of_two_seconds_breaks_even_a_long_target(regroup):
    lines = [line(0, 1, "one"), line(3, 4, "two")]
    assert texts(regroup(lines, 30)) == ["one", "two"]


def test_a_shorter_pause_does_not(regroup):
    lines = [line(0, 1, "one"), line(2.9, 4, "two")]
    assert texts(regroup(lines, 30)) == ["one two"]


def test_mic_marks_follow_the_words(regroup):
    merged = regroup([line(0, 1, "me", mic=True), line(1, 2, "them")], 5)
    assert merged == [line(0, 2, "me them", mic=True)]
    split = regroup([line(0, 10, " ".join(f"w{i}" for i in range(10)), mic=True)], 3)
    assert [piece.get("mic") for piece in split] == [True, True]
    assert "mic" not in regroup([line(0, 1, "plain")], 5)[0]
