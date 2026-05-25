"""Re-export platform SQLModel tables so a single `import app.models` registers
them with SQLModel.metadata. Alembic's env.py also imports `app.plugins`
separately to register per-plugin tables.
"""

from app.models.device_token import DeviceToken
from app.models.family import Family
from app.models.invitation import Invitation
from app.models.membership import Membership
from app.models.notification import Notification
from app.models.plugin import InstalledPlugin, Plugin
from app.models.push_outbox import PushOutbox
from app.models.user import User

__all__ = [
    "DeviceToken",
    "Family",
    "InstalledPlugin",
    "Invitation",
    "Membership",
    "Notification",
    "Plugin",
    "PushOutbox",
    "User",
]
