"""Accounting plugin registration."""

from app.plugins.accounting import models as _models  # noqa: F401  registers tables
from app.plugins.accounting.manifest import MANIFEST
from app.plugins.accounting.routes import router
from app.plugins.accounting.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
