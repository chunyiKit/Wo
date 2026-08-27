"""Chat plugin manifest."""

from app.plugins.registry import DefaultLayout, Permission, PluginManifest

MANIFEST = PluginManifest(
    id="chat",
    name="家聊",
    description_short="一家人的唯一群聊，本机长期保存",
    description_long=(
        "把同一个家庭里的成员默认放进一个群聊。消息支持文字和图片，"
        "手机本地长期保存已同步历史，服务端只保留最近 7 天用于多设备同步。"
    ),
    emoji="💬",
    category="life",
    color_token="accent",
    version="0.1.0",
    publisher="Wo Studio",
    default_layout=DefaultLayout(cw=2, ch=2),
    permissions=(Permission(code="members.read", label="读取家庭成员列表"),),
    notification_types=("chat_message",),
)
