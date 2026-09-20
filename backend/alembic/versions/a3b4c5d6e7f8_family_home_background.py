"""新增家庭共享的首页背景图片。"""

import sqlalchemy as sa
from alembic import op

revision = "a3b4c5d6e7f8"
down_revision = "f2a3b4c5d6e7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("families", sa.Column("background_storage_key", sa.String(256), nullable=True))
    op.add_column("families", sa.Column("background_content_type", sa.String(64), nullable=True))
    op.add_column("families", sa.Column("background_version", sa.Integer(), nullable=False, server_default="0"))


def downgrade() -> None:
    op.drop_column("families", "background_version")
    op.drop_column("families", "background_content_type")
    op.drop_column("families", "background_storage_key")
