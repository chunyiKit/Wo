"""增加预先验证密码的一次性恢复码；不为旧账号回填凭据。"""
from alembic import op
import sqlalchemy as sa

revision = "b4c5d6e7f8a9"
down_revision = "a3b4c5d6e7f8"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("users", sa.Column("recovery_code_hash", sa.String(64), nullable=True))
    op.add_column("users", sa.Column("recovery_expires_at", sa.DateTime(timezone=True), nullable=True))


def downgrade():
    op.drop_column("users", "recovery_expires_at")
    op.drop_column("users", "recovery_code_hash")
