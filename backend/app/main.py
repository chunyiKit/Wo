"""FastAPI app factory.

Wiring order matters:
1. Middleware (request id) — must be registered before the app starts taking
   requests so every request gets traced.
2. Exception handlers — must be registered before any router is included, so
   they catch errors from those routes.
3. Routers — mounted last.
4. Lifespan — runs the seed bootstrap on startup.
"""

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api.v1.router import api_router
from app.core.config import settings
from app.core.errors import register_exception_handlers
from app.core.middleware import RequestIdMiddleware
from app.core.seed import ensure_plugins, ensure_seed_users
from app.services.push_dispatcher import run_push_dispatcher


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    await ensure_seed_users()
    await ensure_plugins()

    # Background push dispatcher — only when push is enabled (off in dev/tests).
    stop_push = asyncio.Event()
    push_task: asyncio.Task[None] | None = None
    if settings.push_enabled:
        push_task = asyncio.create_task(run_push_dispatcher(stop_push))

    try:
        yield
    finally:
        if push_task is not None:
            stop_push.set()
            await push_task


def create_app() -> FastAPI:
    app = FastAPI(title=settings.app_name, debug=settings.debug, lifespan=lifespan)
    app.add_middleware(RequestIdMiddleware)
    register_exception_handlers(app)
    app.include_router(api_router)
    return app


app = create_app()
