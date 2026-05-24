"""Anniversary plugin — track family dates, surface the next one on home.

Importing this package registers the plugin on the global registry. The
explicit `models` import comes first so the SQLModel table is added to
metadata before anything else inspects it (notably Alembic autogenerate).
"""

from app.plugins.anniversary import models as _models  # noqa: F401  registers table
from app.plugins.anniversary.manifest import MANIFEST
from app.plugins.anniversary.routes import router
from app.plugins.anniversary.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
