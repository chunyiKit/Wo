"""Family domain model + public read schema.

A `Family` is the unit of data isolation in Wo: every plugin's content lives
inside one family, and only members of that family can access it. See
docs/backend-contract.md §3.2 / §5.2.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import TYPE_CHECKING, Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, StringConstraints
from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

if TYPE_CHECKING:
    from app.models.membership import Membership

Role = Literal["owner", "admin", "member", "child"]


class FamilyBase(SQLModel):
    name: str = Field(max_length=16)
    slogan: str | None = Field(default=None, max_length=24)
    emoji: str = Field(default="🏡", max_length=16)


class Family(FamilyBase, table=True):
    __tablename__ = "families"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    background_storage_key: str | None = Field(default=None, max_length=256)
    background_content_type: str | None = Field(default=None, max_length=64)
    background_version: int = Field(default=0)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class FamilyCreate(FamilyBase):
    """POST /families request body."""


class FamilyUpdate(BaseModel):
    """PATCH /families/{id} request body —每个字段可选，仅更新提供的字段。"""

    name: Annotated[str, StringConstraints(min_length=1, max_length=16)] | None = None
    slogan: Annotated[str, StringConstraints(max_length=24)] | None = None
    emoji: Annotated[str, StringConstraints(min_length=1, max_length=16)] | None = None


class FamilyRead(BaseModel):
    """Public family shape — includes per-viewer fields (`my_role`)."""

    id: UUID
    name: str
    slogan: str | None
    emoji: str
    created_at: datetime
    member_count: int
    pet_count: int = 0
    my_role: Role
    my_unread_count: int = 0
    background_url: str | None = None

    @classmethod
    def from_components(
        cls,
        family: Family,
        membership: Membership,
        member_count: int,
        pet_count: int = 0,
        unread_count: int = 0,
    ) -> FamilyRead:
        """Compose a FamilyRead from a (Family, viewer's Membership, count) triple."""
        return cls(
            id=family.id,
            name=family.name,
            slogan=family.slogan,
            emoji=family.emoji,
            created_at=family.created_at,
            member_count=member_count,
            pet_count=pet_count,
            my_role=membership.role,  # type: ignore[arg-type]
            my_unread_count=unread_count,
            background_url=(
                f"/api/v1/families/{family.id}/background?v={family.background_version}"
                if family.background_storage_key
                else None
            ),
        )
