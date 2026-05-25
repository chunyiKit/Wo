"""Device push token model.

Maps a user to a JPush registration id (one per app install). `registration_id`
is globally unique: a device that re-registers after the user logs in as someone
else simply reassigns the row to the new user — see `services.device_token`.
"""

from datetime import UTC, datetime
from uuid import UUID

from pydantic import BaseModel
from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class DeviceToken(SQLModel, table=True):
    __tablename__ = "device_tokens"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    user_id: UUID = Field(
        foreign_key="users.id",
        ondelete="CASCADE",
        index=True,
    )
    # JPush registration id obtained on-device via the JPush SDK. One per install,
    # globally unique so a re-register can reassign the device to another user.
    registration_id: str = Field(max_length=64, unique=True, index=True)
    platform: str = Field(max_length=16)  # "ios" | "android"

    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class DeviceTokenRead(BaseModel):
    """Public shape returned by the registration endpoint."""

    id: UUID
    registration_id: str
    platform: str
    created_at: datetime
