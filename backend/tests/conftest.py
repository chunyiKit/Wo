from collections.abc import AsyncIterator

import pytest
from asgi_lifespan import LifespanManager
from httpx import ASGITransport, AsyncClient

from app.main import app


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
