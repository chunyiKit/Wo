"""Chore plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="chore",
    name="家务活",
    description_short="分配家务，谁该干一目了然",
    description_long=(
        "把家里的家务待办列出来，分配给不同的家庭成员，"
        "干完打个勾。需要催一催时，手动给负责人发条提醒。"
        "首页卡片显示你自己还有几件家务没做。"
    ),
    emoji="🧹",
    category="life",
    color_token="chore",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(Permission(code="members.read", label="读取家庭成员列表"),),
)
