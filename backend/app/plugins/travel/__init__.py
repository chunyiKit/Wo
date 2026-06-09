"""Travel (旅行) plugin — a map of where the family has been + AI photo restyle.

Importing this package registers the plugin on the global registry. Models get
imported first so the SQLModel table is on metadata before Alembic autogenerate
inspects it.
"""

from app.plugins.registry import registry
from app.plugins.travel import models as _models  # noqa: F401  registers table
from app.plugins.travel.manifest import MANIFEST
from app.plugins.travel.routes import router
from app.plugins.travel.service import preview_hook

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
