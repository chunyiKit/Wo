"""Plant journal (植物日记) plugin — photo-based plant care with AI analysis,
weather context, and watering/fertilizing reminders.

Importing this package registers the plugin on the global registry. Models get
imported first so the SQLModel tables are on metadata before Alembic
autogenerate inspects them.
"""

from app.plugins.plant import models as _models  # noqa: F401  registers tables
from app.plugins.plant.manifest import MANIFEST
from app.plugins.plant.routes import router
from app.plugins.plant.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
