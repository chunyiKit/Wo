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
from app.plugins.accounting.reminders import run_accounting_monthly_loop
from app.plugins.anniversary.reminders import run_anniversary_reminder_loop
from app.services.push_dispatcher import run_push_dispatcher


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    await ensure_seed_users()
    await ensure_plugins()

    # Background loops, each gated by its own flag (all off in dev/tests). A
    # single stop event shuts them all down cleanly on app teardown.
    stop = asyncio.Event()
    tasks: list[asyncio.Task[None]] = []
    if settings.push_enabled:
        tasks.append(asyncio.create_task(run_push_dispatcher(stop)))
    if settings.anniversary_reminder_enabled:
        tasks.append(asyncio.create_task(run_anniversary_reminder_loop(stop)))
    if settings.accounting_monthly_notice_enabled:
        tasks.append(asyncio.create_task(run_accounting_monthly_loop(stop)))

    try:
        yield
    finally:
        stop.set()
        for task in tasks:
            await task


def create_app() -> FastAPI:
    app = FastAPI(title=settings.app_name, debug=settings.debug, lifespan=lifespan)
    app.add_middleware(RequestIdMiddleware)
    register_exception_handlers(app)
    app.include_router(api_router)
    return app


app = create_app()
