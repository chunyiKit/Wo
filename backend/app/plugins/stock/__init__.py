"""Stock (囤货铺) plugin — track household stock + a shared shopping list.

Importing this package registers the plugin on the global registry. The
explicit `models` import comes first so the SQLModel tables are added to
metadata before anything else inspects it (notably Alembic autogenerate).
"""

from app.plugins.registry import registry
from app.plugins.stock import models as _models  # noqa: F401  registers tables
from app.plugins.stock.manifest import MANIFEST
from app.plugins.stock.routes import router
from app.plugins.stock.service import preview_hook

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
