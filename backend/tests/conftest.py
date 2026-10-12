from collections.abc import AsyncIterator

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.fixture(autouse=True)
def _reset_login_limiter() -> None:
    """Login limiters are process-global; clear them so per-test counts start fresh."""
    from app.api.v1.routes.auth import _login_ip_limiter, _login_phone_limiter

    _login_ip_limiter.reset()
    _login_phone_limiter.reset()


@pytest.fixture
async def client() -> AsyncIterator[AsyncClient]:
    """HTTP client that drives the real ASGI app, lifespan included.

    `LifespanManager` is critical — without it the lifespan never runs and the
    seed user never gets inserted, which breaks any endpoint that touches
    `get_current_user`.
    """
    async with LifespanManager(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            yield ac


@pytest.fixture(autouse=True)
def _enable_test_dev_shim(monkeypatch):
    # Existing plugin tests use the explicit dev channel; app defaults remain secure.
    from app.core.config import settings

    monkeypatch.setattr(settings, "auth_dev_shim_enabled", True)


@pytest.fixture
async def authenticated_account_factory(client):
    """Create only isolated test accounts with genuine session credentials."""
    import uuid

    from app.core.database import async_session_maker
    from app.core.password import hash_password
    from app.models.user import User
    from app.services.session import issue_session

    async def create():
        async with async_session_maker() as session:
            user = User(
                username=f"push-{uuid.uuid4().hex[:16]}",
                display_name="推送测试",
                password_hash=hash_password("synthetic-test-password"),
            )
            session.add(user)
            await session.flush()
            token = await issue_session(session, user.id, ttl_days=1)
            return user.id, token

    return create


@pytest.fixture
async def authenticated_account(authenticated_account_factory):
    return await authenticated_account_factory()
