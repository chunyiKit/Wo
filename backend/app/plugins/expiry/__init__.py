"""Expiry (到期管家) plugin — expiry-date reminders for 证件 / 年检 / 保险 / 合同.

Importing this package registers the plugin on the global registry. Models get
imported first so the SQLModel table is on metadata before Alembic autogenerate
inspects it.
"""

from app.plugins.expiry import models as _models  # noqa: F401  registers table
from app.plugins.expiry.manifest import MANIFEST
from app.plugins.expiry.routes import router
from app.plugins.expiry.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
