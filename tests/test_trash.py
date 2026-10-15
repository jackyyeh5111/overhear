"""Putting a trashed recording back (Recording.putBack in ui/Recordings.swift), run through a
small Swift driver. Only temp folders are used; the real Trash is never touched."""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "ui" / "Recordings.swift", ROOT / "tests" / "trash_driver" / "main.swift"]


@pytest.fixture(scope="session")
def driver(tmp_path_factory):
    if not shutil.which("swiftc"):
        pytest.skip("swiftc not installed")
    binary = tmp_path_factory.mktemp("trash") / "trash_driver"
    subprocess.run(["swiftc", "-swift-version", "5", "-o", str(binary), *map(str, SOURCES)],
                   check=True, capture_output=True)
    return binary


def put_back(driver, trashed, folder):
    return subprocess.run([str(driver), str(trashed), str(folder)], capture_output=True, text=True)


def folder_with(path: Path, text: str) -> Path:
    path.mkdir(parents=True)
    (path / "captions.json").write_text(text)
    return path


def test_put_back_moves_folder_home(driver, tmp_path):
    trashed = folder_with(tmp_path / "Trash" / "2026-10-09_14-30-05 2", "mine")
    home = tmp_path / "recordings" / "2026-10-09_14-30-05"
    home.parent.mkdir()
    assert put_back(driver, trashed, home).returncode == 0
    assert (home / "captions.json").read_text() == "mine"
    assert not trashed.exists()


def test_put_back_never_overwrites(driver, tmp_path):
    trashed = folder_with(tmp_path / "Trash" / "abc123", "old")
    home = folder_with(tmp_path / "youtube" / "abc123", "new")
    result = put_back(driver, trashed, home)
    assert result.returncode == 1
    assert "already" in result.stdout
    assert (home / "captions.json").read_text() == "new"
    assert (trashed / "captions.json").read_text() == "old"


def test_put_back_after_trash_emptied_fails(driver, tmp_path):
    home = tmp_path / "recordings" / "2026-10-09_14-30-05"
    home.parent.mkdir()
    result = put_back(driver, tmp_path / "Trash" / "gone", home)
    assert result.returncode == 1
    assert not home.exists()
