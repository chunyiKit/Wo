"""账号注销：users 增加 deleted_at 标记列。

合规依据：微信《小程序平台常见拒绝情形》3.4.1「在用户注销账号后应相应删除相关
数据」，以及《个人信息保护法》第 47 条。

为什么不直接 DELETE 掉 users 行：记账、宠物、回忆等历史记录的 `created_by`
外键指着它，硬删会让这些记录变孤儿（或触发意料之外的级联）。注销流程会把
phone / password_hash / wechat_openid / avatar / display_name 等全部清空或
匿名化 —— 剩下的这一行**不再包含个人信息**（PIPL 第 4 条的「匿名化」），
保留它是合法的，也是业界通行做法。

nullable：未注销的账号为 NULL，这是绝大多数行的状态。
"""
from alembic import op
import sqlalchemy as sa

revision = "e4f5a6b7c8d9"
down_revision = "c1d2e3f4a5b6"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "users",
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
    )
    # 运维按时间扫「某天之前注销的账号」做二次清理时会用到。
    op.create_index("ix_users_deleted_at", "users", ["deleted_at"])


def downgrade():
    op.drop_index("ix_users_deleted_at", table_name="users")
    op.drop_column("users", "deleted_at")
