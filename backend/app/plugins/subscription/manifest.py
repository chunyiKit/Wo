"""Subscription (订阅管家) plugin manifest — static marketplace metadata."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="subscription",
    name="订阅管家",
    description_short="订阅与定期账单，到期提醒还能自动记账",
    description_long=(
        "把家里的订阅和定期账单都记在一处 —— 视频会员、云盘、房租、宽带 …… "
        "按月或按年设好金额和首次扣费日，到期前自动提醒；如果家里还装了「记账」，"
        "到期当天会自动把这笔扣费记进账本（归到「订阅」分类），不用再手动补。"
        "首页卡片显示下一笔最近的扣费。"
    ),
    emoji="💳",
    category="finance",
    color_token="subscribe",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(
        Permission(code="accounting.write", label="到期时把扣费记入「记账」"),
    ),
    notification_types=("subscription_due", "subscription_charged"),
)
