"""In-memory sliding-window rate limiter — no Redis.

Counters live in process memory, so limits are per-process and reset on
restart. That's deliberate: the current deployment is a single low-concurrency
instance and we don't want to pull in Redis just for login throttling. If we
ever scale to multiple workers/instances, swap the backing store for Redis and
keep the same `check()` interface.

`client_ip` resolves the real caller IP, honoring `X-Forwarded-For` since the
app sits behind nginx in production.
"""

import time
from collections import defaultdict, deque
from threading import Lock

from starlette.requests import Request


class SlidingWindowRateLimiter:
    """Allow at most `max_hits` events per `window_seconds` for a given key."""

    def __init__(self, max_hits: int, window_seconds: float) -> None:
        self._max_hits = max_hits
        self._window = window_seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = Lock()

    def check(self, key: str) -> bool:
        """Record a hit for `key`. Returns True if allowed, False if over limit.

        A rejected hit is NOT recorded, so a client that backs off after a 429
        recovers as soon as the oldest in-window hit ages out.
        """
        now = time.monotonic()
        cutoff = now - self._window
        with self._lock:
            bucket = self._hits[key]
            while bucket and bucket[0] <= cutoff:
                bucket.popleft()
            # Drop the key entirely when idle so the dict can't grow unbounded.
            if not bucket and len(self._hits) > 1:
                self._hits.pop(key, None)
                bucket = self._hits[key]
            if len(bucket) >= self._max_hits:
                return False
            bucket.append(now)
            return True

    def reset(self) -> None:
        """Clear all counters — used by tests for isolation."""
        with self._lock:
            self._hits.clear()


def client_ip(request: Request) -> str:
    """Best-effort caller IP. Trusts the first `X-Forwarded-For` hop (nginx)."""
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"
