"""Android in-app update — the single "latest release" manifest + APK blob.

We keep exactly one published release at a time. The APK blob lives in one of
two places, decided at publish time by whether COS is configured:

- **COS mode** (prod): APK uploads to a public-read COS bucket; clients fetch
  it from `<bucket>.cos.<region>.myqcloud.com`, offloading download bandwidth
  from the single CVM. The manifest records the resolved COS URL verbatim
  so it stays stable even if config changes later.
- **Local mode** (dev/tests): APK is written to disk under
  `STORAGE_ROOT/app-release/`, and served via `/api/v1/app/download`. Same
  behaviour as before COS was introduced.

The manifest sidecar (`manifest.json`) always lives on disk, and is the source
of truth for "what version is published, and where to fetch it". Publishing a
new build overwrites the previous one.

The APK is written to a temp file first (streaming, hashed mid-flight) so a
half-uploaded build can never be served, and so we never hold a 100 MB APK in
memory.
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
from app.core.cos import get_cos_client, normalised_apk_key

_RELEASE_DIRNAME = "app-release"
_APK_FILENAME = "wo-release.apk"
_MANIFEST_FILENAME = "manifest.json"

# Uploaded to COS as octet-stream on purpose: Tencent Cloud's
# DownloadForbidden filter on the default `*.myqcloud.com` domain triggers on
# the official APK MIME (`application/vnd.android.package-archive`). The App
# downloader writes bytes to a local `*.apk` path and invokes the installer
# with an explicit type, so the remote Content-Type is irrelevant for install.
_APK_CONTENT_TYPE = "application/octet-stream"

# Storage marker in the manifest. "local" is the legacy default — manifests
# written before COS was introduced have no marker and resolve to "local".
_STORAGE_LOCAL = "local"
_STORAGE_COS = "cos"


@dataclass(frozen=True)
class ReleaseManifest:
    """Metadata for the one published release. Mirrors `manifest.json`."""

    version_name: str
    version_code: int
    notes: str
    size: int
    sha256: str
    published_at: str
    # "local" → blob is on disk, served by /app/download.
    # "cos"   → blob is in COS, client downloads directly via `cos_url`.
    storage: str = _STORAGE_LOCAL
    # Resolved COS public URL when storage == "cos"; empty otherwise.
    cos_url: str = ""

    def to_dict(self) -> dict:
        return {
            "version_name": self.version_name,
            "version_code": self.version_code,
            "notes": self.notes,
            "size": self.size,
            "sha256": self.sha256,
            "published_at": self.published_at,
            "storage": self.storage,
            "cos_url": self.cos_url,
        }


def _release_dir() -> Path:
    return Path(settings.storage_root).resolve() / _RELEASE_DIRNAME


def _apk_path() -> Path:
    return _release_dir() / _APK_FILENAME


def _manifest_path() -> Path:
    return _release_dir() / _MANIFEST_FILENAME


def get_manifest() -> ReleaseManifest | None:
    """Return the published release's metadata, or None if nothing is published.

    For local-mode releases we also verify the APK file still exists on disk;
    a missing blob means "no release". For COS-mode releases we trust the
    manifest — we can't cheaply verify the remote object exists on every
    /version call, and a transient COS outage shouldn't make the client think
    the release was unpublished.
    """
    mp = _manifest_path()
    if not mp.exists():
        return None
    try:
        raw = json.loads(mp.read_text(encoding="utf-8"))
        storage = str(raw.get("storage") or _STORAGE_LOCAL)
        if storage == _STORAGE_LOCAL and not _apk_path().exists():
            return None
        return ReleaseManifest(
            version_name=str(raw["version_name"]),
            version_code=int(raw["version_code"]),
            notes=str(raw.get("notes", "")),
            size=int(raw["size"]),
            sha256=str(raw["sha256"]),
            published_at=str(raw["published_at"]),
            storage=storage,
            cos_url=str(raw.get("cos_url", "")),
        )
    except (ValueError, KeyError, OSError):
        # A corrupt manifest is treated as "no release" rather than crashing
        # the version check — the client just sees "already up to date".
        return None


def apk_path_for_download() -> Path | None:
    """Path to the published APK for streaming, or None if absent / on COS.

    /app/download uses this to decide between streaming locally and falling
    back to a redirect. COS-mode releases always return None here.
    """
    manifest = get_manifest()
    if manifest is None or manifest.storage != _STORAGE_LOCAL:
        return None
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
    cap mid-stream, then either:

    - uploads the temp file to COS (if configured) and points the manifest at
      the public URL, or
    - atomically swaps it in as the local APK blob.

    Raises ValueError if the upload exceeds `max_bytes` or is empty.
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

        cos = get_cos_client()
        if cos is not None:
            # COS mode: upload temp file → record URL → discard temp.
            key = normalised_apk_key(version_code)
            cos.put_object(key, tmp, _APK_CONTENT_TYPE)
            cos_url = cos.public_url(key)
            tmp.unlink(missing_ok=True)
            # Clean up any stale local APK from a previous local-mode publish
            # so /download doesn't accidentally serve an outdated build.
            _apk_path().unlink(missing_ok=True)
            storage = _STORAGE_COS
        else:
            # Local mode: atomic swap into place.
            os.replace(tmp, _apk_path())
            cos_url = ""
            storage = _STORAGE_LOCAL
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
        storage=storage,
        cos_url=cos_url,
    )
    _manifest_path().write_text(
        json.dumps(manifest.to_dict(), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return manifest
