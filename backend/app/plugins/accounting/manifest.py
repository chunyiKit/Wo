"""Accounting plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="accounting",
    name="记账",
    description_short="一起记下家里的每一笔支出",
    description_long=(
        "家庭成员各自记账、彼此可见 —— 餐饮、购物、水电、养车一目了然。"
        "设置每月预算，首页卡片实时显示本月支出和剩余额度，预算见底会自动变色提醒。"
    ),
    emoji="💰",
    category="finance",
    color_token="money",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(Permission(code="members.read", label="读取家庭成员列表"),),
    multi_instance=False,
    notification_types=("accounting_month_end",),
)
