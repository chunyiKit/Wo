"""微信身份显式映射，不回填、不合并旧账号。"""
from alembic import op
import sqlalchemy as sa

revision = "d091bc34ea12"
down_revision = "9d94a701bf23"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "wechat_identities",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("app_id", sa.String(64), nullable=False),
        sa.Column("openid", sa.String(128), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("app_id", "openid", name="uq_wechat_app_openid"),
        sa.UniqueConstraint("app_id", "user_id", name="uq_wechat_app_user"),
    )
    op.create_index("ix_wechat_identities_user_id", "wechat_identities", ["user_id"])


def downgrade():
    op.drop_index("ix_wechat_identities_user_id", table_name="wechat_identities")
    op.drop_table("wechat_identities")
