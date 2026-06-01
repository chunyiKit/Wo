"""Tencent Cloud COS client wrapper for blob distribution.

Used by the APK release flow (and later, photo distribution) to offload
download bandwidth from the single CVM to COS's public-read domain.

The module is intentionally small: a Protocol-shaped client with `put_object`
and `public_url`, a real implementation backed by `cos-python-sdk-v5`, and a
factory that returns `None` when COS isn't configured (so callers can fall
back to local disk in dev/tests without touching the SDK).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from urllib.parse import quote

from app.core.config import settings


class CosClient(Protocol):
    """Backend-neutral COS surface — only the bits we actually use."""

    def put_object(self, key: str, local_path: Path, content_type: str) -> None: ...
    def public_url(self, key: str) -> str: ...


@dataclass(frozen=True)
class CosConfig:
    bucket: str
    region: str
    secret_id: str
    secret_key: str

    @classmethod
    def from_settings(cls) -> CosConfig | None:
        """Build config from env-backed settings, or None if not configured.

        All four credentials must be present — partial config is treated as
        "not configured" rather than failing late at upload time.
        """
        if not (
            settings.cos_bucket
            and settings.cos_region
            and settings.cos_secret_id
            and settings.cos_secret_key
        ):
            return None
        return cls(
            bucket=settings.cos_bucket,
            region=settings.cos_region,
            secret_id=settings.cos_secret_id,
            secret_key=settings.cos_secret_key,
        )

    @property
    def public_host(self) -> str:
        return f"{self.bucket}.cos.{self.region}.myqcloud.com"


class _CosSdkClient:
    """Thin adapter over qcloud_cos.CosS3Client.

    Imported lazily so dev/tests that never touch COS don't need the SDK on
    PYTHONPATH and don't pay its import cost at app startup.
    """

    def __init__(self, cfg: CosConfig) -> None:
        # Import inside __init__ so a missing optional dep doesn't break
        # `from app.core.cos import ...` at module load.
        from qcloud_cos import CosConfig as _SdkCfg
        from qcloud_cos import CosS3Client

        self._cfg = cfg
        self._client = CosS3Client(
            _SdkCfg(
                Region=cfg.region,
                SecretId=cfg.secret_id,
                SecretKey=cfg.secret_key,
                Scheme="https",
            )
        )

    def put_object(self, key: str, local_path: Path, content_type: str) -> None:
        # upload_file streams from disk in chunks (the SDK switches to multipart
        # automatically beyond ~5 MB), so a 100 MB APK doesn't sit in memory.
        self._client.upload_file(
            Bucket=self._cfg.bucket,
            Key=key,
            LocalFilePath=str(local_path),
            ContentType=content_type,
            EnableMD5=False,
        )

    def public_url(self, key: str) -> str:
        # The bucket is `公有读 / 私有写`, so a plain https URL to the public
        # host downloads without auth. quote() handles any future keys that
        # contain spaces or unicode.
        safe_key = quote(key, safe="/")
        return f"https://{self._cfg.public_host}/{safe_key}"


def get_cos_client() -> CosClient | None:
    """Module-level factory. Returns None when COS isn't configured."""
    cfg = CosConfig.from_settings()
    if cfg is None:
        return None
    return _CosSdkClient(cfg)


def normalised_apk_key(version_code: int) -> str:
    """Object key for a published APK. Encodes version_code so each upload is
    a distinct object — lets us roll back via COS history if needed, and
    sidesteps any propagation lag on overwriting the same key.

    Stored with a `.bin` extension on purpose: Tencent Cloud COS blocks
    `*.apk` / `*.ipa` downloads through the default `*.myqcloud.com` domain
    with a `DownloadForbidden` error (the workaround they recommend is a
    paid custom CDN domain, which requires ICP 备案). Renaming the object
    sidesteps the filter — the App downloader writes the bytes to a local
    `*.apk` path for install, so the remote extension is invisible to users.
    """
    prefix = settings.cos_apk_prefix.strip("/")
    return f"{prefix}/wo-{version_code}.bin" if prefix else f"wo-{version_code}.bin"
