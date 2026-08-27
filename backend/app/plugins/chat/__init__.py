"""Chat plugin registration."""

from app.plugins.chat import models as _models  # noqa: F401  registers tables
from app.plugins.chat.manifest import MANIFEST
from app.plugins.chat.routes import router
from app.plugins.chat.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest=MANIFEST, router=router, preview=preview_hook)
