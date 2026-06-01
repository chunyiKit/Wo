"""Calendar (家历) plugin — a shared family calendar + todo list.

Importing this package registers the plugin on the global registry. Models get
imported first so the SQLModel table is on metadata before Alembic autogenerate
inspects it.
"""

from app.plugins.calendar import models as _models  # noqa: F401  registers table
from app.plugins.calendar.manifest import MANIFEST
from app.plugins.calendar.routes import router
from app.plugins.calendar.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
