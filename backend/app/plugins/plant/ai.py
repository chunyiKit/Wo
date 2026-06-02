"""Plant care AI analysis — looks at a log's photo + environment and produces a
status assessment plus watering/fertilizing/pruning advice.

`analyze_log` is the background task scheduled after a care log is created. It
opens its own DB session (the request's is gone by the time it runs), fetches
the current weather for the plant's location (best-effort), reads the photo back
from storage, asks the multimodal model for a JSON blob, and writes the result
onto the log row.

Design notes (mirrors movie.ai):
- The photo is read back from blob storage and inlined as base64 — the provider
  can't fetch our private COS objects. The stored photo is the durable record;
  the base64 is a throwaway transport for this one call.
- Weather is optional context: a weather failure degrades to photo-only
  analysis rather than failing the task.
- All exceptions are swallowed into `ai_status="failed"` so a flaky model or
  network never crashes the background task. The photo + log row are untouched.
- We never auto-apply the AI's suggested cycles; they're stored as suggestions
  the user adopts explicitly.
"""

from __future__ import annotations

import json
import logging
from typing import Any
from uuid import UUID

from sqlmodel import select

from app.core.database import async_session_maker
from app.core.storage import storage
from app.plugins.plant.models import (
    MAX_ASSESSMENT_LEN,
    Plant,
    PlantFamilySettings,
    PlantLog,
)
from app.services.ai import (
    AiError,
    AiMessage,
    ImagePart,
    TextPart,
    ai_complete,
)
from app.services.weather import WeatherError, WeatherSnapshot, get_weather

logger = logging.getLogger(__name__)

# K2-class thinking models spend tokens reasoning before the JSON answer, so a
# small cap truncates mid-output (empty content). Be generous.
_MAX_TOKENS = 3000
# How many prior logs' assessments to summarize as trend context.
_HISTORY_LIMIT = 3

_SYSTEM_PROMPT = (
    "你是资深植物养护专家。根据用户提供的植物照片与环境信息，分析植物当前状态，"
    "并给出养护建议。只输出一个 JSON 对象，不要任何额外文字、解释或代码块标记。"
)


def _strip_fence(text: str) -> str:
    """Tolerate a model that wraps JSON in a ```json fence despite instructions."""
    s = text.strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[1] if "\n" in s else s
        s = s.rsplit("```", 1)[0]
    return s.strip()


def _coerce_days(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        n = int(value)
        return n if 1 <= n <= 365 else None
    if isinstance(value, str):
        try:
            n = int(float(value.strip()))
        except ValueError:
            return None
        return n if 1 <= n <= 365 else None
    return None


def _weather_text(snap: WeatherSnapshot | None) -> str:
    if snap is None:
        return "（暂无天气数据）"
    parts: list[str] = []
    if snap.condition:
        parts.append(snap.condition)
    if snap.temp_c is not None:
        parts.append(f"气温 {snap.temp_c:.0f}℃")
    if snap.humidity_pct is not None:
        parts.append(f"湿度 {snap.humidity_pct}%")
    if snap.uv_index is not None:
        parts.append(f"紫外线 {snap.uv_index:.0f}")
    if snap.precip_mm is not None:
        parts.append(f"降水 {snap.precip_mm}mm")
    return "，".join(parts) if parts else "（暂无天气数据）"


def _build_prompt(
    plant: Plant,
    weather: WeatherSnapshot | None,
    history: list[str],
    note: str | None,
    photo_count: int = 1,
) -> str:
    intro = (
        f"我提供了同一株植物的 {photo_count} 张照片（不同角度/局部），请综合所有照片判断。"
        if photo_count > 1
        else "请分析这株植物的状态并给出养护建议。"
    )
    lines = [
        intro,
        f"名称：{plant.name}",
        f"品种：{plant.species or '未知（请你从照片推断）'}",
        f"摆放位置：{plant.placement}",
        f"当前环境天气：{_weather_text(weather)}",
    ]
    if note:
        lines.append(f"用户备注：{note}")
    if history:
        lines.append("近期养护记录（由新到旧）：")
        lines.extend(f"- {h}" for h in history)
    lines.append(
        "返回一个 JSON 对象，字段如下：\n"
        '"species"：你从照片识别的品种名（已知则沿用，未知填 null）；\n'
        '"assessment"：100-200字中文，对当前状态的点评（叶片/土壤/光照/长势）；\n'
        '"advice"：对象，含 "watering"/"fertilizing"/"pruning" 三个字符串字段，'
        "分别给浇水、施肥、修剪建议；\n"
        '"suggested_water_days"：建议浇水间隔天数（整数 1-365，不确定填 null）；\n'
        '"suggested_fert_days"：建议施肥间隔天数（整数 1-365，不确定填 null）。'
    )
    return "\n".join(lines)


async def analyze_log(log_id: UUID) -> None:
    """Background task: analyze one care log. Never raises."""
    async with async_session_maker() as session:
        log = await session.get(PlantLog, log_id)
        if log is None:
            return
        plant = await session.get(Plant, log.plant_id)
        if plant is None:
            return

        try:
            # All photos for this log (new logs use `photos`; legacy ones fall
            # back to the single key). The AI looks at every photo together.
            specs = log.photos or (
                [{"key": log.photo_storage_key, "content_type": log.photo_content_type}]
                if log.photo_storage_key
                else []
            )
            if not specs:
                raise AiError("记录没有照片，无法分析")

            # 1) Weather (best-effort) for the plant's family location.
            weather = await _fetch_weather(session, plant)

            # 2) Read every photo back from storage.
            images: list[tuple[bytes, str]] = []
            for spec in specs:
                key = spec.get("key")
                if not key:
                    continue
                try:
                    data_bytes = await storage.get(key)
                except FileNotFoundError as exc:
                    raise AiError("照片文件丢失") from exc
                images.append((data_bytes, spec.get("content_type") or "image/jpeg"))
            if not images:
                raise AiError("照片文件丢失")

            # 3) Recent history as trend context.
            history = await _recent_assessments(session, plant.id, exclude=log.id)

            # 4) Multimodal call — text prompt + every photo as an image block.
            parts: list[object] = [
                TextPart(text=_build_prompt(plant, weather, history, log.note, len(images)))
            ]
            for img_bytes, content_type in images:
                parts.append(ImagePart.from_bytes(img_bytes, content_type=content_type))
            result = await ai_complete(
                [
                    AiMessage(role="system", content=_SYSTEM_PROMPT),
                    AiMessage(role="user", content=parts),
                ],
                max_tokens=_MAX_TOKENS,
            )
            data = json.loads(_strip_fence(result.content))
            if not isinstance(data, dict):
                raise AiError("AI 返回的不是 JSON 对象")
        except (AiError, json.JSONDecodeError, ValueError) as exc:
            logger.warning("plant log analyze failed for %s: %s", log_id, exc)
            log.ai_status = "failed"
            session.add(log)
            await session.commit()
            return

        # Persist the env snapshot (weather + placement) for trend display.
        log.env_snapshot = _env_snapshot(plant, weather)

        assessment = data.get("assessment")
        if isinstance(assessment, str) and assessment.strip():
            log.ai_assessment = assessment.strip()[:MAX_ASSESSMENT_LEN]

        advice = data.get("advice")
        if isinstance(advice, dict):
            log.ai_advice = {
                k: str(v)
                for k, v in advice.items()
                if k in {"watering", "fertilizing", "pruning"} and v is not None
            }

        log.ai_suggested_water_days = _coerce_days(data.get("suggested_water_days"))
        log.ai_suggested_fert_days = _coerce_days(data.get("suggested_fert_days"))

        # Backfill species onto the plant if the model identified one and we had
        # none. Never overwrites a user-provided species.
        species = data.get("species")
        if (not plant.species) and isinstance(species, str) and species.strip():
            plant.species = species.strip()[:60]
            session.add(plant)

        log.ai_status = "ready"
        session.add(log)
        await session.commit()


async def _fetch_weather(session, plant: Plant) -> WeatherSnapshot | None:
    settings_row = await session.get(PlantFamilySettings, plant.family_id)
    if (
        settings_row is None
        or settings_row.latitude is None
        or settings_row.longitude is None
    ):
        return None
    try:
        return await get_weather(settings_row.latitude, settings_row.longitude)
    except WeatherError as exc:
        logger.info("weather unavailable for plant %s: %s", plant.id, exc)
        return None


async def _recent_assessments(session, plant_id: UUID, *, exclude: UUID) -> list[str]:
    stmt = (
        select(PlantLog)
        .where(PlantLog.plant_id == plant_id, PlantLog.id != exclude)
        .order_by(PlantLog.created_at.desc())
        .limit(_HISTORY_LIMIT)
    )
    rows = list((await session.execute(stmt)).scalars().all())
    out: list[str] = []
    for r in rows:
        if r.ai_assessment:
            stamp = r.created_at.date().isoformat()
            out.append(f"{stamp}：{r.ai_assessment[:80]}")
    return out


def _env_snapshot(plant: Plant, weather: WeatherSnapshot | None) -> dict[str, Any]:
    snap: dict[str, Any] = {"placement": plant.placement}
    if weather is not None:
        snap["weather"] = {
            "temp_c": weather.temp_c,
            "humidity_pct": weather.humidity_pct,
            "uv_index": weather.uv_index,
            "precip_mm": weather.precip_mm,
            "condition": weather.condition,
            "observed_at": weather.observed_at,
        }
    return snap


__all__ = ["analyze_log"]
