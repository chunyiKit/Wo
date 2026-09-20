"""家庭共享的支出分类；内置分类保留原代码，自定义分类持久化保存。"""

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.plugins.accounting.models import ALLOWED_CATEGORIES, CategoryRead, CustomCategory

BUILTIN_CATEGORIES = (
    CategoryRead(code="dining", label="餐饮", emoji="🍜"),
    CategoryRead(code="snack", label="零食", emoji="🍭"),
    CategoryRead(code="shopping", label="购物", emoji="🛍️"),
    CategoryRead(code="utilities", label="水电", emoji="💡"),
    CategoryRead(code="car", label="养车", emoji="🚗"),
    CategoryRead(code="pet", label="宠物", emoji="🐾"),
    CategoryRead(code="subscription", label="软件/订阅", emoji="💳"),
)


async def family_categories(session: AsyncSession, family_id: UUID) -> list[CategoryRead]:
    rows = (
        (
            await session.execute(
                select(CustomCategory)
                .where(CustomCategory.family_id == family_id)
                .order_by(CustomCategory.created_at, CustomCategory.code)
            )
        )
        .scalars()
        .all()
    )
    return [*BUILTIN_CATEGORIES, *(CategoryRead.model_validate(row) for row in rows)]


async def validate_category(session: AsyncSession, family_id: UUID, code: str) -> None:
    if code in ALLOWED_CATEGORIES:
        return
    row = await session.get(CustomCategory, code)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.VALIDATION_ERROR, "分类不存在，请重新选择", status_code=422)
