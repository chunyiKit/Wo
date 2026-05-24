"""Re-export platform SQLModel tables so a single `import app.models` registers
them with SQLModel.metadata. Alembic's env.py also imports `app.plugins`
separately to register per-plugin tables.
"""

from app.models.family import Family
from app.models.invitation import Invitation
from app.models.membership import Membership
from app.models.notification import Notification
from app.models.plugin import InstalledPlugin, Plugin
from app.models.user import User

__all__ = [
    "Family",
    "InstalledPlugin",
    "Invitation",
    "Membership",
    "Notification",
    "Plugin",
    "User",
]
