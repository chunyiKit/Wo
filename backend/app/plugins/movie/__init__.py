"""Movie watchlist plugin — a simple "to-watch / watched" memo.

Importing this package registers the plugin on the global registry. Models
get imported first so the SQLModel table is on metadata before Alembic
autogenerate inspects it.
"""

from app.plugins.movie import models as _models  # noqa: F401  registers table
from app.plugins.movie.manifest import MANIFEST
from app.plugins.movie.routes import router
from app.plugins.movie.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
