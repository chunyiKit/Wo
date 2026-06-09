"""Image-generation client — OpenAI `/images/generations`-compatible.

Covers text-to-image and image-to-image (img2img). The travel plugin uses it for
"用一句话重绘这张照片": the original photo is passed as the `image` field and the
prompt drives the restyle. Targets 字节火山方舟 (Volcengine Ark) Seedream
(`doubao-seedream-*`), whose endpoint speaks this dialect:

    POST {base_url}/images/generations
    { "model": ..., "prompt": ..., "image": "data:image/jpeg;base64,...",
      "size": "2048x2048", "response_format": "b64_json", "watermark": false }
    → { "data": [ { "b64_json": "..." } | { "url": "..." } ] }

`generate` returns raw image bytes (decoding b64, or downloading a returned URL),
so callers can persist them directly. Built per-call from the family's configured
`image` model (see app.services.ai_config); never reads global settings.
"""

from __future__ import annotations

import base64
import logging
from dataclasses import dataclass
from typing import Any

import httpx

from app.services.ai.types import AiError, AiNotConfiguredError

logger = logging.getLogger(__name__)

# Default canvas. 4:3 keeps travel photos from being squished; override per call.
_DEFAULT_SIZE = "2048x2048"


def build_image_payload(
    *,
    model: str,
    prompt: str,
    image_data_url: str | None,
    size: str,
) -> dict[str, Any]:
    """Shape an OpenAI-images-compatible body. Pure function.

    `image_data_url` present → img2img (the source photo as a `data:` URL);
    absent → txt2img. `watermark: false` opts out of Ark's default watermark.
    """
    payload: dict[str, Any] = {
        "model": model,
        "prompt": prompt,
        "size": size,
        "response_format": "b64_json",
        "watermark": False,
    }
    if image_data_url:
        payload["image"] = image_data_url
    return payload


def _to_data_url(image_data: bytes, content_type: str) -> str:
    b64 = base64.b64encode(image_data).decode("ascii")
    return f"data:{content_type};base64,{b64}"


@dataclass(frozen=True)
class ImageGenerationClient:
    api_key: str
    base_url: str
    model: str
    timeout_seconds: float
    transport: httpx.AsyncBaseTransport | None = None

    @property
    def configured(self) -> bool:
        return bool(self.api_key)

    async def generate(
        self,
        prompt: str,
        *,
        image_data: bytes | None = None,
        content_type: str = "image/jpeg",
        size: str = _DEFAULT_SIZE,
    ) -> tuple[bytes, str]:
        """Generate (or restyle) an image. Returns (bytes, content_type).

        Raises `AiNotConfiguredError` when unkeyed, `AiError` on any
        provider/transport/parse failure.
        """
        if not self.configured:
            raise AiNotConfiguredError("图片生成模型未配置 API Key")
        if not prompt.strip():
            raise AiError("提示词不能为空")

        image_data_url = (
            _to_data_url(image_data, content_type) if image_data is not None else None
        )
        payload = build_image_payload(
            model=self.model,
            prompt=prompt,
            image_data_url=image_data_url,
            size=size,
        )
        url = f"{self.base_url.rstrip('/')}/images/generations"
        headers = {"Authorization": f"Bearer {self.api_key}"}
        try:
            async with httpx.AsyncClient(
                timeout=self.timeout_seconds, transport=self.transport
            ) as http:
                resp = await http.post(url, json=payload, headers=headers)
        except httpx.HTTPError as exc:
            detail = str(exc) or type(exc).__name__
            raise AiError(f"图片生成请求失败: {detail}") from exc

        if resp.status_code != 200:
            # Log the provider's error body to diagnose schema mismatches. Only
            # the response (never the key/prompt headers) is logged.
            logger.warning(
                "image gen failed: model=%s HTTP %s body=%s",
                self.model,
                resp.status_code,
                resp.text[:1000],
            )
            raise AiError(f"图片生成返回错误: {resp.status_code} {resp.text}")

        try:
            body = resp.json()
        except ValueError as exc:
            raise AiError("图片生成返回非 JSON 内容") from exc

        return await self._extract_image(body)

    async def _extract_image(self, body: dict[str, Any]) -> tuple[bytes, str]:
        data = body.get("data")
        if not isinstance(data, list) or not data:
            raise AiError("图片生成返回内容为空")
        first = data[0] or {}

        b64 = first.get("b64_json")
        if isinstance(b64, str) and b64:
            try:
                return base64.b64decode(b64), "image/png"
            except (ValueError, TypeError) as exc:
                raise AiError("图片生成返回的 b64 解码失败") from exc

        img_url = first.get("url")
        if isinstance(img_url, str) and img_url:
            try:
                async with httpx.AsyncClient(
                    timeout=self.timeout_seconds, transport=self.transport
                ) as http:
                    img_resp = await http.get(img_url)
            except httpx.HTTPError as exc:
                detail = str(exc) or type(exc).__name__
                raise AiError(f"下载生成图失败: {detail}") from exc
            if img_resp.status_code != 200:
                raise AiError(f"下载生成图失败: {img_resp.status_code}")
            ct = img_resp.headers.get("content-type", "image/png").split(";")[0]
            return img_resp.content, ct or "image/png"

        raise AiError("图片生成返回里没有图片数据")


__all__ = ["ImageGenerationClient", "build_image_payload"]
