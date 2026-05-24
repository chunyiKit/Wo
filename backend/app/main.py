"""FastAPI app factory.

Wiring order matters:
1. Middleware (request id) — must be registered before the app starts taking
   requests so every request gets traced.
2. Exception handlers — must be registered before any router is included, so
   they catch errors from those routes.
3. Routers — mounted last.
4. Lifespan — runs the seed bootstrap on startup.
"""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api.v1.router import api_router
from app.core.config import settings
from app.core.errors import register_exception_handlers
from app.core.middleware import RequestIdMiddleware
from app.core.seed import ensure_plugins, ensure_seed_users


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    await ensure_seed_users()
    await ensure_plugins()
    yield


def create_app() -> FastAPI:
    app = FastAPI(title=settings.app_name, debug=settings.debug, lifespan=lifespan)
    app.add_middleware(RequestIdMiddleware)
    register_exception_handlers(app)
    app.include_router(api_router)
    return app


app = create_app()
