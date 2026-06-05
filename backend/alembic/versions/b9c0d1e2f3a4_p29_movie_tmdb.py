"""p29 movie TMDB enrichment

Switches the 看电影 plugin's enrichment source from an LLM's recollection to
The Movie Database (TMDB):
- rename movie_movies.douban_rating -> tmdb_rating (now TMDB's vote_average).
- add  movie_movies.tmdb_id (the matched TMDB movie id).

Existing values carry over under the new column name; old rows keep their prior
(LLM-recalled) score until re-enriched against TMDB.

Revision ID: b9c0d1e2f3a4
Revises: a8b9c0d1e2f3
Create Date: 2026-06-03 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b9c0d1e2f3a4"
down_revision: str | None = "a8b9c0d1e2f3"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column("movie_movies", "douban_rating", new_column_name="tmdb_rating")
    op.add_column(
        "movie_movies",
        sa.Column("tmdb_id", sa.Integer(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("movie_movies", "tmdb_id")
    op.alter_column("movie_movies", "tmdb_rating", new_column_name="douban_rating")
