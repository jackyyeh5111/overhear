"""Replay's loop range (PlayRange in ui/PlayRange.swift), run through a small Swift driver."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "ui" / "Recordings.swift", ROOT / "ui" / "PlayRange.swift",
           ROOT / "tests" / "play_range_driver" / "main.swift"]


@pytest.fixture(scope="session")
def driver(tmp_path_factory):
    if not shutil.which("swiftc"):
        pytest.skip("swiftc not installed")
    binary = tmp_path_factory.mktemp("play_range") / "play_range_driver"
    subprocess.run(["swiftc", "-swift-version", "5", "-o", str(binary), *map(str, SOURCES)],
                   check=True, capture_output=True)
    return binary


@pytest.fixture
def run(driver):
    """Runs the commands against a fresh range; returns each answer."""
    def go(*commands):
        out = subprocess.run([str(driver)], input=json.dumps(commands),
                             check=True, capture_output=True, text=True).stdout
        return json.loads(out)
    return go


def line(start, end):
    return {"start": start, "end": end, "text": "…"}


L1, L2, L3, L4, L5 = line(0, 4), line(4, 8), line(8, 12), line(12, 16), line(16, 20)


def test_lines_from_start_to_end_are_in_it(run):
    assert run(["start", L2], ["end", L4], *[["contains", l] for l in [L1, L2, L3, L4, L5]]) == [
        True, True, False, True, True, True, False]


def test_one_line_can_be_both_ends(run):
    assert run(["start", L3], ["end", L3], ["contains", L2], ["contains", L3], ["contains", L4]) == [
        True, True, False, True, False]


def test_a_lone_end_marks_just_its_line(run):
    assert run(["start", L3], ["contains", L2], ["contains", L3], ["contains", L4]) == [
        True, False, True, False]
    assert run(["end", L3], ["contains", L2], ["contains", L3], ["contains", L4]) == [
        True, False, True, False]


def test_a_start_after_the_end_is_refused(run):
    assert run(["start", L2], ["end", L3], ["start", L4], ["contains", L2], ["contains", L4]) == [
        True, True, False, True, False]


def test_an_end_before_the_start_is_refused(run):
    assert run(["start", L3], ["end", L4], ["end", L2], ["contains", L4], ["contains", L2]) == [
        True, True, False, True, False]


def test_running_past_the_end_is_noticed_once(run):
    assert run(["start", L2], ["end", L3],
               ["ran_past_end", 11.9, 12.05],  # crossed the end
               ["ran_past_end", 12.0, 12.1],   # already past it
               ["ran_past_end", 10.0, 10.1],   # not there yet
               ) == [True, True, True, False, False]


def test_a_lone_end_never_loops(run):
    assert run(["end", L3], ["ran_past_end", 11.9, 12.05]) == [True, False]
