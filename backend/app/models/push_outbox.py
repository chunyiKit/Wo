"""Push outbox — a transactional-outbox row mirroring a notification's push intent.

Staged in the *same* transaction as the `Notification` it points at (see
`services.notification._add_for_recipients`), so "a notification exists" and "we
owe a push for it" commit atomically. This is what lets us emit pushes without
risking ghost pushes for a rolled-back transaction.

Drained by `services.push_dispatcher`.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime, Index
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

# Lifecycle states. A row starts `pending`; the dispatcher moves it to `sent`
# (delivered, or no device to deliver to) or `failed` (gave up after retries).
STATUS_PENDING = "pending"
STATUS_SENT = "sent"
STATUS_FAILED = "failed"


class PushOutbox(SQLModel, table=True):
    __tablename__ = "push_outbox"
    __table_args__ = (
        # The dispatcher polls "oldest pending first"; this composite index lets
        # PG answer that with a single index scan instead of a full-table sort.
        Index("ix_push_outbox_status_created", "status", "created_at"),
    )

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    notification_id: UUID = Field(
        foreign_key="notifications.id",
        ondelete="CASCADE",
        index=True,
    )
    status: str = Field(default=STATUS_PENDING, max_length=16)
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
