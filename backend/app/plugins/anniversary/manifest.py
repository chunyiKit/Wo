"""Anniversary plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="anniversary",
    name="纪念日",
    description_short="一起记得每一个重要的日子",
    description_long=(
        "记录家里的纪念日 —— 结婚日、相识日、宝宝生日、买房日 …… "
        "首页卡片会自动显示下一个最近的纪念日，再也不会忘。"
    ),
    emoji="🎂",
    category="life",
    color_token="anniv",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(Permission(code="members.read", label="读取家庭成员列表"),),
)
