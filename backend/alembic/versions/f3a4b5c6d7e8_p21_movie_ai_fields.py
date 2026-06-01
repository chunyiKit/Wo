"""p21 movie AI enrichment fields

Adds AI-filled columns to movie_movies: intro / douban_rating / poster_* /
ai_status. All nullable or defaulted, so existing rows backfill cleanly
(ai_status defaults to 'none', poster_version to 0).

Revision ID: f3a4b5c6d7e8
Revises: e2f3a4b5c6d7
Create Date: 2026-05-29 12:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'f3a4b5c6d7e8'
down_revision: str | None = 'e2f3a4b5c6d7'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        'movie_movies',
        sa.Column('intro', sqlmodel.sql.sqltypes.AutoString(length=1000), nullable=True),
    )
    op.add_column('movie_movies', sa.Column('douban_rating', sa.Float(), nullable=True))
    op.add_column(
        'movie_movies',
        sa.Column('poster_storage_key', sqlmodel.sql.sqltypes.AutoString(), nullable=True),
    )
    op.add_column(
        'movie_movies',
        sa.Column('poster_content_type', sqlmodel.sql.sqltypes.AutoString(), nullable=True),
    )
    op.add_column(
        'movie_movies',
        sa.Column('poster_version', sa.Integer(), nullable=False, server_default='0'),
    )
    op.add_column(
        'movie_movies',
        sa.Column(
            'ai_status',
            sqlmodel.sql.sqltypes.AutoString(length=16),
            nullable=False,
            server_default='none',
        ),
    )


def downgrade() -> None:
    op.drop_column('movie_movies', 'ai_status')
    op.drop_column('movie_movies', 'poster_version')
    op.drop_column('movie_movies', 'poster_content_type')
    op.drop_column('movie_movies', 'poster_storage_key')
    op.drop_column('movie_movies', 'douban_rating')
    op.drop_column('movie_movies', 'intro')
