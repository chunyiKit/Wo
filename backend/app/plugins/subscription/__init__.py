"""Subscription (订阅管家) plugin — recurring bills with due reminders + auto-record.

Importing this package registers the plugin on the global registry. Models get
imported first so the SQLModel table is on metadata before Alembic autogenerate
inspects it.
"""

from app.plugins.registry import registry
from app.plugins.subscription import models as _models  # noqa: F401  registers table
from app.plugins.subscription.manifest import MANIFEST
from app.plugins.subscription.routes import router
from app.plugins.subscription.service import preview_hook

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
