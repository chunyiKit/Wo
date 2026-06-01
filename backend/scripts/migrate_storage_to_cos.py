"""One-shot: copy everything under STORAGE_ROOT into COS.

Run on the server **after** COS env vars are set and the new code has been
deployed (so `COSStorage` is the active singleton), but before users start
hitting reads they expect to land in COS.

The script is idempotent: it skips objects that already exist in COS, so you
can re-run safely after partial failures. Local files are **never deleted**
— they remain as a rollback safety net. If something goes wrong, just blank
the COS env vars + restart wo-backend and reads fall back to local disk.

Usage on the server:
    cd /opt/wo-backend && uv run python scripts/migrate_storage_to_cos.py
    # add --dry-run to preview without uploading
    # add --prefix memory to scope to one subtree

The content-type guess is best-effort from the file extension — for image and
video keys this matches what the validator picked at upload time. Unknown
extensions fall back to `application/octet-stream`.
"""

from __future__ import annotations

import argparse
import asyncio
import mimetypes
import sys
from pathlib import Path

from app.core.config import settings
from app.core.storage import COSStorage, LocalStorage

# Extensions that mimetypes doesn't guess on every platform but we know.
_KNOWN_TYPES: dict[str, str] = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".mp4": "video/mp4",
    ".mov": "video/quicktime",
    ".webm": "video/webm",
}


def _guess_content_type(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in _KNOWN_TYPES:
        return _KNOWN_TYPES[ext]
    guess, _ = mimetypes.guess_type(path.name)
    return guess or "application/octet-stream"


async def _migrate(prefix: str | None, dry_run: bool) -> tuple[int, int, int]:
    """Walk STORAGE_ROOT and copy to COS. Returns (copied, skipped, failed)."""
    if not (
        settings.cos_bucket
        and settings.cos_region
        and settings.cos_secret_id
        and settings.cos_secret_key
    ):
        print("ERROR: COS env vars not configured; nothing to migrate to.", file=sys.stderr)
        return 0, 0, 1

    local = LocalStorage(Path(settings.storage_root))
    cos = COSStorage(
        bucket=settings.cos_bucket,
        region=settings.cos_region,
        secret_id=settings.cos_secret_id,
        secret_key=settings.cos_secret_key,
    )

    root = local.root
    print(f"Source: {root}")
    print(f"Target: cos://{settings.cos_bucket} ({settings.cos_region})")
    if prefix:
        print(f"Prefix filter: {prefix!r}")
    if dry_run:
        print("(dry-run — no objects will be uploaded)")
    print()

    copied = skipped = failed = 0

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        # Skip hidden files (e.g. in-flight uploads like .wo-release.apk.uploading).
        if any(part.startswith(".") for part in path.relative_to(root).parts):
            continue
        key = path.relative_to(root).as_posix()
        if prefix and not key.startswith(prefix.rstrip("/") + "/") and key != prefix:
            continue

        # Skip the app-release directory — APK distribution has its own
        # public-read upload path (app.core.cos), and re-uploading the APK
        # here would mark it private and break /app/download.
        if key.startswith("app-release/"):
            continue

        try:
            if await cos.exists(key):
                print(f"  skip  {key} (already in COS)")
                skipped += 1
                continue
        except Exception as exc:
            print(f"  WARN  {key} — exists() failed: {exc}; will try put", file=sys.stderr)

        if dry_run:
            print(f"  plan  {key} ({path.stat().st_size:,} bytes)")
            copied += 1
            continue

        try:
            data = path.read_bytes()
            await cos.put(key, data, _guess_content_type(path))
            print(f"  copy  {key} ({len(data):,} bytes)")
            copied += 1
        except Exception as exc:
            print(f"  FAIL  {key} — {exc}", file=sys.stderr)
            failed += 1

    return copied, skipped, failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="preview only")
    parser.add_argument(
        "--prefix",
        default=None,
        help="only migrate keys under this prefix (e.g. 'memory')",
    )
    args = parser.parse_args()

    copied, skipped, failed = asyncio.run(_migrate(args.prefix, args.dry_run))
    print()
    print(f"Done: {copied} copied, {skipped} skipped, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
