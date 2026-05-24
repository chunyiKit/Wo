"""Health checks. `/health` has no dependencies; `/health/db` round-trips PG."""

from fastapi import APIRouter
from sqlalchemy import text

from app.api.deps import SessionDep
from app.core.response import ApiResponse, ok

router = APIRouter(tags=["health"])


@router.get("/health", response_model=ApiResponse[dict])
async def health() -> ApiResponse[dict]:
    return ok({"status": "ok"})


@router.get("/health/db", response_model=ApiResponse[dict])
async def health_db(session: SessionDep) -> ApiResponse[dict]:
    await session.execute(text("SELECT 1"))
    return ok({"status": "ok", "db": "connected"})
