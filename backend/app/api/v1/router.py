"""v1 API aggregator.

Order of operations:
1. Import all platform route modules.
2. Import `app.plugins` — its `__init__.py` imports every plugin sub-package,
   which in turn registers manifests, routes, and preview hooks on the global
   `registry` singleton. This must happen *before* the loop at the bottom.
3. Mount platform routers, then walk the registry to mount each plugin's
   own router (e.g. anniversary's `/families/{id}/plugins/anniversary/...`).
"""

from fastapi import APIRouter

import app.plugins  # noqa: F401  triggers every plugin's registration side effect
from app.api.v1.routes import (
    app_release,
    auth,
    devices,
    families,
    health,
    invitations,
    me,
    members,
    notifications,
    plugins,
)
from app.plugins.registry import registry

api_router = APIRouter(prefix="/api/v1")

# Platform routes.
api_router.include_router(health.router)
api_router.include_router(auth.router)
api_router.include_router(me.router)
api_router.include_router(families.router)
api_router.include_router(members.router)
api_router.include_router(invitations.families_router)
api_router.include_router(invitations.public_router)
api_router.include_router(plugins.marketplace_router)
api_router.include_router(plugins.installed_router)
api_router.include_router(notifications.router)
api_router.include_router(devices.router)
api_router.include_router(app_release.router)

# Per-plugin routes (each registered via its own __init__.py).
for _reg in registry.list_registrations():
    if _reg.router is not None:
        api_router.include_router(_reg.router)
