"""Movie plugin tables.

A single resource — `Movie` (a movie a family wants to watch / has watched).
The table is named `movie_movies` (plugin-prefixed) to keep plugin tables
visually separable, mirroring `chore_chores` / `recipe_recipes` / `stock_*`.

Watched is just a flag + timestamp — we don't try to model ratings or where
the movie was watched. Keep it a memo, not a database.
"""

from datetime import UTC, datetime
from typing import Literal
from uuid import UUID

from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

MAX_TITLE_LEN = 80
MAX_NOTE_LEN = 500
# AI intro is asked for as 100-150 chars; allow headroom for the model overrunning.
MAX_INTRO_LEN = 1000

# AI enrichment lifecycle for a movie's intro / rating / poster:
# - none:    not enriched (e.g. rows predating the feature, or manual edits)
# - pending: enrichment scheduled / running in the background
# - ready:   enrichment finished (intro present; poster/rating best-effort)
# - failed:  the AI call or parse failed; the client can offer a retry
AiStatus = Literal["none", "pending", "ready", "failed"]


class MovieBase(SQLModel):
    title: str = Field(max_length=MAX_TITLE_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)


class Movie(MovieBase, table=True):
    __tablename__ = "movie_movies"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    watched: bool = Field(default=False)
    # Stamped when `watched` flips to True; cleared when flipped back to False.
    # The client orders the 「看过」 list by this DESC so the most recent watch
    # bubbles to the top.
    watched_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    # Survives the recorder leaving — keep the movie even when its author is gone.
    created_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )

    # ---- Enriched fields (filled by the background enrichment task) -------
    # Source: The Movie Database (TMDB), matched by title — see
    # app.services.tmdb and app.plugins.movie.enrich.
    # The movie's overview (Chinese when TMDB has a zh-CN translation), trimmed
    # to MAX_INTRO_LEN. None when TMDB carries no overview for it.
    intro: str | None = Field(default=None, max_length=MAX_INTRO_LEN)
    # TMDB's community score (vote_average), 0–10. None when unrated/unknown.
    tmdb_rating: float | None = Field(default=None)
    # The matched TMDB movie id, kept so a re-enrich / future deep-link can refer
    # back to the exact entry. None until a match is found.
    tmdb_id: int | None = Field(default=None)
    # Poster lives in blob storage (COS/local); we keep only the key + type here
    # and serve bytes via the /poster route. `poster_version` busts client image
    # caches when a re-enrichment overwrites the same key.
    poster_storage_key: str | None = Field(default=None)
    poster_content_type: str | None = Field(default=None)
    poster_version: int = Field(default=0)
    # Enrichment lifecycle (one of AiStatus). Stored as str so SQLModel maps it.
    # Named `ai_status` for back-compat with existing rows/clients even though
    # enrichment now reads TMDB rather than an LLM.
    ai_status: str = Field(default="none", max_length=16)


class MovieCreate(MovieBase):
    """POST request body."""


class MovieUpdate(SQLModel):
    """PUT request body — all fields optional for partial update.

    Toggling `watched` here also stamps / clears `watched_at` server-side
    (see routes.update_movie). Clients don't pass `watched_at` directly.
    """

    title: str | None = Field(default=None, max_length=MAX_TITLE_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    watched: bool | None = None


class MovieRead(MovieBase):
    id: UUID
    family_id: UUID
    watched: bool
    watched_at: datetime | None
    created_at: datetime
    created_by: UUID | None
    # Enriched display fields (from TMDB).
    intro: str | None = None
    tmdb_rating: float | None = None
    ai_status: str = "none"
    # Host-relative poster URL (client prepends baseUrl + uses image auth
    # headers), with a `?v=` cache-buster. None when no poster was saved.
    # Injected server-side from poster_storage_key (see service.build_read).
    poster_url: str | None = None


# ---- 片库 (TMDB discover) response/request models --------------------------
# These describe live TMDB data, not saved rows, so they live alongside the
# table models but never touch the database.


class MovieGenreRead(SQLModel):
    """A TMDB movie genre (id + localized name) for the 片库 filter chips."""

    id: int
    name: str


class DiscoverMovieRead(SQLModel):
    """A 片库 result card — a TMDB title not (yet) saved, so keyed by `tmdb_id`.

    `poster_url` is a host-relative URL of the backend thumbnail proxy (the
    client prepends baseUrl + sends image auth headers), so phones load browse
    thumbnails through us rather than from image.tmdb.org directly.
    `already_added` flags titles already in this family's list (UI: 「已在片单」).
    """

    tmdb_id: int
    title: str
    overview: str | None = None
    release_date: str | None = None
    tmdb_rating: float | None = None
    poster_url: str | None = None
    already_added: bool = False


class MovieFromTmdb(SQLModel):
    """POST body for adding a 片库 result to the family's list (by TMDB id)."""

    tmdb_id: int
