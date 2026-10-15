"""The app icon (ui/Icon.swift), rendered to PNG by a small Swift driver."""
import shutil
import struct
import subprocess
import zlib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "ui" / "Icon.swift", ROOT / "tests" / "icon_driver" / "main.swift"]


@pytest.fixture(scope="session")
def render(tmp_path_factory):
    if not shutil.which("swiftc"):
        pytest.skip("swiftc not installed")
    folder = tmp_path_factory.mktemp("icon")
    subprocess.run(["swiftc", "-swift-version", "5", "-o", str(folder / "icon_driver"),
                    *map(str, SOURCES)], check=True, capture_output=True)

    def run(size: int) -> "Pixels":
        png = folder / f"icon{size}.png"
        subprocess.run([str(folder / "icon_driver"), str(size), str(png)], check=True)
        return Pixels(png.read_bytes())
    return run


class Pixels:
    """Just enough of a PNG decoder for the driver's output: 8-bit RGBA, non-interlaced."""

    def __init__(self, png: bytes):
        chunks, at = {}, 8
        while at < len(png):
            length, kind = struct.unpack(">I4s", png[at:at + 8])
            chunks.setdefault(kind, b"")
            chunks[kind] += png[at + 8:at + 8 + length]
            at += 12 + length
        self.width, self.height, depth, color = struct.unpack(">IIBB", chunks[b"IHDR"][:10])
        assert (depth, color) == (8, 6), "expected 8-bit RGBA"
        raw = zlib.decompress(chunks[b"IDAT"])
        stride = self.width * 4
        self.rows, previous = [], bytearray(stride)
        for y in range(self.height):
            kind, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b = previous[i]
                c = previous[i - 4] if i >= 4 else 0
                line[i] = (line[i] + [0, a, b, (a + b) // 2, paeth(a, b, c)][kind]) & 0xFF
            self.rows.append(line)
            previous = line

    def alpha(self, x: int, y: int) -> int:
        return self.rows[y][x * 4 + 3]


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else b if pb <= pc else c


def test_renders_at_the_size_asked(render):
    icon = render(128)
    assert (icon.width, icon.height) == (128, 128)


def test_is_a_rounded_tile_on_the_macos_grid(render):
    icon = render(128)
    # Outside the tile (inset 100/1024 ≈ 12 px, rounded corners) is transparent; the middle isn't.
    for x, y in [(1, 1), (126, 1), (1, 126), (126, 126), (64, 2), (15, 15)]:
        assert icon.alpha(x, y) < 40, (x, y)
    for x, y in [(64, 64), (20, 64), (64, 20), (107, 64)]:
        assert icon.alpha(x, y) == 255, (x, y)
