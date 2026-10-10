"""Mixes the inputs that are turned on (system audio, microphone) into one live audio stream.

Each input runs only while it's on: turning the mic off closes it, so macOS's mic indicator goes
out. The mixed stream keeps a steady 100 ms pace even when every input is off (it's silence then),
so recording time and Deepgram's line times stay aligned however often the user toggles.

Each chunk also says whether the mic heard speech, which marks the lines the user spoke in.
"""
import asyncio
import math
from array import array
from collections.abc import AsyncIterator, Awaitable, Callable

CHUNK_SECONDS = 0.1
# An input waits until it has this much audio buffered before it's mixed in, and again after it
# runs dry, so uneven delivery doesn't chop gaps into the audio.
PRIME_SECONDS = 0.15
# Buffered audio past this is dropped, so an input that runs fast doesn't drift behind.
MAX_LAG_SECONDS = 0.5
# Mic loudness (RMS of 16-bit samples) above which a chunk counts as the user speaking.
# Quiet rooms sit around 50-150; speech into a laptop mic is around 1000-3000.
SPEECH_RMS = 400


def mix(parts: list[bytes], size: int) -> bytes:
    """Adds 16-bit mono chunks of `size` bytes sample by sample, clipping at full scale.

    E.g. samples [1000, -30000] + [500, -5000] → [1500, -32768]; no parts → silence.
    """
    if not parts:
        return bytes(size)
    if len(parts) == 1:
        return parts[0]
    total = array("h", parts[0])
    for part in parts[1:]:
        total = array("h", (max(-32768, min(32767, a + b)) for a, b in zip(total, array("h", part))))
    return total.tobytes()


def is_speech(chunk: bytes) -> bool:
    samples = array("h", chunk)
    return bool(samples) and math.sqrt(sum(s * s for s in samples) / len(samples)) >= SPEECH_RMS


class Buffer:
    """One input's audio waiting to be mixed in (a small jitter buffer)."""

    def __init__(self, sample_rate: int):
        self.data = bytearray()
        self.primed = False
        self.prime = int(sample_rate * PRIME_SECONDS) * 2
        self.max = int(sample_rate * MAX_LAG_SECONDS) * 2

    def put(self, chunk: bytes):
        self.data += chunk
        if len(self.data) > self.max:
            del self.data[:len(self.data) - self.prime]

    def take(self, size: int) -> bytes | None:
        """The next `size` bytes, or None (silence) while it's still filling up."""
        if not self.primed:
            if len(self.data) < self.prime:
                return None
            self.primed = True
        chunk = bytes(self.data[:size])
        del self.data[:size]
        if len(chunk) < size:
            self.primed = False  # ran dry: refill before mixing it in again
            chunk += bytes(size - len(chunk))
        return chunk


class Inputs:
    """The live inputs of one session, mixed into ~100 ms chunks by chunks().

    `openers` maps each input name ("system", "mic") to a function that starts capturing it and
    returns its PCM chunks. Captures run only while chunks() is being read. If an input fails or
    ends, it's turned off and `on_failure(name, error)` is told.

    E.g. Inputs(48000, {"system": ..., "mic": ...}, on={"system"}, ...) mixes only system audio
    until set("mic", True).
    """

    def __init__(self, sample_rate: int, openers: dict[str, Callable[[], AsyncIterator[bytes]]],
                 on: set[str], on_failure: Callable[[str, Exception], Awaitable[None]]):
        self.sample_rate = sample_rate
        self.openers = openers
        self.on_failure = on_failure
        self.on = {name for name in on if name in openers}
        self.running = False
        self.buffers: dict[str, Buffer] = {}
        self.tasks: dict[str, asyncio.Task] = {}

    def set(self, name: str, on: bool):
        if name not in self.openers:
            return
        if on:
            self.on.add(name)
        else:
            self.on.discard(name)
        self._apply()

    def _apply(self):
        """Starts and stops captures to match `on` (none while chunks() isn't running)."""
        wanted = self.on if self.running else set()
        for name in wanted - set(self.tasks):
            self.buffers[name] = Buffer(self.sample_rate)
            self.tasks[name] = asyncio.create_task(self._capture(name))
        for name in set(self.tasks) - wanted:
            self.tasks.pop(name).cancel()
            del self.buffers[name]

    async def _capture(self, name: str):
        buffer = self.buffers[name]
        source = self.openers[name]()
        try:
            async for chunk in source:
                buffer.put(chunk)
            error = RuntimeError("no more audio")
        except Exception as e:  # not CancelledError: turning it off isn't a failure
            error = e
        finally:
            await source.aclose()
        if self.tasks.get(name) is not asyncio.current_task():
            return  # already turned off
        del self.tasks[name], self.buffers[name]
        self.on.discard(name)
        await self.on_failure(name, error)

    async def chunks(self) -> AsyncIterator[tuple[bytes, bool]]:
        """Yields (mixed chunk, the mic heard speech) every 100 ms until closed."""
        self.running = True
        self._apply()
        loop = asyncio.get_running_loop()
        size = int(self.sample_rate * CHUNK_SECONDS) * 2
        due = loop.time()
        try:
            while True:
                due += CHUNK_SECONDS
                await asyncio.sleep(max(0.0, due - loop.time()))
                parts = {name: chunk for name, buffer in self.buffers.items()
                         if (chunk := buffer.take(size)) is not None}
                mic = parts.get("mic")
                yield mix(list(parts.values()), size), mic is not None and is_speech(mic)
        finally:
            self.running = False
            self._apply()
