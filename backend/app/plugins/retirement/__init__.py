"""Retirement countdown plugin registration."""

from app.plugins.registry import registry
from app.plugins.retirement import models as _models  # noqa: F401  registers tables
from app.plugins.retirement.manifest import MANIFEST
from app.plugins.retirement.routes import router
from app.plugins.retirement.service import preview_hook

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
