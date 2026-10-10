import asyncio
import json

from recording import PARTIAL, Recording
from stream_system_audio import session

RATE = 16000
SECOND = bytes(RATE * 2)


class FakeUI:
    """Scripted clicks in, recorded messages out; None in the script means the app quit.

    A click is a type ("save") or a whole event ({"type": "input", "name": "mic", "on": True}).
    """

    def __init__(self, *events: str | dict | None):
        self.events: asyncio.Queue = asyncio.Queue()
        for e in events:
            self.click(e)
        self.sent: list[tuple[str, str]] = []

    def click(self, event: str | dict | None):
        self.events.put_nowait({"type": event} if isinstance(event, str) else event)

    async def next_event(self):
        return await self.events.get()

    async def send(self, kind, text, **extra):
        self.sent.append((kind, text))


async def capture(rec, stop, *, seconds=1, fail=None, drain_line=None):
    """Records audio and a line, then waits for stop like stream() does."""
    for i in range(seconds):
        rec.write(SECOND)
        rec.add_line(i, 0.5, f"line {i}")
    await asyncio.sleep(0)
    if fail:
        raise fail
    await stop.wait()
    if drain_line:
        rec.add_line(seconds, 0.5, drain_line)  # Deepgram's last final, after audio stopped


def saved(root):
    return [p for p in root.iterdir() if p.name != PARTIAL]


def run_session(root, ui, **capture_kwargs):
    async def go():
        rec = Recording(root, RATE)
        stop = asyncio.Event()
        await session(ui, rec, capture(rec, stop, **capture_kwargs), stop)
    asyncio.run(go())


def test_save_keeps_recording_and_ends(tmp_path):
    ui = FakeUI("save")
    run_session(tmp_path, ui, seconds=2)
    [path] = saved(tmp_path)
    assert len(json.loads((path / "captions.json").read_text())["lines"]) == 2
    assert ui.sent[-1] == ("ended", "")


def test_discard_leaves_nothing_and_ends(tmp_path):
    ui = FakeUI("discard")
    run_session(tmp_path, ui)
    assert saved(tmp_path) == []
    assert list((tmp_path / PARTIAL).iterdir()) == []
    assert ui.sent[-1] == ("ended", "")


def test_capture_failure_waits_for_choice_then_saves(tmp_path):
    ui = FakeUI()

    async def go():
        rec = Recording(tmp_path, RATE)
        stop = asyncio.Event()
        task = asyncio.create_task(
            session(ui, rec, capture(rec, stop, fail=RuntimeError("network down")), stop))
        await asyncio.sleep(0.05)
        assert not task.done()  # still waiting for the user to decide
        assert ("error", "Error: network down") in ui.sent
        ui.click("save")
        await task
    asyncio.run(go())
    assert len(saved(tmp_path)) == 1


def test_ui_quit_autosaves_when_worth_keeping(tmp_path):
    ui = FakeUI(None)
    run_session(tmp_path, ui)
    assert len(saved(tmp_path)) == 1
    assert ("ended", "") not in ui.sent  # nobody to tell


def test_ui_quit_discards_when_nothing_worth_keeping(tmp_path):
    ui = FakeUI(None)
    run_session(tmp_path, ui, seconds=0)
    assert saved(tmp_path) == []


def test_ctrl_c_autosaves(tmp_path):
    async def go():
        rec = Recording(tmp_path, RATE)
        stop = asyncio.Event()
        task = asyncio.create_task(session(FakeUI(), rec, capture(rec, stop), stop))
        await asyncio.sleep(0.05)
        task.cancel()  # what asyncio.run does on Ctrl+C
        try:
            await task
        except asyncio.CancelledError:
            pass
    asyncio.run(go())
    assert len(saved(tmp_path)) == 1


def test_stop_drains_last_lines_into_recording(tmp_path):
    ui = FakeUI("save")
    run_session(tmp_path, ui, drain_line="the last sentence")
    [path] = saved(tmp_path)
    lines = json.loads((path / "captions.json").read_text())["lines"]
    assert lines[-1]["text"] == "the last sentence"


class FakeInputs:
    def __init__(self):
        self.on = {"system"}

    def set(self, name, on):
        (self.on.add if on else self.on.discard)(name)


def test_toggles_reach_inputs_during_session(tmp_path):
    ui = FakeUI({"type": "input", "name": "mic", "on": True},
                {"type": "input", "name": "system", "on": False}, "save")
    inputs = FakeInputs()

    async def go():
        rec = Recording(tmp_path, RATE)
        stop = asyncio.Event()
        await session(ui, rec, capture(rec, stop), stop, inputs)
    asyncio.run(go())
    assert inputs.on == {"mic"}
    assert ("status", "Listening to microphone") in ui.sent
