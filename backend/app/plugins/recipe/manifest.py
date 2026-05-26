"""Recipe plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="recipe",
    name="菜谱",
    description_short="家里的拿手菜，全家一起做",
    description_long=(
        "把家里的拿手菜记下来 —— 食材、步骤、火候时间，按菜系整理。"
        "想吃什么翻一翻就能照着做，首页卡片显示最近新增的一道菜。"
    ),
    emoji="🍳",
    category="life",
    # No dedicated food color in the palette; the warm accent reads well for
    # a "featured dish" home card.
    color_token="accent",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(Permission(code="members.read", label="读取家庭成员列表"),),
)
