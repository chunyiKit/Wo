"""Blob storage abstraction.

The plugin platform never holds binary data in PG — files (photos, etc.) live
in storage and we record only the metadata + storage key. Two backends:

- `LocalStorage` for dev/tests: files under `STORAGE_ROOT` on the local
  filesystem.
- `COSStorage` for prod: objects in a Tencent Cloud COS bucket, written with
  per-object ACL `private` so the bucket-default `public-read` (used by the
  APK release flow) doesn't accidentally expose family photos. Reads are
  served via short-lived presigned URLs the routes 302-redirect to, which
  offloads the actual byte transfer from this CVM to COS.

Routes import the module-level `storage` singleton. The singleton is picked
at import time based on whether COS is configured — empty COS settings keep
the LocalStorage path so tests and dev environments don't need an SDK.

Family content (photos, videos, avatars) goes through this abstraction. The
APK release flow has its own COS client in `app.core.cos` because it needs
**public-read** uploads (so any client can download without auth), and bakes
the public URL into the version manifest. Mixing both concerns into one
storage class would force every put-site to pass an ACL flag — keeping them
separate makes the dangerous default (private) impossible to forget.
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol, runtime_checkable
from urllib.parse import quote

from app.core.config import settings

# Read size when draining a COS stream. The SDK's StreamBody.read(n) returns at
# most n bytes per call, so we loop until empty. 1 MiB keeps the loop short.
_STREAM_CHUNK = 1024 * 1024


def _drain_stream(body: object, *, chunk_size: int = _STREAM_CHUNK) -> bytes:
    """Read a qcloud_cos StreamBody (or any object with `.read(n)`) to the end.

    `StreamBody.read()` returns a single chunk, not the full body — calling it
    once truncates large objects. We loop until `read` returns empty.
    """
    chunks: list[bytes] = []
    while True:
        chunk = body.read(chunk_size)  # type: ignore[attr-defined]
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


class Storage(Protocol):
    """Backend-neutral blob storage interface."""

    async def put(self, key: str, data: bytes, content_type: str) -> None: ...
    async def get(self, key: str) -> bytes: ...
    async def delete(self, key: str) -> None: ...
    async def exists(self, key: str) -> bool: ...


@runtime_checkable
class PresignableStorage(Protocol):
    """Optional capability for backends that can offload reads via a temporary
    public URL. Routes that want bandwidth offload check `isinstance(storage,
    PresignableStorage)` and 302-redirect to the URL instead of streaming
    bytes; backends without this capability (e.g. LocalStorage) fall back to
    the legacy `storage.get` + Response pattern.
    """

    async def presigned_get_url(self, key: str, *, ttl_seconds: int) -> str: ...


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


class COSStorage:
    """Tencent Cloud COS-backed storage for family content.

    Every put sets the object's ACL to `private` explicitly so that an
    accidentally-permissive bucket policy can't leak family photos. Reads are
    intentionally NOT plumbed through the backend by default — callers should
    prefer `presigned_get_url` and let the client fetch from COS directly. A
    fallback `get()` is provided for callers that haven't been migrated yet
    (downloads the full body through the backend; slower but correct).
    """

    # Default URL lifetime when callers don't pass one. One hour covers
    # photo browsing sessions; long enough that paging through a memory's
    # gallery doesn't issue dozens of refreshes, short enough that a leaked
    # URL ages out quickly.
    _DEFAULT_TTL_SECONDS = 3600

    def __init__(
        self,
        *,
        bucket: str,
        region: str,
        secret_id: str,
        secret_key: str,
    ) -> None:
        # Lazy SDK import so dev/tests that never touch COS don't pay the
        # cost (or fail when the optional dep isn't installed).
        from qcloud_cos import CosConfig as _SdkCfg
        from qcloud_cos import CosS3Client

        self._bucket = bucket
        self._region = region
        self._client = CosS3Client(
            _SdkCfg(
                Region=region,
                SecretId=secret_id,
                SecretKey=secret_key,
                Scheme="https",
            )
        )

    async def put(self, key: str, data: bytes, content_type: str) -> None:
        # `put_object` is sync in the SDK; we accept the blocking call here
        # because uploads are bounded by `MAX_UPLOAD_BYTES` (20 MB) and the
        # server is single-tenant. If/when this becomes a bottleneck, move
        # to a thread executor.
        self._client.put_object(
            Bucket=self._bucket,
            Key=key,
            Body=data,
            ContentType=content_type,
            ACL="private",
        )

    async def get(self, key: str) -> bytes:
        # Fallback path for callers that haven't been migrated to presigned
        # URLs. Downloads the whole body via the backend — defeats the
        # bandwidth-offload point, so prefer `presigned_get_url`.
        try:
            resp = self._client.get_object(Bucket=self._bucket, Key=key)
        except Exception as exc:  # qcloud_cos raises its own CosServiceError
            raise FileNotFoundError(key) from exc
        # CRITICAL: qcloud_cos StreamBody.read(chunk_size=1024) returns ONE
        # chunk, not the whole body — a bare .read() yields only 1024 bytes and
        # truncates the object. Drain the stream fully.
        return _drain_stream(resp["Body"])

    async def delete(self, key: str) -> None:
        # COS delete is idempotent — deleting a missing object returns 204,
        # so we don't need a pre-check.
        self._client.delete_object(Bucket=self._bucket, Key=key)

    async def exists(self, key: str) -> bool:
        try:
            self._client.head_object(Bucket=self._bucket, Key=key)
        except Exception:
            return False
        return True

    async def presigned_get_url(
        self, key: str, *, ttl_seconds: int = _DEFAULT_TTL_SECONDS
    ) -> str:
        """Mint a temporary public URL for an object.

        Returns a fully-qualified https URL with the signature embedded in
        the query string; clients use it without any auth headers. The URL
        becomes invalid after `ttl_seconds`.
        """
        # The SDK's `get_presigned_url` takes Method/Bucket/Key/Expired.
        return self._client.get_presigned_url(
            Method="GET",
            Bucket=self._bucket,
            Key=quote(key, safe="/"),
            Expired=ttl_seconds,
        )


def _build_storage() -> Storage:
    """Pick the storage backend based on COS settings; fall back to local."""
    if (
        settings.cos_bucket
        and settings.cos_region
        and settings.cos_secret_id
        and settings.cos_secret_key
    ):
        return COSStorage(
            bucket=settings.cos_bucket,
            region=settings.cos_region,
            secret_id=settings.cos_secret_id,
            secret_key=settings.cos_secret_key,
        )
    return LocalStorage(Path(settings.storage_root))


# Module-level singleton. Tests monkeypatch this directly when they need to
# inject a fake — the routes always re-read `storage.storage` so swaps stick.
storage: Storage = _build_storage()
