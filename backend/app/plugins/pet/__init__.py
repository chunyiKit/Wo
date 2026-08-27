from app.plugins.pet.manifest import manifest
from app.plugins.pet.routes import router
from app.plugins.pet.service import preview_hook
from app.plugins.registry import registry

registry.register(manifest, router=router, preview=preview_hook)

__all__ = ["manifest", "router"]
