"""Photo plugin manifest."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="photo",
    name="家庭相册",
    description_short="一起记录家的日常",
    description_long=(
        "把家里的照片集中起来 —— 一起上传、一起翻看，按相册整理。"
        "首页卡片显示最近上传的照片和本周新增数量。"
    ),
    emoji="📷",
    category="life",
    color_token="photo",
    version="0.1.0",
    publisher="Wo Studio",
    # Large card by default — photos benefit from real estate.
    default_layout=DefaultLayout(cw=4, ch=2),
    permissions=(Permission(code="members.read", label="读取家庭成员列表"),),
    # 后端有 routes / models,但前端尚未实现详情页 → 装上点开是死的。
    # 暂时下架,等前端补齐再翻回 True;现有 family 已装的实例不受影响。
    published=False,
)
