import asyncio
from array import array

from inputs import SPEECH_RMS, Buffer, Inputs, is_speech, mix

RATE = 16000
CHUNK = RATE // 10 * 2  # 100 ms of 16-bit mono


def pcm(*samples: int) -> bytes:
    return array("h", samples).tobytes()


def tone(level: int, seconds: float = 0.1) -> bytes:
    return pcm(*[level, -level] * int(RATE * seconds / 2))


def test_mix_adds_and_clips():
    assert mix([pcm(1000, -30000), pcm(500, -5000)], 4) == pcm(1500, -32768)
    assert mix([pcm(7, 8)], 4) == pcm(7, 8)
    assert mix([], 4) == bytes(4)


def test_is_speech_compares_loudness():
    assert is_speech(tone(SPEECH_RMS * 2))
    assert not is_speech(tone(SPEECH_RMS // 4))


def test_buffer_waits_until_primed_and_after_running_dry():
    buffer = Buffer(RATE)
    buffer.put(tone(100, 0.1))
    assert buffer.take(CHUNK) is None  # 100 ms < the 150 ms it waits for
    buffer.put(tone(100, 0.05))
    assert buffer.take(CHUNK) == tone(100, 0.1)
    assert buffer.take(CHUNK) == tone(100, 0.05) + bytes(CHUNK // 2)  # ran dry: padded
    assert buffer.take(CHUNK) is None  # refilling


def test_buffer_drops_audio_that_falls_too_far_behind():
    buffer = Buffer(RATE)
    buffer.put(tone(100, 2))
    assert len(buffer.data) == int(RATE * 0.15) * 2


async def endless(level: int):
    while True:
        yield tone(level, 0.02)
        await asyncio.sleep(0.02)


def take(inputs: Inputs, count: int, toggle_at: int | None = None, toggle=None):
    async def go():
        out = []
        chunks = inputs.chunks()
        async for item in chunks:
            out.append(item)
            if len(out) == toggle_at:
                toggle()
            if len(out) == count:
                await chunks.aclose()
                return out
    return asyncio.run(go())


def test_inputs_mix_what_is_on_and_flag_mic_speech():
    async def ignore(name, error):
        pass

    inputs = Inputs(RATE, {"system": lambda: endless(300), "mic": lambda: endless(SPEECH_RMS * 2)},
                    {"system"}, ignore)
    out = take(inputs, 12, toggle_at=4, toggle=lambda: inputs.set("mic", True))
    levels = [max(array("h", chunk)) for chunk, _ in out]
    assert levels[3] == 300 and not out[3][1]          # system only
    assert levels[-1] == 300 + SPEECH_RMS * 2 and out[-1][1]  # both, and the mic heard speech
    assert inputs.tasks == {}  # captures stop when the stream does


def test_failed_input_is_turned_off_and_reported():
    failures = []

    async def broken():
        raise OSError("no mic")
        yield

    async def record(name, error):
        failures.append((name, str(error)))

    inputs = Inputs(RATE, {"system": lambda: endless(300), "mic": broken}, {"system", "mic"}, record)
    out = take(inputs, 3)
    assert failures == [("mic", "no mic")]
    assert inputs.on == {"system"}
    assert all(len(chunk) == CHUNK for chunk, _ in out)
