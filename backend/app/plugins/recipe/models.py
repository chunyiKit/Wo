"""Recipe plugin tables.

A single resource — `Recipe` (a dish belonging to a family). The table is named
`recipe_recipes` (plugin-prefixed) to keep plugin tables visually separable.

`ingredients` and `steps` are free-form lists stored as JSONB rather than child
tables: they're only ever read/written as a whole alongside their recipe, never
queried independently, so a relational split would add joins without benefit.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

# Difficulty is a 1..3 scale: 简单 / 中等 / 有点难.
MIN_DIFFICULTY = 1
MAX_DIFFICULTY = 3

# Tags a family starts with; seeded lazily the first time it reads its tag list.
# After that the list is fully family-managed (add/remove persist).
DEFAULT_TAGS = ("早餐", "午餐", "晚餐", "汤羹", "烘焙", "小食")
MAX_TAG_LEN = 16


class Ingredient(SQLModel):
    """One ingredient line, e.g. {name: '番茄', amount: '2个'}."""

    name: str = Field(max_length=32)
    amount: str = Field(default="", max_length=32)


class RecipeBase(SQLModel):
    name: str = Field(max_length=64)
    emoji: str = Field(default="🍳", max_length=16)
    # Free-text category (早餐 / 午餐 / 晚餐 / 汤羹 / 烘焙 / 小食 …); not enum-enforced
    # so families can coin their own.
    category: str = Field(default="", max_length=16)
    minutes: int = Field(default=0, ge=0, le=24 * 60)
    difficulty: int = Field(default=MIN_DIFFICULTY, ge=MIN_DIFFICULTY, le=MAX_DIFFICULTY)
    servings: int | None = Field(default=None, ge=1, le=99)
    note: str | None = Field(default=None, max_length=500)


class Recipe(RecipeBase, table=True):
    __tablename__ = "recipe_recipes"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    ingredients: list[dict] = Field(
        default_factory=list,
        sa_column=Column(JSONB, nullable=False, server_default="[]"),
    )
    steps: list[str] = Field(
        default_factory=list,
        sa_column=Column(JSONB, nullable=False, server_default="[]"),
    )
    # Optional uploaded cover photo. When absent the client falls back to the
    # emoji. `cover_version` bumps on every (re)upload so clients can cache the
    # raw-bytes URL by version and refresh only when it changes.
    cover_storage_key: str | None = Field(default=None, max_length=255)
    cover_content_type: str | None = Field(default=None, max_length=64)
    cover_version: int = Field(default=0, ge=0)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    created_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )


class RecipeTag(SQLModel, table=True):
    """A selectable category/tag in a family's recipe palette.

    Recipes themselves store a free-text `category` string; this table is just
    the family-shared list of suggested choices shown in the editor, so a member
    can curate it (add/remove) without touching existing recipes.
    """

    __tablename__ = "recipe_tags"
    __table_args__ = (UniqueConstraint("family_id", "name", name="uq_recipe_tag"),)

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    name: str = Field(max_length=MAX_TAG_LEN)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class RecipeTagCreate(SQLModel):
    """POST body for adding a tag."""

    name: str = Field(max_length=MAX_TAG_LEN)


class RecipeCreate(RecipeBase):
    """POST request body."""

    ingredients: list[Ingredient] = Field(default_factory=list)
    steps: list[str] = Field(default_factory=list)


class RecipeUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    name: str | None = Field(default=None, max_length=64)
    emoji: str | None = Field(default=None, max_length=16)
    category: str | None = Field(default=None, max_length=16)
    minutes: int | None = Field(default=None, ge=0, le=24 * 60)
    difficulty: int | None = Field(
        default=None, ge=MIN_DIFFICULTY, le=MAX_DIFFICULTY
    )
    servings: int | None = Field(default=None, ge=1, le=99)
    note: str | None = Field(default=None, max_length=500)
    ingredients: list[Ingredient] | None = None
    steps: list[str] | None = None


class RecipeRead(RecipeBase):
    id: UUID
    family_id: UUID
    ingredients: list[Ingredient] = Field(default_factory=list)
    steps: list[str] = Field(default_factory=list)
    created_at: datetime
    created_by: UUID | None
    # Author display info, injected server-side from the family's memberships
    # (see service.build_read). Null when the author left the family.
    creator_name: str | None = None
    creator_emoji: str | None = None
    # Member-avatar URL when the author uploaded a real photo; None → emoji.
    creator_avatar_url: str | None = None
    # Cover photo: version (0 = none) + a relative raw-bytes URL with a `?v=`
    # cache-buster. `cover_url` is None when no photo has been uploaded, in
    # which case clients render the emoji.
    cover_version: int = 0
    cover_url: str | None = None
