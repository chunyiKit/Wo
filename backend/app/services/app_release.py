"""Android in-app update — the single "latest release" stored on disk.

We keep exactly one published release: an APK plus a small `manifest.json`
sidecar, both under `STORAGE_ROOT/app-release/`. Publishing a new build
overwrites the previous one. The directory lives in `storage`, which the deploy
rsync excludes from `--delete`, so releases survive code deploys.

The APK is written via a temp-file-then-rename so a half-uploaded build can
never be served, and streamed in chunks so a 100 MB APK doesn't sit in memory.
"""

from __future__ import annotations

import hashlib
import json
import os
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from app.core.config import settings

_RELEASE_DIRNAME = "app-release"
_APK_FILENAME = "wo-release.apk"
_MANIFEST_FILENAME = "manifest.json"


@dataclass(frozen=True)
class ReleaseManifest:
    """Metadata for the one published release. Mirrors `manifest.json`."""

    version_name: str
    version_code: int
    notes: str
    size: int
    sha256: str
    published_at: str

    def to_dict(self) -> dict:
        return {
            "version_name": self.version_name,
            "version_code": self.version_code,
            "notes": self.notes,
            "size": self.size,
            "sha256": self.sha256,
            "published_at": self.published_at,
        }


def _release_dir() -> Path:
    return Path(settings.storage_root).resolve() / _RELEASE_DIRNAME


def _apk_path() -> Path:
    return _release_dir() / _APK_FILENAME


def _manifest_path() -> Path:
    return _release_dir() / _MANIFEST_FILENAME


def get_manifest() -> ReleaseManifest | None:
    """Return the published release's metadata, or None if nothing is published."""
    mp = _manifest_path()
    if not mp.exists() or not _apk_path().exists():
        return None
    try:
        raw = json.loads(mp.read_text(encoding="utf-8"))
        return ReleaseManifest(
            version_name=str(raw["version_name"]),
            version_code=int(raw["version_code"]),
            notes=str(raw.get("notes", "")),
            size=int(raw["size"]),
            sha256=str(raw["sha256"]),
            published_at=str(raw["published_at"]),
        )
    except (ValueError, KeyError, OSError):
        # A corrupt manifest is treated as "no release" rather than crashing
        # the version check — the client just sees "already up to date".
        return None


def apk_path_for_download() -> Path | None:
    """Path to the published APK for streaming, or None if absent."""
    path = _apk_path()
    return path if path.exists() else None


async def publish(
    stream: AsyncIterator[bytes],
    *,
    version_name: str,
    version_code: int,
    notes: str,
    max_bytes: int,
) -> ReleaseManifest:
    """Write a new release from an upload stream, replacing any previous one.

    Streams to a temp file while hashing and counting bytes, enforces the size
    cap mid-stream, then atomically swaps it in and writes the manifest.

    Raises ValueError if the upload exceeds `max_bytes`.
    """
    release_dir = _release_dir()
    release_dir.mkdir(parents=True, exist_ok=True)

    tmp = release_dir / f".{_APK_FILENAME}.uploading"
    hasher = hashlib.sha256()
    size = 0
    try:
        with tmp.open("wb") as fh:
            async for chunk in stream:
                if not chunk:
                    continue
                size += len(chunk)
                if size > max_bytes:
                    raise ValueError("apk exceeds size limit")
                hasher.update(chunk)
                fh.write(chunk)
        if size == 0:
            raise ValueError("empty upload")

        os.replace(tmp, _apk_path())
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise

    manifest = ReleaseManifest(
        version_name=version_name,
        version_code=version_code,
        notes=notes,
        size=size,
        sha256=hasher.hexdigest(),
        published_at=datetime.now(UTC).isoformat(),
    )
    _manifest_path().write_text(
        json.dumps(manifest.to_dict(), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return manifest
