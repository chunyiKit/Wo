"""Audit legacy Pet conversion and optionally normalize photo storage keys.

Dry-run is the default and makes no changes. With ``--copy-photos``, each
migrated Pet whose photo still points at a User avatar object is copied to the
dedicated ``pets/{family_id}/{pet_id}/avatar.<ext>`` key. Failures are logged
and leave the original pointer untouched, so the migration never loses a
working photo; the client still falls back to the Pet emoji if that object is
missing.

Run from ``backend/`` as ``uv run python -m scripts.audit_pet_migration``.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
from pathlib import PurePosixPath

from sqlmodel import select

from app.core.database import async_session_maker
from app.core.storage import storage
from app.models.pet import Pet

logger = logging.getLogger("pet-migration-audit")


def _extension(pet: Pet) -> str:
    suffix = PurePosixPath(pet.photo_storage_key or "").suffix.lower().lstrip(".")
    if suffix in {"jpg", "jpeg", "png", "webp"}:
        return "jpg" if suffix == "jpeg" else suffix
    return {
        "image/png": "png",
        "image/webp": "webp",
    }.get(pet.photo_content_type or "", "jpg")


async def audit(*, copy_photos: bool) -> dict[str, int]:
    result = {
        "migrated_pets": 0,
        "photo_pointers": 0,
        "already_normalized": 0,
        "source_missing": 0,
        "copied": 0,
        "copy_failed": 0,
    }
    async with async_session_maker() as session:
        pets = list(
            (await session.execute(select(Pet).where(Pet.legacy_user_id.is_not(None))))
            .scalars()
            .all()
        )
        result["migrated_pets"] = len(pets)
        for pet in pets:
            source = pet.photo_storage_key
            if not source:
                continue
            result["photo_pointers"] += 1
            target = f"pets/{pet.family_id}/{pet.id}/avatar.{_extension(pet)}"
            if source == target:
                result["already_normalized"] += 1
                continue
            if not await storage.exists(source):
                result["source_missing"] += 1
                logger.warning("source photo missing: pet=%s key=%s", pet.id, source)
                continue
            if not copy_photos:
                continue
            try:
                data = await storage.get(source)
                await storage.put(target, data, pet.photo_content_type or "image/jpeg")
                pet.photo_storage_key = target
                pet.photo_version += 1
                session.add(pet)
                await session.commit()
                result["copied"] += 1
            except Exception:  # noqa: BLE001
                await session.rollback()
                result["copy_failed"] += 1
                logger.exception("photo copy failed: pet=%s source=%s", pet.id, source)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--copy-photos",
        action="store_true",
        help="copy legacy avatar objects to dedicated Pet keys and update rows",
    )
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    result = asyncio.run(audit(copy_photos=args.copy_photos))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
