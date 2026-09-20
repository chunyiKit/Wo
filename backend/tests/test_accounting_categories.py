"""验证自定义分类持久化、家庭隔离、输入校验及识别后记账。"""

import json
import uuid
from io import BytesIO

import pytest
from httpx import AsyncClient
from PIL import Image

from app.plugins.accounting import receipt
from app.plugins.accounting.models import ALLOWED_CATEGORIES
from app.services.ai import AiResult

MEMBER = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}


async def family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": f"分类-{uuid.uuid4().hex[:8]}"})
    return response.json()["data"]["id"]


def base(fid: str) -> str:
    return f"/api/v1/families/{fid}/plugins/accounting"


async def test_custom_category_shared_and_usable(client: AsyncClient) -> None:
    fid = await family(client)
    response = await client.post(
        base(fid) + "/categories", json={"label": "  旅行  ", "emoji": "✈️"}
    )
    assert response.status_code == 201, response.text
    category = response.json()["data"]
    assert category["label"] == "旅行"
    assert len(category["code"]) <= 16
    invite = await client.post(
        f"/api/v1/families/{fid}/invitations",
        json={"role": "member", "ttl_seconds": 3600, "channel": "link"},
    )
    code = invite.json()["data"]["code"]
    joined = await client.post(f"/api/v1/invitations/{code}/accept", headers=MEMBER)
    assert joined.status_code == 200
    rows = (await client.get(base(fid) + "/categories", headers=MEMBER)).json()["data"]
    assert [c["code"] for c in rows[:-1]] == list(ALLOWED_CATEGORIES)
    assert rows[-1] == category
    created = await client.post(
        base(fid) + "/transactions",
        headers=MEMBER,
        json={"amount": "123.45", "category": category["code"]},
    )
    assert created.status_code == 201, created.text
    tid = created.json()["data"]["id"]
    updated = await client.put(
        base(fid) + f"/transactions/{tid}",
        json={"category": category["code"], "note": "车票"},
    )
    assert updated.status_code == 200
    summary = (await client.get(base(fid) + "/summary")).json()["data"]
    assert float(summary["month_total"]) == 123.45


async def test_category_isolation_and_membership(client: AsyncClient) -> None:
    fid, other = await family(client), await family(client)
    category = (await client.post(base(fid) + "/categories", json={"label": "医疗"})).json()["data"]
    rows = (await client.get(base(other) + "/categories")).json()["data"]
    assert category["code"] not in [c["code"] for c in rows]
    denied = await client.post(
        base(other) + "/transactions",
        json={"amount": 10, "category": category["code"]},
    )
    assert denied.status_code == 422
    existing = (
        await client.post(
            base(other) + "/transactions",
            json={"amount": 10, "category": "dining"},
        )
    ).json()["data"]
    denied = await client.put(
        base(other) + f"/transactions/{existing['id']}",
        json={"category": category["code"]},
    )
    assert denied.status_code == 422
    assert (await client.get(base(fid) + "/categories", headers=MEMBER)).status_code == 404
    assert (
        await client.post(
            base(fid) + "/categories",
            json={"label": "学习"},
            headers=MEMBER,
        )
    ).status_code == 404
    assert (
        await client.post(base(other) + "/categories", json={"label": "医疗"})
    ).status_code == 201


@pytest.mark.parametrize(
    "payload",
    [
        {"label": ""},
        {"label": "   "},
        {"label": "学" * 21},
        {"label": "学习", "emoji": " "},
        {"label": "学习", "emoji": "x" * 17},
        {"label": " 餐饮 "},
    ],
)
async def test_invalid_category(client: AsyncClient, payload: dict) -> None:
    fid = await family(client)
    response = await client.post(base(fid) + "/categories", json=payload)
    assert response.status_code == 422


async def test_duplicate_category_rejected(client: AsyncClient) -> None:
    fid = await family(client)
    assert (await client.post(base(fid) + "/categories", json={"label": "学习"})).status_code == 201
    duplicate = await client.post(base(fid) + "/categories", json={"label": " 学习 "})
    assert duplicate.status_code == 422
    assert duplicate.json()["error"]["message"] == "分类名称已存在"


async def test_scan_uses_family_categories(client: AsyncClient, monkeypatch) -> None:
    fid = await family(client)
    category = (await client.post(base(fid) + "/categories", json={"label": "旅行"})).json()["data"]

    async def vision(**kwargs):
        assert category["code"] in kwargs["user"]
        assert "旅行" in kwargs["user"]
        return AiResult(
            content=json.dumps({"amount": 80, "category": category["code"]}), model="test"
        )

    monkeypatch.setattr(receipt, "ai_complete_vision", vision)
    image = BytesIO()
    Image.new("RGB", (16, 16), "white").save(image, format="JPEG")
    response = await client.post(
        base(fid) + "/receipt-scan",
        files={"file": ("r.jpg", image.getvalue(), "image/jpeg")},
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["category"] == category["code"]
