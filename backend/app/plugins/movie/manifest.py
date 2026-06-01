"""Movie plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import DefaultLayout, PluginManifest

MANIFEST = PluginManifest(
    id="movie",
    name="看电影",
    description_short="想看的电影都记下来",
    description_long=(
        "一个简单的电影备忘 —— 加上想看的片名和备注（哪里看到的、谁推荐的），"
        "看过之后一键标记完成。首页卡片显示还有几部想看的、最新加的一部。"
    ),
    emoji="🎬",
    category="entertainment",
    color_token="movie",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
)
