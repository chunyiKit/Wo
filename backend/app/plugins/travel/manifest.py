"""Travel (旅行) plugin manifest — static marketplace metadata.

A map of where the family has been. Each record pins one photo to a city on an
interactive China map; zoom in and the photo thumbnails float beside the city.
Add a record with a single photo, then optionally "用一句话重绘这张照片" — the
family's image-gen model restyles it (img2img) while the original is always kept.
"""

from app.plugins.registry import DefaultLayout, PluginManifest

MANIFEST = PluginManifest(
    id="travel",
    name="旅行",
    description_short="一张中国地图，标记你们去过的地方",
    description_long=(
        "把每段旅行钉在地图上 —— 一座城市、一张照片、一句话。"
        "首页是可拖动缩放的中国地图，放大后去过的城市旁会浮出照片缩略图。"
        "添加记录时还能「用一句话重绘这张照片」，让 AI 换个画风或心情，"
        "原图始终保留，喜欢哪张留哪张。"
    ),
    emoji="🧭",
    category="entertainment",
    color_token="travel",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=4, ch=2),
)
