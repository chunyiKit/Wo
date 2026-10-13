"""推送设备绑定会话，旧记录安全停用直至有效会话重新登记。"""
from alembic import op
import sqlalchemy as sa

revision = "9d94a701bf23"
down_revision = "b4c5d6e7f8a9"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("device_tokens", sa.Column("session_id", sa.Uuid(), nullable=True))
    op.create_foreign_key("fk_device_tokens_session_id", "device_tokens", "auth_sessions",
                          ["session_id"], ["id"], ondelete="CASCADE")
    op.create_index("ix_device_tokens_session_id", "device_tokens", ["session_id"])


def downgrade():
    op.drop_index("ix_device_tokens_session_id", table_name="device_tokens")
    op.drop_constraint("fk_device_tokens_session_id", "device_tokens", type_="foreignkey")
    op.drop_column("device_tokens", "session_id")
