"""微信身份仅映射到既有用户，不保存 session_key 或客户端凭据。"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime, UniqueConstraint
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class WechatIdentity(SQLModel, table=True):
    __tablename__ = "wechat_identities"
    __table_args__ = (
        UniqueConstraint("app_id", "openid", name="uq_wechat_app_openid"),
        UniqueConstraint("app_id", "user_id", name="uq_wechat_app_user"),
    )

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    app_id: str = Field(max_length=64)
    openid: str = Field(max_length=128)
    user_id: UUID = Field(foreign_key="users.id", ondelete="CASCADE", index=True)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
