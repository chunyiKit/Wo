"""解散家庭前收集附件键，交给调用方在事务提交后删除对象。"""

from uuid import UUID

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import SQLModel

from app.models.family import Family


async def family_storage_keys(session: AsyncSession, family_id: UUID) -> list[str]:
    """包含已离家成员的附件，以及家庭背景、宠物照片和植物日志多图。

    平台与插件共用 SQLModel.metadata；存储引用遵循 storage_key / *_storage_key
    命名，旅行插件沿用 original_key / ai_key，植物日志的 photos 另存多图键。
    只读取当前家庭，必须在外键级联删除数据库行之前调用。
    """
    keys: list[str] = []
    family = await session.get(Family, family_id)
    if family is not None and family.background_storage_key:
        keys.append(family.background_storage_key)
    for table in SQLModel.metadata.tables.values():
        if "family_id" not in table.c:
            continue
        columns = [
            col for col in table.c
            if col.name == "storage_key" or col.name.endswith("_storage_key")
            or col.name in ("original_key", "ai_key")
        ]
        if columns:
            rows = await session.execute(select(*columns).where(table.c.family_id == family_id))
            keys.extend(key for row in rows for key in row if key)
        if table.name == "plant_logs":
            rows = await session.execute(
                select(table.c.photos).where(table.c.family_id == family_id)
            )
            for photos in rows.scalars():
                keys.extend(photo["key"] for photo in (photos or []) if photo.get("key"))
    keys = list(dict.fromkeys(keys))
    if not keys:
        return []
    # 旧版宠物迁移可能让不同家庭共用同一个原图指针。解散一个家庭不能破坏另一个。
    referenced_elsewhere: set[str] = set()
    for table in SQLModel.metadata.tables.values():
        if "family_id" not in table.c:
            continue
        columns = [
            col for col in table.c
            if col.name == "storage_key" or col.name.endswith("_storage_key")
            or col.name in ("original_key", "ai_key")
        ]
        if columns:
            rows = await session.execute(select(*columns).where(
                table.c.family_id != family_id, or_(*(col.in_(keys) for col in columns))
            ))
            referenced_elsewhere.update(key for row in rows for key in row if key)
    return [key for key in keys if key not in referenced_elsewhere]
