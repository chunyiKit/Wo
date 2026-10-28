"""微信小程序账号互通：users 增加 openid/unionid 绑定列，auth_sessions 标记来源客户端。

两个标识符列都是 **nullable + unique**：Postgres 的唯一索引允许多个 NULL，
所以未绑定微信的用户之间不会互相冲突，同时保证一个微信身份只能绑一个 Wo 账号
（并发绑定由唯一约束兜底，应用层再加行锁做友好报错）。

`auth_sessions.client` 带 server_default，保证旧行读出来是 "app" 而不是 NULL，
避免调用方到处写 `or "app"`。
"""
from alembic import op
import sqlalchemy as sa

revision = "c1d2e3f4a5b6"
down_revision = "9d94a701bf23"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("users", sa.Column("wechat_openid", sa.String(64), nullable=True))
    op.add_column("users", sa.Column("wechat_unionid", sa.String(64), nullable=True))
    op.create_unique_constraint("uq_users_wechat_openid", "users", ["wechat_openid"])
    op.create_unique_constraint("uq_users_wechat_unionid", "users", ["wechat_unionid"])
    op.create_index("ix_users_wechat_openid", "users", ["wechat_openid"])
    op.create_index("ix_users_wechat_unionid", "users", ["wechat_unionid"])

    op.add_column(
        "auth_sessions",
        sa.Column("client", sa.String(16), nullable=False, server_default="app"),
    )
    op.create_index("ix_auth_sessions_client", "auth_sessions", ["client"])


def downgrade():
    op.drop_index("ix_auth_sessions_client", table_name="auth_sessions")
    op.drop_column("auth_sessions", "client")

    op.drop_index("ix_users_wechat_unionid", table_name="users")
    op.drop_index("ix_users_wechat_openid", table_name="users")
    op.drop_constraint("uq_users_wechat_unionid", "users", type_="unique")
    op.drop_constraint("uq_users_wechat_openid", "users", type_="unique")
    op.drop_column("users", "wechat_unionid")
    op.drop_column("users", "wechat_openid")
