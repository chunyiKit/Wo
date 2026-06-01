"""Plant journal plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import (
    DefaultLayout,
    Permission,
    PluginManifest,
)

MANIFEST = PluginManifest(
    id="plant",
    name="植物日记",
    description_short="给植物拍照，AI 看图给养护建议",
    description_long=(
        "为家里的每株植物建档，定期拍照记录状态。AI 结合照片与实时天气分析植物"
        "长势，给出浇水、施肥、修剪建议；设定养护周期后，到点自动提醒该浇水 / 施肥。"
        "首页卡片显示最近该照料的一株。"
    ),
    emoji="🌿",
    category="life",
    color_token="plant",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(
        Permission(code="location", label="读取定位以获取当地天气"),
        Permission(code="camera", label="拍摄植物照片"),
    ),
    notification_types=("plant_water_due", "plant_fert_due"),
)
