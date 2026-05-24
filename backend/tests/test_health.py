from httpx import AsyncClient


async def test_health_returns_envelope(client: AsyncClient) -> None:
    response = await client.get("/api/v1/health")
    assert response.status_code == 200
    body = response.json()
    assert body == {
        "success": True,
        "data": {"status": "ok"},
        "error": None,
        "meta": None,
    }


async def test_health_response_has_request_id_header(client: AsyncClient) -> None:
    response = await client.get("/api/v1/health")
    assert response.headers.get("X-Request-Id")


async def test_health_honors_incoming_request_id(client: AsyncClient) -> None:
    response = await client.get(
        "/api/v1/health",
        headers={"X-Request-Id": "test-trace-001"},
    )
    assert response.headers["X-Request-Id"] == "test-trace-001"


async def test_health_db(client: AsyncClient) -> None:
    response = await client.get("/api/v1/health/db")
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["data"] == {"status": "ok", "db": "connected"}
