"""Chat plugin tables and public schemas.

One family maps to one chat room. The server keeps only a short sync window
(configured by ``settings.chat_retention_days``); clients persist their own
long-term history locally.
"""

from datetime import UTC, datetime
from uuid import UUID

from pydantic import BaseModel
from pydantic import Field as PydanticField
from sqlalchemy import Column, DateTime, Index, UniqueConstraint
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

KIND_TEXT = "text"
KIND_IMAGE = "image"
MESSAGE_KINDS = (KIND_TEXT, KIND_IMAGE)

MAX_CLIENT_ID_LEN = 80
MAX_BODY_LEN = 2000
MAX_SENDER_NAME_LEN = 24

PUSH_PENDING = "pending"
PUSH_SENT = "sent"
PUSH_FAILED = "failed"


class ChatMessage(SQLModel, table=True):
    __tablename__ = "chat_messages"
    __table_args__ = (
        UniqueConstraint(
            "family_id",
            "sender_id",
            "client_id",
            name="uq_chat_messages_family_sender_client",
        ),
        Index("ix_chat_messages_family_created_id", "family_id", "created_at", "id"),
    )

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    sender_id: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
        index=True,
    )
    client_id: str = Field(max_length=MAX_CLIENT_ID_LEN)
    kind: str = Field(default=KIND_TEXT, max_length=8)
    body: str | None = Field(default=None, max_length=MAX_BODY_LEN)

    # Snapshot the display identity so old local history still has a readable
    # name/emoji if the sender later leaves the family.
    sender_name: str = Field(max_length=MAX_SENDER_NAME_LEN)
    sender_emoji: str = Field(default="👤", max_length=16)

    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class ChatImage(SQLModel, table=True):
    __tablename__ = "chat_images"

    message_id: UUID = Field(
        foreign_key="chat_messages.id",
        primary_key=True,
        ondelete="CASCADE",
    )
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    storage_key: str = Field(max_length=255)
    content_type: str = Field(max_length=64)
    size_bytes: int = Field(ge=0)
    width: int | None = Field(default=None, ge=0)
    height: int | None = Field(default=None, ge=0)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class ChatPushOutbox(SQLModel, table=True):
    __tablename__ = "chat_push_outbox"
    __table_args__ = (Index("ix_chat_push_outbox_status_created", "status", "created_at"),)

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    message_id: UUID = Field(
        foreign_key="chat_messages.id",
        ondelete="CASCADE",
        index=True,
    )
    user_id: UUID = Field(
        foreign_key="users.id",
        ondelete="CASCADE",
        index=True,
    )
    status: str = Field(default=PUSH_PENDING, max_length=16)
    attempts: int = Field(default=0)
    last_error: str | None = Field(default=None, max_length=500)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    sent_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )


class ChatTextCreate(BaseModel):
    client_id: str = PydanticField(min_length=1, max_length=MAX_CLIENT_ID_LEN)
    body: str = PydanticField(min_length=1, max_length=MAX_BODY_LEN)


class ChatImageRead(BaseModel):
    message_id: UUID
    content_type: str
    size_bytes: int
    width: int | None
    height: int | None
    url: str


class ChatMessageRead(BaseModel):
    id: UUID
    family_id: UUID
    sender_id: UUID | None
    client_id: str
    kind: str
    body: str | None
    sender_name: str
    sender_emoji: str
    sender_avatar_url: str | None = None
    created_at: datetime
    image: ChatImageRead | None = None
