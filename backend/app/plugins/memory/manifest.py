"""Memory plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="memory",
    name="回忆",
    description_short="以时间线记录你们的生活点滴",
    description_long=(
        "把值得记住的瞬间记成一条条回忆，按时间线串起来。"
        "每段回忆可以配上照片或短视频、写下标题和文案，"
        "另一半还能在下面留言。首页卡片显示最近一段回忆的标题，"
        "以及你们一共记录了多少条。"
    ),
    emoji="📸",
    category="life",
    color_token="memory",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(Permission(code="members.read", label="读取家庭成员列表"),),
)
