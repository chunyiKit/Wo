"""Receipt-scan tests — pure JSON parsing, the AI-mocked endpoint happy path,
category fallback, and the not-configured / failure / bad-image error paths."""

import io
import uuid

import pytest
from httpx import AsyncClient
from PIL import Image

from app.plugins.accounting import receipt as receipt_mod
from app.plugins.accounting.receipt import ReceiptScanResult, parse_receipt_json
from app.services.ai import AiError, AiNotConfiguredError, AiResult

SCAN = "/api/v1/families/{fid}/plugins/accounting/receipt-scan"


def _jpeg_bytes(color: str = "white") -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (16, 16), color).save(buf, format="JPEG")
    return buf.getvalue()


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post("/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"})
    return resp.json()["data"]["id"]


def _fake_vision(content: str):
    """Return an async stand-in for ai_complete_vision yielding `content`."""

    async def _call(**_kwargs) -> AiResult:
        return AiResult(content=content, model="test")

    return _call


# ---- pure parsing ----------------------------------------------------------


def test_parse_basic() -> None:
    out = parse_receipt_json(
        '{"amount": 35.5, "category": "dining", "merchant": "星巴克", "note": "拿铁两杯"}'
    )
    assert out.amount is not None and str(out.amount) == "35.50"
    assert out.category == "dining"
    assert out.merchant == "星巴克"
    assert out.note == "拿铁两杯"


def test_parse_strips_code_fence_and_currency() -> None:
    out = parse_receipt_json('```json\n{"amount": "¥12", "category": "snack"}\n```')
    assert str(out.amount) == "12.00"
    assert out.category == "snack"


def test_parse_unknown_category_falls_back_to_shopping() -> None:
    out = parse_receipt_json('{"amount": 9, "category": "groceries"}')
    assert out.category == "shopping"


def test_parse_note_falls_back_to_merchant() -> None:
    out = parse_receipt_json('{"amount": 9, "category": "shopping", "merchant": "全家"}')
    assert out.note == "全家"


def test_parse_missing_or_bad_amount_is_none() -> None:
    assert parse_receipt_json('{"category": "dining"}').amount is None
    assert parse_receipt_json('{"amount": 0, "category": "dining"}').amount is None
    assert parse_receipt_json('{"amount": "abc", "category": "dining"}').amount is None


def test_parse_non_json_raises() -> None:
    with pytest.raises(AiError):
        parse_receipt_json("我没看清这张图")


def test_parse_json_array_raises() -> None:
    with pytest.raises(AiError):
        parse_receipt_json("[1, 2, 3]")


# ---- endpoint --------------------------------------------------------------


async def test_scan_happy_path(client: AsyncClient, monkeypatch) -> None:
    monkeypatch.setattr(
        receipt_mod,
        "ai_complete_vision",
        _fake_vision(
            '{"amount": 88, "category": "shopping", "merchant": "山姆", "note": "周末采买"}'
        ),
    )
    fid = await _create_family(client)
    resp = await client.post(
        SCAN.format(fid=fid),
        files={"file": ("r.jpg", _jpeg_bytes(), "image/jpeg")},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["amount"] == "88.00"
    assert data["category"] == "shopping"
    assert data["merchant"] == "山姆"
    assert data["note"] == "周末采买"


async def test_scan_amount_unreadable_returns_null_amount(client: AsyncClient, monkeypatch) -> None:
    monkeypatch.setattr(
        receipt_mod,
        "ai_complete_vision",
        _fake_vision('{"amount": null, "category": "dining", "merchant": "某餐厅"}'),
    )
    fid = await _create_family(client)
    resp = await client.post(
        SCAN.format(fid=fid),
        files={"file": ("r.jpg", _jpeg_bytes(), "image/jpeg")},
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["amount"] is None
    assert data["category"] == "dining"


async def test_scan_not_configured_returns_503(client: AsyncClient, monkeypatch) -> None:
    async def _raise(**_kwargs):
        raise AiNotConfiguredError("no key")

    monkeypatch.setattr(receipt_mod, "ai_complete_vision", _raise)
    fid = await _create_family(client)
    resp = await client.post(
        SCAN.format(fid=fid),
        files={"file": ("r.jpg", _jpeg_bytes(), "image/jpeg")},
    )
    assert resp.status_code == 503
    assert resp.json()["success"] is False


async def test_scan_ai_failure_returns_422(client: AsyncClient, monkeypatch) -> None:
    async def _raise(**_kwargs):
        raise AiError("provider down")

    monkeypatch.setattr(receipt_mod, "ai_complete_vision", _raise)
    fid = await _create_family(client)
    resp = await client.post(
        SCAN.format(fid=fid),
        files={"file": ("r.jpg", _jpeg_bytes(), "image/jpeg")},
    )
    assert resp.status_code == 422


async def test_scan_bad_image_rejected(client: AsyncClient, monkeypatch) -> None:
    # AI should never be reached for a non-image upload.
    async def _boom(**_kwargs):  # pragma: no cover - must not run
        raise AssertionError("AI called on invalid image")

    monkeypatch.setattr(receipt_mod, "ai_complete_vision", _boom)
    fid = await _create_family(client)
    resp = await client.post(
        SCAN.format(fid=fid),
        files={"file": ("r.txt", b"not an image", "text/plain")},
    )
    assert resp.status_code in (400, 422)


def test_result_model_defaults() -> None:
    r = ReceiptScanResult()
    assert r.amount is None
    assert r.category == "shopping"
