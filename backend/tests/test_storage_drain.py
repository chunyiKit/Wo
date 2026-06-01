"""Regression test for COS stream draining.

qcloud_cos StreamBody.read(chunk_size=1024) returns ONE chunk, not the whole
body — a bare .read() truncated avatars to 1024 bytes. `_drain_stream` must loop
until the stream is exhausted and return the full payload.
"""

from app.core.storage import _drain_stream


class _FakeStreamBody:
    """Mimics qcloud_cos StreamBody: read(n) returns at most n bytes per call,
    advancing through the payload, then b'' at EOF."""

    def __init__(self, payload: bytes) -> None:
        self._buf = payload
        self._pos = 0

    def read(self, chunk_size: int = 1024) -> bytes:
        chunk = self._buf[self._pos : self._pos + chunk_size]
        self._pos += len(chunk)
        return chunk


def test_drain_reads_full_multichunk_body() -> None:
    payload = b"x" * 69501  # larger than one 1 KiB chunk (the old bug truncated)
    drained = _drain_stream(_FakeStreamBody(payload), chunk_size=1024)
    assert drained == payload
    assert len(drained) == 69501


def test_drain_empty_body() -> None:
    assert _drain_stream(_FakeStreamBody(b"")) == b""


def test_drain_small_body() -> None:
    assert _drain_stream(_FakeStreamBody(b"hi")) == b"hi"
