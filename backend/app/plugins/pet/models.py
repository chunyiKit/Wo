"""Database and API models for the 宠物日常 plugin."""

from datetime import UTC, date, datetime
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel
from pydantic import Field as PydanticField
from sqlalchemy import Column, Date, DateTime, Index, Numeric, UniqueConstraint
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7
from app.models.pet import PetRead

DataKind = Literal["general", "weight"]
RecurrenceUnit = Literal["none", "day", "week", "month", "year"]

MAX_TYPE_NAME_LEN = 32
MAX_ITEM_NAME_LEN = 80
MAX_NOTE_LEN = 2000


class PetRecordType(SQLModel, table=True):
    __tablename__ = "pet_record_types"
    __table_args__ = (
        UniqueConstraint("family_id", "name", name="uq_pet_record_types_family_name"),
    )

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(foreign_key="families.id", ondelete="CASCADE", index=True)
    name: str = Field(max_length=MAX_TYPE_NAME_LEN)
    emoji: str = Field(default="🐾", max_length=16)
    data_kind: str = Field(default="general", max_length=16)
    sort_order: int = Field(default=0)
    archived_at: datetime | None = Field(
        default=None, sa_column=Column(DateTime(timezone=True), nullable=True)
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class RecordTypeCreate(BaseModel):
    name: str = PydanticField(max_length=MAX_TYPE_NAME_LEN)
    emoji: str = PydanticField(default="🐾", max_length=16)
    data_kind: DataKind = "general"


class RecordTypeUpdate(BaseModel):
    name: str | None = PydanticField(default=None, max_length=MAX_TYPE_NAME_LEN)
    emoji: str | None = PydanticField(default=None, max_length=16)
    data_kind: DataKind | None = None
    sort_order: int | None = None
    archived: bool | None = None


class RecordTypeReorder(BaseModel):
    ids: list[UUID]


class RecordTypeRead(BaseModel):
    id: UUID
    family_id: UUID
    name: str
    emoji: str
    data_kind: DataKind
    sort_order: int
    archived: bool = False


class PetCarePlan(SQLModel, table=True):
    __tablename__ = "pet_care_plans"
    __table_args__ = (
        Index("ix_pet_care_plans_due_active", "active", "next_due_date", "family_id"),
    )

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(foreign_key="families.id", ondelete="CASCADE", index=True)
    pet_id: UUID = Field(foreign_key="pets.id", ondelete="CASCADE", index=True)
    record_type_id: UUID = Field(foreign_key="pet_record_types.id", ondelete="RESTRICT", index=True)
    name: str = Field(max_length=MAX_ITEM_NAME_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    recurrence_unit: str = Field(default="none", max_length=16)
    recurrence_interval: int = Field(default=1, ge=1, le=999)
    next_due_date: date | None = Field(
        default=None, sa_column=Column(Date, nullable=True, index=True)
    )
    active: bool = Field(default=True, index=True)
    last_notified_due_date: date | None = Field(default=None, sa_column=Column(Date, nullable=True))
    created_by: UUID | None = Field(
        default=None, foreign_key="users.id", ondelete="SET NULL", nullable=True
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class CarePlanCreate(BaseModel):
    record_type_id: UUID
    name: str = PydanticField(max_length=MAX_ITEM_NAME_LEN)
    note: str | None = PydanticField(default=None, max_length=MAX_NOTE_LEN)
    recurrence_unit: RecurrenceUnit = "none"
    recurrence_interval: int = PydanticField(default=1, ge=1, le=999)
    next_due_date: date | None = None


class CarePlanUpdate(BaseModel):
    record_type_id: UUID | None = None
    name: str | None = PydanticField(default=None, max_length=MAX_ITEM_NAME_LEN)
    note: str | None = PydanticField(default=None, max_length=MAX_NOTE_LEN)
    recurrence_unit: RecurrenceUnit | None = None
    recurrence_interval: int | None = PydanticField(default=None, ge=1, le=999)
    next_due_date: date | None = None
    active: bool | None = None


class CarePlanRead(BaseModel):
    id: UUID
    family_id: UUID
    pet_id: UUID
    record_type_id: UUID
    type_name: str
    type_emoji: str
    data_kind: DataKind
    name: str
    note: str | None
    recurrence_unit: RecurrenceUnit
    recurrence_interval: int
    next_due_date: date | None
    active: bool
    created_by: UUID | None
    created_at: datetime
    updated_at: datetime
    days_until: int | None = None


class FollowUpCreate(BaseModel):
    plan_id: UUID | None = None
    recurrence_unit: RecurrenceUnit = "none"
    recurrence_interval: int = PydanticField(default=1, ge=1, le=999)
    next_due_date: date


class PetRecord(SQLModel, table=True):
    __tablename__ = "pet_records"
    __table_args__ = (
        UniqueConstraint("plan_id", "scheduled_due_date", name="uq_pet_records_plan_due"),
        Index(
            "ix_pet_records_timeline",
            "family_id",
            "pet_id",
            "occurred_on",
            "created_at",
            "id",
        ),
        Index(
            "ix_pet_records_weight",
            "family_id",
            "pet_id",
            "data_kind_snapshot",
            "occurred_on",
        ),
    )

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(foreign_key="families.id", ondelete="CASCADE", index=True)
    pet_id: UUID = Field(foreign_key="pets.id", ondelete="CASCADE", index=True)
    record_type_id: UUID | None = Field(
        default=None,
        foreign_key="pet_record_types.id",
        ondelete="SET NULL",
        nullable=True,
        index=True,
    )
    type_name_snapshot: str = Field(max_length=MAX_TYPE_NAME_LEN)
    type_emoji_snapshot: str = Field(max_length=16)
    data_kind_snapshot: str = Field(default="general", max_length=16)
    name: str = Field(max_length=MAX_ITEM_NAME_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    occurred_on: date = Field(sa_column=Column(Date, nullable=False, index=True))
    next_due_date: date | None = Field(default=None, sa_column=Column(Date, nullable=True))
    weight_kg: Decimal | None = Field(default=None, sa_column=Column(Numeric(7, 3), nullable=True))
    plan_id: UUID | None = Field(
        default=None,
        foreign_key="pet_care_plans.id",
        ondelete="SET NULL",
        nullable=True,
        index=True,
    )
    scheduled_due_date: date | None = Field(default=None, sa_column=Column(Date, nullable=True))
    created_by: UUID | None = Field(
        default=None, foreign_key="users.id", ondelete="SET NULL", nullable=True
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class RecordCreate(BaseModel):
    record_type_id: UUID
    name: str = PydanticField(max_length=MAX_ITEM_NAME_LEN)
    occurred_on: date
    note: str | None = PydanticField(default=None, max_length=MAX_NOTE_LEN)
    weight_kg: Decimal | None = PydanticField(default=None, gt=0, le=1000)
    next_due_date: date | None = None
    follow_up: FollowUpCreate | None = None


class RecordUpdate(BaseModel):
    record_type_id: UUID | None = None
    name: str | None = PydanticField(default=None, max_length=MAX_ITEM_NAME_LEN)
    occurred_on: date | None = None
    note: str | None = PydanticField(default=None, max_length=MAX_NOTE_LEN)
    weight_kg: Decimal | None = PydanticField(default=None, gt=0, le=1000)
    next_due_date: date | None = None


class PlanCompletionCreate(BaseModel):
    occurred_on: date | None = None
    note: str | None = PydanticField(default=None, max_length=MAX_NOTE_LEN)
    weight_kg: Decimal | None = PydanticField(default=None, gt=0, le=1000)
    next_due_date_override: date | None = None
    scheduled_due_date: date | None = None


class PetRecordAttachment(SQLModel, table=True):
    __tablename__ = "pet_record_attachments"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(foreign_key="families.id", ondelete="CASCADE", index=True)
    record_id: UUID = Field(foreign_key="pet_records.id", ondelete="CASCADE", index=True)
    original_filename: str = Field(max_length=255)
    storage_key: str = Field(max_length=255)
    content_type: str = Field(max_length=64)
    size_bytes: int = Field(ge=0)
    sort_order: int = Field(default=0)
    created_by: UUID | None = Field(
        default=None, foreign_key="users.id", ondelete="SET NULL", nullable=True
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class AttachmentRead(BaseModel):
    id: UUID
    original_filename: str
    content_type: str
    size_bytes: int
    sort_order: int
    url: str


class RecordRead(BaseModel):
    id: UUID
    family_id: UUID
    pet_id: UUID
    record_type_id: UUID | None
    type_name: str
    type_emoji: str
    data_kind: DataKind
    name: str
    note: str | None
    occurred_on: date
    next_due_date: date | None
    weight_kg: Decimal | None
    plan_id: UUID | None
    scheduled_due_date: date | None
    created_by: UUID | None
    created_at: datetime
    updated_at: datetime
    creator_name: str | None = None
    creator_emoji: str | None = None
    creator_avatar_url: str | None = None
    attachments: list[AttachmentRead] = PydanticField(default_factory=list)


class WeightPoint(BaseModel):
    record_id: UUID
    occurred_on: date
    weight_kg: Decimal


class PetListItem(BaseModel):
    pet: PetRead
    next_plan: CarePlanRead | None = None
    latest_weight: WeightPoint | None = None


class PetDashboard(BaseModel):
    pet: PetRead
    today_plans: list[CarePlanRead]
    upcoming_plans: list[CarePlanRead]
    latest_weight: WeightPoint | None = None
    weight_trend: list[WeightPoint] = PydanticField(default_factory=list)
    records: list[RecordRead] = PydanticField(default_factory=list)
    records_cursor: str | None = None
