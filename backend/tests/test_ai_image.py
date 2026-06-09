"""Image-generation client tests — payload shape, b64/url extraction, img2img."""

import base64

import httpx
import pytest

from app.services.ai import ImageGenerationClient, ai_generate_image
from app.services.ai.image_client import build_image_payload
from app.services.ai.types import AiError, AiNotConfiguredError

_PNG = base64.b64decode(
    # 1x1 transparent PNG
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)


def test_build_payload_txt2img_omits_image() -> None:
    p = build_image_payload(model="m", prompt="夕阳", image_data_url=None, size="1024x1024")
    assert p["model"] == "m"
    assert p["prompt"] == "夕阳"
    assert p["response_format"] == "b64_json"
    assert p["watermark"] is False
    assert "image" not in p


def test_build_payload_img2img_includes_image() -> None:
    p = build_image_payload(
        model="m", prompt="重绘", image_data_url="data:image/jpeg;base64,QUJD", size="1024x1024"
    )
    assert p["image"] == "data:image/jpeg;base64,QUJD"


def _client(handler) -> ImageGenerationClient:
    return ImageGenerationClient(
        api_key="sk-img",
        base_url="https://ark.example/api/v3",
        model="doubao-seedream-5-0-260128",
        timeout_seconds=10,
        transport=httpx.MockTransport(handler),
    )


async def test_generate_b64_returns_bytes_and_sends_image() -> None:
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json

        seen["url"] = str(request.url)
        seen["body"] = json.loads(request.content)
        return httpx.Response(
            200, json={"data": [{"b64_json": base64.b64encode(_PNG).decode()}]}
        )

    client = _client(handler)
    data, ct = await client.generate(
        "把它画成吉卜力风格", image_data=b"ORIGINAL", content_type="image/jpeg"
    )
    assert data == _PNG
    assert ct == "image/png"
    assert seen["url"].endswith("/images/generations")
    # img2img: the original is sent inline as a data URL.
    assert seen["body"]["image"].startswith("data:image/jpeg;base64,")


async def test_generate_downloads_url_when_no_b64() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/images/generations"):
            return httpx.Response(200, json={"data": [{"url": "https://img.example/x.png"}]})
        # the follow-up image download
        return httpx.Response(200, content=_PNG, headers={"content-type": "image/png"})

    client = _client(handler)
    data, ct = await client.generate("夕阳")
    assert data == _PNG
    assert ct == "image/png"


async def test_generate_unconfigured_raises() -> None:
    client = ImageGenerationClient(
        api_key="", base_url="https://x", model="m", timeout_seconds=5
    )
    with pytest.raises(AiNotConfiguredError):
        await client.generate("x")


async def test_generate_error_status_raises() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(403, json={"error": "bad key"})

    with pytest.raises(AiError):
        await _client(handler).generate("x")


async def test_ai_generate_image_with_explicit_client() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"data": [{"b64_json": base64.b64encode(_PNG).decode()}]})

    data, ct = await ai_generate_image(prompt="夕阳", client=_client(handler))
    assert data == _PNG
