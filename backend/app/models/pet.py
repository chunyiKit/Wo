"""Family-level pet identity.

Pets appear alongside people in family management, but they are not users and
never participate in Membership, authentication, roles, invitations, or push
recipients.  Plugin-specific care history lives under ``app.plugins.pet``.
"""

from datetime import UTC, date, datetime
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, StringConstraints
from sqlalchemy import Column, Date, DateTime, Index
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

MAX_PET_NAME_LEN = 24
MAX_PET_SPECIES_LEN = 32
MAX_PET_BREED_LEN = 64
MAX_PET_NOTES_LEN = 1000


class PetBase(SQLModel):
    name: str = Field(max_length=MAX_PET_NAME_LEN)
    emoji: str = Field(default="🐾", max_length=16)
    species: str | None = Field(default=None, max_length=MAX_PET_SPECIES_LEN)
    breed: str | None = Field(default=None, max_length=MAX_PET_BREED_LEN)
    sex: str | None = Field(default=None, max_length=16)
    birthday: date | None = Field(default=None, sa_column=Column(Date, nullable=True))
    birthday_estimated: bool = Field(default=False)
    arrival_date: date | None = Field(default=None, sa_column=Column(Date, nullable=True))
    neutered: bool | None = Field(default=None)
    notes: str | None = Field(default=None, max_length=MAX_PET_NOTES_LEN)


class Pet(PetBase, table=True):
    __tablename__ = "pets"
    __table_args__ = (Index("ix_pets_family_active", "family_id", "archived_at"),)

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(foreign_key="families.id", ondelete="CASCADE", index=True)
    photo_storage_key: str | None = Field(default=None, max_length=255)
    photo_content_type: str | None = Field(default=None, max_length=64)
    photo_version: int = Field(default=0, ge=0)
    created_by: UUID | None = Field(
        default=None, foreign_key="users.id", ondelete="SET NULL", nullable=True
    )
    # Audit/rollback mapping for rows converted from the legacy role=pet
    # Membership shape. New pets leave this null and it is never exposed.
    legacy_user_id: UUID | None = Field(
        default=None, foreign_key="users.id", ondelete="SET NULL", nullable=True
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    archived_at: datetime | None = Field(
        default=None, sa_column=Column(DateTime(timezone=True), nullable=True)
    )


class PetCreate(PetBase):
    pass


class PetUpdate(BaseModel):
    name: Annotated[str, StringConstraints(min_length=1, max_length=MAX_PET_NAME_LEN)] | None = None
    emoji: Annotated[str, StringConstraints(min_length=1, max_length=16)] | None = None
    species: Annotated[str, StringConstraints(max_length=MAX_PET_SPECIES_LEN)] | None = None
    breed: Annotated[str, StringConstraints(max_length=MAX_PET_BREED_LEN)] | None = None
    sex: Annotated[str, StringConstraints(max_length=16)] | None = None
    birthday: date | None = None
    birthday_estimated: bool | None = None
    arrival_date: date | None = None
    neutered: bool | None = None
    notes: Annotated[str, StringConstraints(max_length=MAX_PET_NOTES_LEN)] | None = None


class PetRead(PetBase):
    id: UUID
    family_id: UUID
    photo_version: int = 0
    photo_url: str | None = None
    created_by: UUID | None = None
    created_at: datetime
    archived_at: datetime | None = None


def pet_photo_url(pet: Pet) -> str | None:
    if not pet.photo_storage_key:
        return None
    return f"/api/v1/families/{pet.family_id}/pets/{pet.id}/photo?v={pet.photo_version}"


def to_pet_read(pet: Pet) -> PetRead:
    read = PetRead.model_validate(pet, from_attributes=True)
    return read.model_copy(update={"photo_url": pet_photo_url(pet)})
