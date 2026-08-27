from app.plugins.registry import DefaultLayout, Permission, PluginManifest

manifest = PluginManifest(
    id="pet",
    name="宠物日常",
    description_short="全家一起照顾毛孩子",
    description_long="记录今日照护、体重、健康时间线和下一次提醒，不漏做也不重复做。",
    emoji="🐾",
    category="life",
    color_token="pet",
    version="1.0.0",
    publisher="Wo 官方",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(
        Permission(code="pet.read", label="读取家庭宠物档案"),
        Permission(code="pet.write", label="记录宠物照护和健康信息"),
        Permission(code="notification.write", label="发送照护到期提醒"),
    ),
    size_kb=36,
    notification_types=("pet_care_due",),
)
