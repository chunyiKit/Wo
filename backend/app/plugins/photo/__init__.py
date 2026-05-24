"""Photo plugin — albums + photos, blob storage backed.

Importing this package registers the plugin on the global registry. The
explicit `models` import comes first so the SQLModel tables land on
metadata before Alembic autogenerate inspects them.
"""

from app.plugins.photo import models as _models  # noqa: F401  registers tables
from app.plugins.photo.manifest import MANIFEST
from app.plugins.photo.routes import router
from app.plugins.photo.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
