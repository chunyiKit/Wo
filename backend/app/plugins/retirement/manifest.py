"""Retirement countdown plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="retirement",
    name="退休倒计时",
    description_short="把资产、负债、目标放一起，倒数退休那天",
    description_long=(
        "记下家里的存款、公积金和房贷车贷，设好每月固定收入、退休日期和存款目标，"
        "插件就替你算清楚：按现在的节奏还要多少个月能达标、要在退休前攒够每月还得多攒多少。"
        "每月自动入账固定收入、定时扣还月供，还会和「记账」打通，月初把上个月的支出从存款里结算掉。"
    ),
    emoji="🏖️",
    category="finance",
    color_token="retire",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(Permission(code="members.read", label="读取家庭成员列表"),),
    multi_instance=False,
    notification_types=("retirement_debt_charged", "retirement_expense_settled"),
)
