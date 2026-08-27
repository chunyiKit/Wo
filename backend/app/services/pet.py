"""Family Pet identity CRUD and private photo helpers."""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_admin, require_membership
from app.models.pet import Pet, PetCreate, PetUpdate
from app.models.user import User


def photo_storage_key(family_id: UUID, pet_id: UUID, ext: str) -> str:
    return f"pets/{family_id}/{pet_id}/avatar.{ext}"


async def load_pet(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    *,
    include_archived: bool = False,
) -> Pet:
    pet = await session.get(Pet, pet_id)
    if (
        pet is None
        or pet.family_id != family_id
        or (pet.archived_at is not None and not include_archived)
    ):
        raise AppError(ErrorCode.NOT_FOUND, "宠物不存在", status_code=404)
    return pet


async def list_pets(
    session: AsyncSession, family_id: UUID, requester: User, *, include_archived: bool = False
) -> list[Pet]:
    await require_membership(session, requester.id, family_id)
    stmt = select(Pet).where(Pet.family_id == family_id)
    if not include_archived:
        stmt = stmt.where(Pet.archived_at.is_(None))
    stmt = stmt.order_by(Pet.created_at, Pet.id)
    return list((await session.execute(stmt)).scalars().all())


async def create_pet(
    session: AsyncSession, family_id: UUID, payload: PetCreate, requester: User
) -> Pet:
    membership = await require_membership(session, requester.id, family_id)
    require_admin(membership)
    name = payload.name.strip()
    if not name:
        raise AppError(ErrorCode.VALIDATION_ERROR, "宠物名字不能为空", status_code=400)
    pet = Pet(**payload.model_dump(), family_id=family_id, created_by=requester.id)
    pet.name = name
    session.add(pet)
    await session.commit()
    await session.refresh(pet)
    return pet


async def update_pet(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    payload: PetUpdate,
    requester: User,
) -> Pet:
    membership = await require_membership(session, requester.id, family_id)
    require_admin(membership)
    pet = await load_pet(session, family_id, pet_id)
    updates = payload.model_dump(exclude_unset=True)
    if "name" in updates and updates["name"] is not None:
        updates["name"] = updates["name"].strip()
        if not updates["name"]:
            raise AppError(ErrorCode.VALIDATION_ERROR, "宠物名字不能为空", status_code=400)
    for key, value in updates.items():
        setattr(pet, key, value)
    session.add(pet)
    await session.commit()
    await session.refresh(pet)
    return pet


async def archive_pet(session: AsyncSession, family_id: UUID, pet_id: UUID, requester: User) -> Pet:
    membership = await require_membership(session, requester.id, family_id)
    require_admin(membership)
    pet = await load_pet(session, family_id, pet_id)
    pet.archived_at = datetime.now(UTC)
    session.add(pet)
    await session.commit()
    await session.refresh(pet)
    return pet
