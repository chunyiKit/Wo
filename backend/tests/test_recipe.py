"""Recipe plugin content tests + preview computation."""

import uuid
from io import BytesIO

from httpx import AsyncClient
from PIL import Image

XIAOBAO = {"X-User-Id": "019000a0-1100-7000-8000-000000000003"}


def _png_bytes(color: str = "red") -> bytes:
    buf = BytesIO()
    Image.new("RGB", (8, 8), color).save(buf, format="PNG")
    return buf.getvalue()


def _unique_name() -> str:
    return f"菜谱测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def test_create_and_get_recipe(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        f"/api/v1/families/{fid}/plugins/recipe/recipes",
        json={
            "name": "番茄炒蛋",
            "emoji": "🍅",
            "category": "早餐",
            "minutes": 10,
            "difficulty": 1,
            "servings": 2,
            "ingredients": [
                {"name": "番茄", "amount": "2个"},
                {"name": "鸡蛋", "amount": "3个"},
            ],
            "steps": ["番茄切块", "鸡蛋打散下锅", "倒入番茄翻炒出汁"],
            "note": "番茄要去皮口感更好",
        },
    )
    assert create.status_code == 201, create.text
    created = create.json()["data"]
    assert created["name"] == "番茄炒蛋"
    assert created["category"] == "早餐"
    assert len(created["ingredients"]) == 2
    assert created["ingredients"][0] == {"name": "番茄", "amount": "2个"}
    assert created["steps"][-1] == "倒入番茄翻炒出汁"
    # Author display injected from membership.
    assert created["creator_name"]

    got = await client.get(
        f"/api/v1/families/{fid}/plugins/recipe/recipes/{created['id']}"
    )
    assert got.status_code == 200
    assert got.json()["data"]["name"] == "番茄炒蛋"


async def test_list_and_filter_by_category(client: AsyncClient) -> None:
    fid = await _create_family(client)
    for name, cat in [("红烧肉", "晚餐"), ("可乐鸡翅", "午餐"), ("凉拌黄瓜", "小食")]:
        await client.post(
            f"/api/v1/families/{fid}/plugins/recipe/recipes",
            json={"name": name, "category": cat},
        )

    listing = await client.get(f"/api/v1/families/{fid}/plugins/recipe/recipes")
    assert listing.status_code == 200
    assert len(listing.json()["data"]) == 3

    filtered = await client.get(
        f"/api/v1/families/{fid}/plugins/recipe/recipes?category=晚餐"
    )
    data = filtered.json()["data"]
    assert len(data) == 1
    assert data[0]["name"] == "红烧肉"


async def test_update_recipe(client: AsyncClient) -> None:
    fid = await _create_family(client)
    created = (
        await client.post(
            f"/api/v1/families/{fid}/plugins/recipe/recipes",
            json={"name": "麻婆豆腐", "minutes": 25, "difficulty": 2},
        )
    ).json()["data"]

    updated = await client.put(
        f"/api/v1/families/{fid}/plugins/recipe/recipes/{created['id']}",
        json={
            "minutes": 30,
            "ingredients": [{"name": "豆腐", "amount": "1块"}],
            "steps": ["豆腐切丁焯水", "炒香豆瓣酱", "下豆腐焖煮"],
        },
    )
    assert updated.status_code == 200, updated.text
    data = updated.json()["data"]
    assert data["minutes"] == 30
    assert data["name"] == "麻婆豆腐"  # untouched
    assert len(data["ingredients"]) == 1
    assert len(data["steps"]) == 3


async def test_delete_recipe(client: AsyncClient) -> None:
    fid = await _create_family(client)
    created = (
        await client.post(
            f"/api/v1/families/{fid}/plugins/recipe/recipes",
            json={"name": "测试菜"},
        )
    ).json()["data"]

    deleted = await client.delete(
        f"/api/v1/families/{fid}/plugins/recipe/recipes/{created['id']}"
    )
    assert deleted.status_code == 200

    listing = await client.get(f"/api/v1/families/{fid}/plugins/recipe/recipes")
    assert listing.json()["data"] == []


async def test_get_missing_recipe_404(client: AsyncClient) -> None:
    fid = await _create_family(client)
    missing = await client.get(
        f"/api/v1/families/{fid}/plugins/recipe/recipes/{uuid.uuid4()}"
    )
    assert missing.status_code == 404


async def test_non_member_forbidden(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # 小宝 is not a member of this freshly-created family.
    resp = await client.get(
        f"/api/v1/families/{fid}/plugins/recipe/recipes", headers=XIAOBAO
    )
    assert resp.status_code in (403, 404)


async def _make_recipe(client: AsyncClient, fid: str, name: str = "封面菜") -> dict:
    return (
        await client.post(
            f"/api/v1/families/{fid}/plugins/recipe/recipes",
            json={"name": name},
        )
    ).json()["data"]


async def test_recipe_has_no_cover_by_default(client: AsyncClient) -> None:
    fid = await _create_family(client)
    r = await _make_recipe(client, fid)
    assert r["cover_version"] == 0
    assert r["cover_url"] is None


async def test_upload_cover_sets_url_and_bumps_version(client: AsyncClient) -> None:
    fid = await _create_family(client)
    r = await _make_recipe(client, fid)
    rid = r["id"]

    up = await client.post(
        f"/api/v1/families/{fid}/plugins/recipe/recipes/{rid}/cover",
        files={"file": ("cover.png", _png_bytes(), "image/png")},
    )
    assert up.status_code == 200, up.text
    data = up.json()["data"]
    assert data["cover_version"] == 1
    assert data["cover_url"] is not None
    assert "v=1" in data["cover_url"]

    # Raw bytes are served and look like a PNG.
    raw = await client.get(f"/api/v1/families/{fid}/plugins/recipe/recipes/{rid}/cover")
    assert raw.status_code == 200
    assert raw.headers["content-type"] == "image/png"
    assert raw.content[:8] == b"\x89PNG\r\n\x1a\n"

    # Re-upload bumps the version (cache-buster changes).
    up2 = await client.post(
        f"/api/v1/families/{fid}/plugins/recipe/recipes/{rid}/cover",
        files={"file": ("cover.png", _png_bytes("blue"), "image/png")},
    )
    assert up2.json()["data"]["cover_version"] == 2


async def test_delete_cover_falls_back_to_emoji(client: AsyncClient) -> None:
    fid = await _create_family(client)
    r = await _make_recipe(client, fid)
    rid = r["id"]
    await client.post(
        f"/api/v1/families/{fid}/plugins/recipe/recipes/{rid}/cover",
        files={"file": ("cover.png", _png_bytes(), "image/png")},
    )
    deleted = await client.delete(
        f"/api/v1/families/{fid}/plugins/recipe/recipes/{rid}/cover"
    )
    assert deleted.status_code == 200
    assert deleted.json()["data"]["cover_url"] is None

    raw = await client.get(f"/api/v1/families/{fid}/plugins/recipe/recipes/{rid}/cover")
    assert raw.status_code == 404


async def test_upload_cover_rejects_non_image(client: AsyncClient) -> None:
    fid = await _create_family(client)
    r = await _make_recipe(client, fid)
    rid = r["id"]
    bad = await client.post(
        f"/api/v1/families/{fid}/plugins/recipe/recipes/{rid}/cover",
        files={"file": ("note.txt", b"not an image", "text/plain")},
    )
    assert bad.status_code == 400


async def _tags(client: AsyncClient, fid: str) -> list[str]:
    return (
        await client.get(f"/api/v1/families/{fid}/plugins/recipe/tags")
    ).json()["data"]


async def test_tags_seed_defaults_on_first_read(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # Install the plugin so the seeded-marker has somewhere to live.
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "recipe"})
    tags = await _tags(client, fid)
    assert tags == ["早餐", "午餐", "晚餐", "汤羹", "烘焙", "小食"]


async def test_add_tag(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "recipe"})
    await _tags(client, fid)  # trigger seed
    added = await client.post(
        f"/api/v1/families/{fid}/plugins/recipe/tags", json={"name": "夜宵"}
    )
    assert added.status_code == 201
    assert "夜宵" in added.json()["data"]
    # Idempotent.
    again = await client.post(
        f"/api/v1/families/{fid}/plugins/recipe/tags", json={"name": "夜宵"}
    )
    assert again.json()["data"].count("夜宵") == 1


async def test_delete_tag_sticks(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "recipe"})
    await _tags(client, fid)  # seed defaults

    deleted = await client.delete(
        f"/api/v1/families/{fid}/plugins/recipe/tags", params={"name": "烘焙"}
    )
    assert deleted.status_code == 200
    assert "烘焙" not in deleted.json()["data"]
    # A later read must NOT re-seed the deleted default back.
    assert "烘焙" not in await _tags(client, fid)


async def test_delete_all_tags_stays_empty(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "recipe"})
    for name in await _tags(client, fid):
        await client.delete(
            f"/api/v1/families/{fid}/plugins/recipe/tags", params={"name": name}
        )
    assert await _tags(client, fid) == []


async def test_add_blank_tag_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(
        f"/api/v1/families/{fid}/plugins/recipe/tags", json={"name": "   "}
    )
    assert resp.status_code == 400


async def test_preview_reflects_latest(client: AsyncClient) -> None:
    from app.core.database import async_session_maker
    from app.models.plugin import InstalledPlugin
    from app.plugins.recipe.service import preview_hook

    fid = await _create_family(client)
    await client.post(
        f"/api/v1/families/{fid}/plugins/recipe/recipes",
        json={"name": "红烧排骨", "emoji": "🍖"},
    )

    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="recipe")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip)
    assert preview.primary == "红烧排骨"
    assert "1" in (preview.secondary or "")
