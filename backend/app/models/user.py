"""User domain model.

Matches the User shape defined in docs/backend-contract.md §5.1 / appendix A.

`phone` backs the phone-number login flow (`/auth/login`). SMS verification is
not wired yet — login currently just looks the phone up (and registers it if
new). OAuth/Passkey columns will follow. `phone` is nullable so legacy/seed
rows created before P5 stay valid.

`current_family_id` is normally encoded in the JWT (see contract §4.3); in dev
mode we persist it on the user row so the shim `get_current_user` can resolve
it without a token.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class UserBase(SQLModel):
    username: str = Field(unique=True, index=True, max_length=32)
    display_name: str = Field(max_length=24)
    avatar_emoji: str = Field(default="👤", max_length=16)
    level: int = Field(default=1, ge=1)


class User(UserBase, table=True):
    __tablename__ = "users"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    # Login identifier. Nullable + unique: pre-P5 rows may lack a phone, but no
    # two users can share one. Not exposed in UserRead (kept off public reads).
    phone: str | None = Field(default=None, max_length=20, unique=True, index=True)
    current_family_id: UUID | None = Field(
        default=None,
        foreign_key="families.id",
        ondelete="SET NULL",
        nullable=True,
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class UserRead(UserBase):
    """Public user shape — what the API returns."""

    id: UUID
    created_at: datetime
