"""Blob storage abstraction.

The plugin platform never holds binary data in PG — files (photos, etc.) live
in storage and we record only the metadata + storage key. Two backends:

- `LocalStorage` for dev: files under `STORAGE_ROOT` on the local filesystem.
- (Future) `S3Storage` for prod: same Protocol, drops in without route changes.

Routes import the module-level `storage` singleton. Tests can monkeypatch it
or swap the singleton on app startup if/when we add a test-only InMemory
backend.
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol

from app.core.config import settings


class Storage(Protocol):
    """Backend-neutral blob storage interface."""

    async def put(self, key: str, data: bytes, content_type: str) -> None: ...
    async def get(self, key: str) -> bytes: ...
    async def delete(self, key: str) -> None: ...
    async def exists(self, key: str) -> bool: ...


class LocalStorage:
    """Filesystem-backed storage rooted at a configurable directory.

    `key` is a forward-slash separated relative path (e.g.
    `photos/{family_id}/{photo_id}.jpg`). The class never opens paths outside
    `root` — keys are joined and resolved, and the result must stay under root.
    """

    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _resolve(self, key: str) -> Path:
        path = (self.root / key).resolve()
        # Defense-in-depth: prevent path traversal via crafted keys.
        if not str(path).startswith(str(self.root)):
            raise ValueError(f"storage key escapes root: {key!r}")
        return path

    async def put(self, key: str, data: bytes, content_type: str) -> None:
        path = self._resolve(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    async def get(self, key: str) -> bytes:
        path = self._resolve(key)
        if not path.exists():
            raise FileNotFoundError(key)
        return path.read_bytes()

    async def delete(self, key: str) -> None:
        path = self._resolve(key)
        if path.exists():
            path.unlink()

    async def exists(self, key: str) -> bool:
        return self._resolve(key).exists()


# Module-level singleton. P5/prod swaps this with S3Storage(...) via env.
storage: Storage = LocalStorage(Path(settings.storage_root))
