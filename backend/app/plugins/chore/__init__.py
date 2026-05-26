"""Chore plugin — assign household tasks to members, nudge them, track who owes.

Importing this package registers the plugin on the global registry. The explicit
`models` import comes first so the SQLModel table is added to metadata before
anything else inspects it (notably Alembic autogenerate).
"""

from app.plugins.chore import models as _models  # noqa: F401  registers table
from app.plugins.chore.manifest import MANIFEST
from app.plugins.chore.routes import router
from app.plugins.chore.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
