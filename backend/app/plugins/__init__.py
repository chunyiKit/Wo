"""Importing this package loads every plugin and triggers its registration.

Each plugin's own `__init__.py` calls `registry.register(...)`, so the side
effect of importing the sub-package is enough. Alembic's env.py and the v1
router both rely on this implicit registration.

To add a new plugin: drop a sub-package under `app/plugins/`, register it in
its own `__init__.py`, then import it here.
"""

# Each import below runs the sub-package's __init__.py and registers itself.
from app.plugins import (  # noqa: F401
    accounting,
    anniversary,
    chore,
    photo,
    recipe,
)
from app.plugins.registry import registry  # noqa: F401  re-export for convenience

__all__ = ["registry"]
