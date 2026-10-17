"""Remembering where you left off in each recording (LeftOff in ui/LeftOff.swift), run through a
small Swift driver against a throwaway preferences file."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "ui" / "LeftOff.swift", ROOT / "tests" / "left_off_driver" / "main.swift"]


@pytest.fixture(scope="session")
def driver(tmp_path_factory):
    if not shutil.which("swiftc"):
        pytest.skip("swiftc not installed")
    binary = tmp_path_factory.mktemp("left_off") / "left_off_driver"
    subprocess.run(["swiftc", "-swift-version", "5", "-o", str(binary), *map(str, SOURCES)],
                   check=True, capture_output=True)
    return binary


@pytest.fixture
def run(driver, tmp_path):
    """Runs the commands against fresh preferences; returns each "time" answer."""
    def go(*commands):
        out = subprocess.run([str(driver), str(tmp_path / "prefs.plist")], input=json.dumps(commands),
                             check=True, capture_output=True, text=True).stdout
        return json.loads(out)
    return go


def test_mid_recording_is_remembered_per_folder(run):
    assert run(["save", "/r/a", 754.5, 2700.0], ["time", "/r/a"], ["time", "/r/b"]) == [754.5, None]


@pytest.mark.parametrize("time", [0.0, 3.0, 2697.0, 2700.0])
def test_near_either_end_forgets(run, time):
    assert run(["save", "/r/a", 754.0, 2700.0], ["save", "/r/a", time, 2700.0], ["time", "/r/a"]) == [None]


def test_prune_forgets_deleted_folders(run, tmp_path):
    kept = tmp_path / "kept"
    kept.mkdir()
    gone = tmp_path / "gone"
    assert run(["save", str(kept), 60.0, 600.0], ["save", str(gone), 60.0, 600.0], ["prune"],
               ["time", str(kept)], ["time", str(gone)]) == [60.0, None]
