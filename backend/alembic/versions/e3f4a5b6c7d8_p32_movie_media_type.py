"""p32 movie media type

Adds movie_movies.tmdb_media_type so the 看电影 watch-list can hold TV shows as
well as films: enrichment now searches TMDB's combined movie+TV index, and this
column records whether a matched id is a movie or a show so a re-enrich looks it
up via /movie/{id} vs /tv/{id}. Existing rows stay NULL (treated as movie).

Revision ID: e3f4a5b6c7d8
Revises: d2e3f4a5b6c7
Create Date: 2026-06-05 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "e3f4a5b6c7d8"
down_revision: str | None = "d2e3f4a5b6c7"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "movie_movies",
        sa.Column(
            "tmdb_media_type",
            sqlmodel.sql.sqltypes.AutoString(length=8),
            nullable=True,
        ),
    )


def downgrade() -> None:
    op.drop_column("movie_movies", "tmdb_media_type")
