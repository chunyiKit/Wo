"""Expiry (到期管家) plugin manifest — static marketplace metadata.

A reminder ledger for things that *expire* rather than recur as a bill —
证件 (身份证/护照/签证/驾照)、年检、保险、合同、会员卡 …… The plugin reminds
the family ahead of each expiry date (and again once overdue). Unlike
订阅管家, it never auto-advances the date: you renew a passport, you don't
get auto-charged, so the user updates the new date themselves.
"""

from app.plugins.registry import DefaultLayout, PluginManifest

MANIFEST = PluginManifest(
    id="expiry",
    name="到期管家",
    description_short="证件、年检、保险、合同，到期前提醒",
    description_long=(
        "把家里会「到期」的东西都记在一处 —— 身份证、护照、签证、驾照、车险、"
        "年检、房租合同、各种会员卡 …… 设好到期日和想提前几天提醒，"
        "临近到期会提前推送提醒全家，过期了也会再提醒一次，别再错过续期。"
        "首页卡片显示最近一个要到期的项目还剩几天。"
    ),
    emoji="📄",
    category="life",
    color_token="expiry",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    notification_types=("expiry_due", "expiry_expired"),
)
