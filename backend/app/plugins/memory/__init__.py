"""Memory plugin — timeline of moments with photos/videos, text, and comments.

Importing this package registers the plugin on the global registry. The explicit
`models` import comes first so the SQLModel tables are added to metadata before
anything else inspects them (notably Alembic autogenerate).
"""

from app.plugins.memory import models as _models  # noqa: F401  registers tables
from app.plugins.memory.manifest import MANIFEST
from app.plugins.memory.routes import router
from app.plugins.memory.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
