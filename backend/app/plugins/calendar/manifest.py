"""Calendar (家历) plugin manifest — static metadata for the marketplace."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="calendar",
    name="家历",
    description_short="全家的日程与待办，一处共享",
    description_long=(
        "把全家的安排都记在一处 —— 谁几点有事、今天该买什么、周末去哪儿。"
        "条目可以排到某一天（带不带时间都行），也可以只是一条没日期的待办；"
        "支持每天 / 每周 / 每月重复，可指派给某位家庭成员，并在到点前提醒。"
        "首页卡片显示下一件该做的事。"
    ),
    emoji="📅",
    category="life",
    color_token="calendar",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(Permission(code="members.read", label="读取家庭成员列表"),),
    notification_types=("calendar_due", "calendar_assigned", "calendar_remind"),
)
