"""Stock (囤货铺) plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import DefaultLayout, PluginManifest

MANIFEST = PluginManifest(
    id="stock",
    name="囤货铺",
    description_short="家里囤了啥、还要买啥，一目了然",
    description_long=(
        "把家里囤的日用品记下来，数量见底时一键加进采买清单；"
        "出门买齐打个勾，买到的还能顺手入库。"
        "首页卡片在有东西要补货时提醒你，平时显示采买清单还剩几项。"
    ),
    emoji="🛒",
    category="life",
    color_token="stock",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
)
