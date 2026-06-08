"""AI module tests — payload/response pure functions, the not-configured guard,
and end-to-end calls against a mocked transport (provider override path)."""

import httpx
import pytest

from app.services.ai import (
    AiError,
    AiMessage,
    AiNotConfiguredError,
    ImagePart,
    TextPart,
    ai_complete_text,
    ai_complete_vision,
)
from app.services.ai.client import (
    OpenAICompatibleClient,
    build_payload,
    parse_response,
)

# ---- pure functions --------------------------------------------------------


def test_build_payload_basics() -> None:
    payload = build_payload(
        model="kimi-k2.5",
        messages=[
            AiMessage(role="system", content="be terse"),
            AiMessage(role="user", content="hi"),
        ],
        temperature=0.3,
        max_tokens=None,
    )
    assert payload["model"] == "kimi-k2.5"
    assert payload["temperature"] == 0.3
    assert payload["messages"] == [
        {"role": "system", "content": "be terse"},
        {"role": "user", "content": "hi"},
    ]
    # max_tokens omitted when None (provider uses its own default).
    assert "max_tokens" not in payload


def test_build_payload_includes_max_tokens() -> None:
    payload = build_payload(
        model="m", messages=[AiMessage(role="user", content="x")],
        temperature=0.6, max_tokens=128,
    )
    assert payload["max_tokens"] == 128


def test_build_payload_omits_temperature_when_none() -> None:
    """Thinking models (K2 series) fix temperature to 1 and 400 on any other
    value, so None must drop the field entirely rather than send a default."""
    payload = build_payload(
        model="kimi-k2.6", messages=[AiMessage(role="user", content="x")],
        temperature=None, max_tokens=None,
    )
    assert "temperature" not in payload


def test_parse_response_extracts_content_and_usage() -> None:
    body = {
        "model": "kimi-k2.5",
        "choices": [
            {"message": {"role": "assistant", "content": "餐饮"}, "finish_reason": "stop"}
        ],
        "usage": {"prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12},
    }
    result = parse_response(body, fallback_model="fallback")
    assert result.content == "餐饮"
    assert result.model == "kimi-k2.5"
    assert result.finish_reason == "stop"
    assert result.usage is not None
    assert result.usage.total_tokens == 12


def test_parse_response_captures_reasoning_content() -> None:
    """Thinking models split reasoning from the final answer; capture both."""
    body = {
        "choices": [
            {
                "message": {"content": "餐饮", "reasoning_content": "星巴克是咖啡店…"},
                "finish_reason": "stop",
            }
        ],
    }
    result = parse_response(body, fallback_model="m")
    assert result.content == "餐饮"
    assert result.reasoning_content == "星巴克是咖啡店…"


def test_parse_response_reasoning_absent_is_none() -> None:
    body = {"choices": [{"message": {"content": "x"}, "finish_reason": "stop"}]}
    assert parse_response(body, fallback_model="m").reasoning_content is None


def test_parse_response_empty_choices_raises() -> None:
    with pytest.raises(AiError):
        parse_response({"choices": []}, fallback_model="m")


def test_parse_response_missing_content_raises() -> None:
    with pytest.raises(AiError):
        parse_response(
            {"choices": [{"message": {"role": "assistant"}}]}, fallback_model="m"
        )


# ---- not configured --------------------------------------------------------


async def test_complete_unconfigured_raises() -> None:
    client = OpenAICompatibleClient(
        api_key="", base_url="https://x/v1", model="m", timeout_seconds=5
    )
    with pytest.raises(AiNotConfiguredError):
        await client.complete([AiMessage(role="user", content="hi")])


# ---- end-to-end against a mocked transport ---------------------------------


def _mock_transport(handler) -> httpx.MockTransport:
    return httpx.MockTransport(handler)


async def test_complete_success_via_mock_transport() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["auth"] = request.headers.get("authorization")
        return httpx.Response(
            200,
            json={
                "model": "kimi-k2.5",
                "choices": [
                    {"message": {"content": "你好"}, "finish_reason": "stop"}
                ],
                "usage": {"prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4},
            },
        )

    client = OpenAICompatibleClient(
        api_key="sk-secret",
        base_url="https://api.moonshot.cn/v1",
        model="kimi-k2.5",
        timeout_seconds=5,
        transport=_mock_transport(handler),
    )
    result = await client.complete([AiMessage(role="user", content="hi")])
    assert result.content == "你好"
    assert captured["url"] == "https://api.moonshot.cn/v1/chat/completions"
    assert captured["auth"] == "Bearer sk-secret"


async def test_complete_error_status_raises() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"error": {"message": "bad key"}})

    client = OpenAICompatibleClient(
        api_key="sk-bad",
        base_url="https://api.moonshot.cn/v1",
        model="kimi-k2.5",
        timeout_seconds=5,
        transport=_mock_transport(handler),
    )
    with pytest.raises(AiError):
        await client.complete([AiMessage(role="user", content="hi")])


async def test_ai_complete_text_threads_system_and_user() -> None:
    seen_messages: list = []

    def handler(request: httpx.Request) -> httpx.Response:
        import json

        seen_messages.extend(json.loads(request.content)["messages"])
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": "ok"}, "finish_reason": "stop"}]},
        )

    client = OpenAICompatibleClient(
        api_key="sk-x",
        base_url="https://x/v1",
        model="m",
        timeout_seconds=5,
        transport=_mock_transport(handler),
    )
    result = await ai_complete_text(
        system="只输出分类", user="星巴克 35 元", provider=client
    )
    assert result.content == "ok"
    assert seen_messages == [
        {"role": "system", "content": "只输出分类"},
        {"role": "user", "content": "星巴克 35 元"},
    ]


# ---- multimodal (vision) ---------------------------------------------------


def test_str_content_serializes_verbatim() -> None:
    """Backward compatibility: a str-content message must serialize byte-for-byte
    as before the multimodal extension (existing text-only callers unaffected)."""
    msg = AiMessage(role="user", content="星巴克拿铁 35 元")
    assert msg.to_dict() == {"role": "user", "content": "星巴克拿铁 35 元"}


def test_build_payload_text_only_unchanged() -> None:
    """The whole payload for text-only messages is identical to legacy output."""
    payload = build_payload(
        model="kimi-k2.6",
        messages=[
            AiMessage(role="system", content="be terse"),
            AiMessage(role="user", content="hi"),
        ],
        temperature=None,
        max_tokens=None,
    )
    assert payload == {
        "model": "kimi-k2.6",
        "messages": [
            {"role": "system", "content": "be terse"},
            {"role": "user", "content": "hi"},
        ],
    }


def test_multimodal_message_serializes_to_image_url() -> None:
    msg = AiMessage(
        role="user",
        content=[
            TextPart(text="这株植物怎么样？"),
            ImagePart(image="data:image/jpeg;base64,QUJD"),
        ],
    )
    assert msg.to_dict() == {
        "role": "user",
        "content": [
            {"type": "text", "text": "这株植物怎么样？"},
            {
                "type": "image_url",
                "image_url": {"url": "data:image/jpeg;base64,QUJD"},
            },
        ],
    }


def test_image_part_from_bytes_builds_data_url() -> None:
    part = ImagePart.from_bytes(b"ABC", content_type="image/png")
    # base64("ABC") == "QUJD"
    assert part.image == "data:image/png;base64,QUJD"


def test_with_image_helper_builds_text_plus_image() -> None:
    msg = AiMessage.with_image(text="看图", image_data=b"ABC")
    assert msg.role == "user"
    assert msg.to_dict() == {
        "role": "user",
        "content": [
            {"type": "text", "text": "看图"},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}},
        ],
    }


async def test_ai_complete_vision_sends_image_block() -> None:
    seen_messages: list = []

    def handler(request: httpx.Request) -> httpx.Response:
        import json

        seen_messages.extend(json.loads(request.content)["messages"])
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": "健康"}, "finish_reason": "stop"}]},
        )

    client = OpenAICompatibleClient(
        api_key="sk-x",
        base_url="https://x/v1",
        model="kimi-k2.6",
        timeout_seconds=5,
        transport=_mock_transport(handler),
    )
    result = await ai_complete_vision(
        system="你是植物养护专家", user="分析状态", image_data=b"ABC", provider=client
    )
    assert result.content == "健康"
    assert seen_messages[0] == {"role": "system", "content": "你是植物养护专家"}
    user_msg = seen_messages[1]
    assert user_msg["role"] == "user"
    assert user_msg["content"][0] == {"type": "text", "text": "分析状态"}
    assert user_msg["content"][1]["type"] == "image_url"
    assert user_msg["content"][1]["image_url"]["url"].startswith("data:image/jpeg;base64,")


async def test_complete_vision_unconfigured_raises() -> None:
    client = OpenAICompatibleClient(
        api_key="", base_url="https://x/v1", model="m", timeout_seconds=5
    )
    with pytest.raises(AiNotConfiguredError):
        await ai_complete_vision(user="x", image_data=b"ABC", provider=client)
