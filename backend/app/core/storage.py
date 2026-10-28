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

Reads and writes can both be offloaded to COS:

- **Reads** → `presigned_get_url` (see above), already used everywhere.
- **Writes** → `presigned_post` (POST Object). The client gets a short-lived
  signed *policy* instead of credentials and uploads straight to COS, so a
  100 MB video never transits this CVM. The policy pins the object key, its
  content type, its ACL (`private`) and a `content-length-range`, so a holder
  of the ticket can only ever write exactly the object we intended.

Family content (photos, videos, avatars) goes through this abstraction. The
APK release flow has its own COS client in `app.core.cos` because it needs
**public-read** uploads (so any client can download without auth), and bakes
the public URL into the version manifest. Mixing both concerns into one
storage class would force every put-site to pass an ACL flag — keeping them
separate makes the dangerous default (private) impossible to forget.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import hmac
import json
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol, runtime_checkable
from urllib.parse import quote

from app.core.config import settings

# Read size when draining a COS stream. The SDK's StreamBody.read(n) returns at
# most n bytes per call, so we loop until empty. 1 MiB keeps the loop short.
_STREAM_CHUNK = 1024 * 1024

# Bytes fetched when stat-ing an object. Enough for every magic-number check
# (`ftyp` sits at 4..8, `RIFF....WEBP` needs 12) and cheap enough to run on
# every direct-upload commit.
_STAT_HEAD_BYTES = 16


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


@dataclass(frozen=True)
class PresignedPost:
    """Everything a client needs to POST one object straight to COS.

    `fields` must be sent as `multipart/form-data` parts **before** the file
    part, which is non-negotiable for COS: it stops reading at `file`.
    """

    url: str
    # Largest object the signed policy accepts (COS rejects bigger ones).
    max_bytes: int
    expires_at: datetime
    fields: dict[str, str] = field(default_factory=dict)
    # Name the file part must use. Constant in practice, but carried here so
    # the client never hardcodes it.
    file_field: str = "file"


@dataclass(frozen=True)
class BlobStat:
    """Size, declared content type and leading bytes of a stored object.

    `head` lets callers sanity-check content without downloading the whole
    object — a 100 MB video only costs us 16 bytes to classify.
    """

    size_bytes: int
    content_type: str
    head: bytes


@runtime_checkable
class DirectUploadStorage(Protocol):
    """Capability for backends that can take uploads directly from a client.

    Complements `presigned_get_url`: reads and writes both bypass this CVM.
    Backends without it (e.g. LocalStorage) keep the upload-through-API path.
    """

    async def presigned_post(
        self,
        key: str,
        *,
        content_type: str,
        max_bytes: int,
        ttl_seconds: int,
    ) -> PresignedPost: ...

    async def stat(self, key: str) -> BlobStat | None: ...


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
        self._secret_id = secret_id
        self._secret_key = secret_key
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

    @property
    def _post_url(self) -> str:
        """Bucket endpoint a client POSTs a direct upload to."""
        return f"https://{self._bucket}.cos.{self._region}.myqcloud.com/"

    async def presigned_post(
        self,
        key: str,
        *,
        content_type: str,
        max_bytes: int,
        ttl_seconds: int = _DEFAULT_TTL_SECONDS,
    ) -> PresignedPost:
        """Mint a signed POST policy so a client can upload `key` itself.

        The SecretKey never leaves the server: it only ever signs a policy that
        pins down *what* may be written — this exact key, this content type,
        `private` ACL, and at most `max_bytes`. Everything else COS rejects.
        """
        now = int(time.time())
        key_time = f"{now};{now + ttl_seconds}"
        policy_text = build_post_policy(
            bucket=self._bucket,
            secret_id=self._secret_id,
            key=key,
            content_type=content_type,
            max_bytes=max_bytes,
            key_time=key_time,
            expiration=datetime.fromtimestamp(now + ttl_seconds, UTC).strftime(
                "%Y-%m-%dT%H:%M:%S.000Z"
            ),
        )
        signature = sign_post_policy(policy_text, self._secret_key, key_time)
        return PresignedPost(
            url=self._post_url,
            fields={
                "key": key,
                "acl": "private",
                "Content-Type": content_type,
                # COS answers 204 by default; 200 gives clients a simple
                # "did it work" check (and a body we ignore anyway).
                "success_action_status": "200",
                "policy": base64.b64encode(policy_text.encode("utf-8")).decode("ascii"),
                "q-sign-algorithm": "sha1",
                "q-ak": self._secret_id,
                "q-key-time": key_time,
                "q-signature": signature,
            },
            max_bytes=max_bytes,
            expires_at=datetime.fromtimestamp(now + ttl_seconds, UTC),
        )

    async def stat(self, key: str) -> BlobStat | None:
        """Size / type / leading bytes of an object, or None when missing.

        One ranged GET covering the first bytes returns everything: the
        `Content-Range` total is the object size and the response headers carry
        the stored content type.
        """
        try:
            resp = self._client.get_object(
                Bucket=self._bucket,
                Key=quote(key, safe="/"),
                Range=f"bytes=0-{_STAT_HEAD_BYTES - 1}",
            )
        except Exception:  # CosServiceError (404) and transport errors alike
            return None
        # The SDK spreads response headers onto the result with their original
        # capitalisation (`Content-Range`), and nests a copy under "Headers" in
        # some versions — fold both into one lower-cased map so lookups can't
        # silently miss.
        headers = {str(k).lower(): str(v) for k, v in resp.items() if k != "Body"}
        nested = resp.get("Headers")
        if isinstance(nested, dict):
            headers.update({str(k).lower(): str(v) for k, v in nested.items()})

        def header(name: str) -> str:
            return headers.get(name) or ""

        size = 0
        content_range = header("content-range")
        if "/" in content_range:
            with contextlib.suppress(ValueError):
                size = int(content_range.rsplit("/", 1)[1])
        if not size:
            with contextlib.suppress(ValueError):
                size = int(header("content-length") or 0)

        body = resp.get("Body")
        head = _drain_stream(body) if body is not None else b""
        return BlobStat(
            size_bytes=size,
            content_type=header("content-type"),
            head=head[:_STAT_HEAD_BYTES],
        )


def build_post_policy(
    *,
    bucket: str,
    secret_id: str,
    key: str,
    content_type: str,
    max_bytes: int,
    key_time: str,
    expiration: str,
) -> str:
    """Serialise the POST Object policy COS will enforce.

    Every condition here is a restriction, never a convenience: the ticket
    holder may write **only** this key, **only** this content type, **only** a
    private object, and **only** up to `max_bytes`. Compact separators matter —
    the signature covers these exact bytes and the client forwards them as-is.
    """
    policy = {
        "expiration": expiration,
        "conditions": [
            # Objects stay private even though the bucket defaults to
            # public-read for the APK flow — family photos must never inherit
            # that.
            {"acl": "private"},
            {"bucket": bucket},
            ["content-length-range", 1, max_bytes],
            ["eq", "$key", key],
            ["eq", "$Content-Type", content_type],
            {"q-sign-algorithm": "sha1"},
            {"q-ak": secret_id},
            {"q-sign-time": key_time},
        ],
    }
    return json.dumps(policy, separators=(",", ":"), ensure_ascii=False)


def sign_post_policy(policy_text: str, secret_key: str, key_time: str) -> str:
    """Signature for COS's POST Object flow (`q-signature`).

    Deliberately *not* the usual COS request signature: POST Object has no
    HttpString, so the policy text's SHA-1 takes its place.

        SignKey      = HMAC-SHA1(SecretKey, KeyTime)
        StringToSign = SHA1(PolicyText)
        Signature    = HMAC-SHA1(SignKey, StringToSign)

    Kept module-level (and SDK-free) so it's unit-testable on machines without
    `qcloud_cos` installed.
    """
    sign_key = hmac.new(
        secret_key.encode("utf-8"), key_time.encode("utf-8"), hashlib.sha1
    ).hexdigest()
    string_to_sign = hashlib.sha1(policy_text.encode("utf-8")).hexdigest()
    return hmac.new(
        sign_key.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha1
    ).hexdigest()


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
