"""Receipt scanning — turn a photo of a 小票 / 账单 / 付款截图 into a draft expense.

`scan_receipt` inlines the photo to the multimodal model and asks it to extract
the paid amount, the best-fitting built-in category, the merchant, and a short
note. It returns a *draft* only — nothing is written to the ledger and the photo
is never persisted. The client pre-fills the 记一笔 form with the draft so the
user reviews and confirms before saving (mirrors plant: AI suggestions are never
auto-applied).

Design notes (mirror plant.ai):
- The photo is inlined as base64; we hold nothing afterwards.
- A flaky/unconfigured model surfaces as the module's domain errors; the route
  maps them to a friendly message so the user can just type the amount instead.
- The model is asked for strict JSON; `_strip_fence` tolerates a stray ```json
  wrapper despite the instruction.
"""

from __future__ import annotations

import json
import logging
from decimal import Decimal, InvalidOperation
from typing import TYPE_CHECKING, Any
from uuid import UUID

from pydantic import BaseModel

from app.plugins.accounting.models import ALLOWED_CATEGORIES
from app.services.ai import AiError, ai_complete_vision

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

# K2-class thinking models spend tokens reasoning before the JSON answer; keep a
# generous cap so the answer isn't truncated to empty content.
_MAX_TOKENS = 1500
_MAX_MERCHANT_LEN = 40
_MAX_NOTE_LEN = 200
# Fallback when the model returns a category outside the built-in set.
_DEFAULT_CATEGORY = "shopping"

# Category code → Chinese hint shown to the model so it maps to a stable code.
_CATEGORY_HINTS: dict[str, str] = {
    "dining": "餐饮（堂食、外卖、餐厅）",
    "snack": "零食 / 饮料 / 奶茶咖啡",
    "shopping": "购物 / 日用百货 / 超市",
    "utilities": "水电煤、宽带、物业等缴费",
    "car": "养车 / 加油 / 停车 / 维修",
    "subscription": "软件、会员、订阅",
}

_SYSTEM_PROMPT = (
    "你是家庭记账助手。看用户提供的小票 / 账单 / 支付截图，识别出这一笔消费。"
    "只输出一个 JSON 对象，不要任何额外文字、解释或代码块标记。"
)


class ReceiptScanResult(BaseModel):
    """A non-persisted draft expense parsed from a receipt photo.

    `amount` is None when the model couldn't read a total — the client then opens
    the entry form with the category/note pre-filled but the amount blank.
    """

    amount: Decimal | None = None
    category: str = _DEFAULT_CATEGORY
    merchant: str | None = None
    note: str | None = None


def _strip_fence(text: str) -> str:
    """Tolerate a model that wraps JSON in a ```json fence despite instructions."""
    s = text.strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[1] if "\n" in s else s
        s = s.rsplit("```", 1)[0]
    return s.strip()


def _coerce_amount(value: Any) -> Decimal | None:
    """Parse a positive money amount; None for missing/invalid/non-positive."""
    if value is None or isinstance(value, bool):
        return None
    try:
        amount = Decimal(str(value).strip().replace(",", "").lstrip("¥$"))
    except (InvalidOperation, ValueError):
        return None
    if amount <= 0:
        return None
    # Two-decimal money, matching the Transaction column.
    return amount.quantize(Decimal("0.01"))


def _coerce_category(value: Any) -> str:
    if isinstance(value, str) and value.strip() in ALLOWED_CATEGORIES:
        return value.strip()
    return _DEFAULT_CATEGORY


def _coerce_text(value: Any, *, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    return cleaned[:limit] or None


def _build_prompt() -> str:
    cats = "\n".join(f'- "{code}"：{hint}' for code, hint in _CATEGORY_HINTS.items())
    return (
        "请识别这张图片里的一笔消费，返回一个 JSON 对象，字段如下：\n"
        '"amount"：实付总金额（数字，人民币元；识别不到填 null）；\n'
        '"category"：从下面的分类里选最贴切的一个，只填代码：\n'
        f"{cats}\n"
        '"merchant"：商家 / 店铺名称（识别不到填 null）；\n'
        '"note"：不超过 20 字的中文摘要（如「星巴克 拿铁两杯」，识别不到填 null）。'
    )


def parse_receipt_json(raw: str) -> ReceiptScanResult:
    """Parse the model's text answer into a validated draft. Pure function.

    Raises `AiError` when the answer isn't a usable JSON object.
    """
    try:
        data = json.loads(_strip_fence(raw))
    except (json.JSONDecodeError, ValueError) as exc:
        raise AiError("没认出小票内容") from exc
    if not isinstance(data, dict):
        raise AiError("AI 返回的不是 JSON 对象")

    merchant = _coerce_text(data.get("merchant"), limit=_MAX_MERCHANT_LEN)
    note = _coerce_text(data.get("note"), limit=_MAX_NOTE_LEN)
    # Prefer the model's note; fall back to the merchant so the entry form's note
    # is never empty when we did recognize a shop.
    return ReceiptScanResult(
        amount=_coerce_amount(data.get("amount")),
        category=_coerce_category(data.get("category")),
        merchant=merchant,
        note=note or merchant,
    )


async def scan_receipt(
    session: AsyncSession,
    family_id: UUID,
    image_data: bytes,
    *,
    content_type: str,
) -> ReceiptScanResult:
    """Ask the family's multimodal model to read one receipt photo into a draft.

    Raises `AiNotConfiguredError` when the family has no multimodal model set and
    `AiError` on a provider/transport failure or an unparseable answer.
    """
    result = await ai_complete_vision(
        session=session,
        family_id=family_id,
        ai_type="multimodal",
        system=_SYSTEM_PROMPT,
        user=_build_prompt(),
        image_data=image_data,
        content_type=content_type,
        max_tokens=_MAX_TOKENS,
    )
    return parse_receipt_json(result.content)


__all__ = ["ReceiptScanResult", "parse_receipt_json", "scan_receipt"]
