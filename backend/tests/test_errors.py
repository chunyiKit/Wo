from httpx import AsyncClient


async def test_unknown_route_returns_enveloped_404(client: AsyncClient) -> None:
    response = await client.get("/api/v1/does-not-exist")
    assert response.status_code == 404
    body = response.json()
    assert body["success"] is False
    assert body["data"] is None
    assert body["meta"] is None
    assert body["error"]["code"] == "NOT_FOUND"
    # Message should be human-readable (FastAPI's "Not Found" or similar).
    assert body["error"]["message"]
