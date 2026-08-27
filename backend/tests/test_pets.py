"""Core Pet identity tests.

Pet is deliberately family-scoped and independent from User/Membership.
"""

import io
import uuid

from httpx import AsyncClient
from PIL import Image

XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}


def _jpeg_bytes() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (16, 16), "orange").save(buf, format="JPEG")
    return buf.getvalue()


async def _create_family(client: AsyncClient) -> str:
    response = await client.post(
        "/api/v1/families", json={"name": f"宠物核心-{uuid.uuid4().hex[:8]}"}
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]["id"]


async def _add_member(client: AsyncClient, family_id: str) -> None:
    invite = (
        await client.post(f"/api/v1/families/{family_id}/invitations", json={"role": "member"})
    ).json()["data"]
    accepted = await client.post(f"/api/v1/invitations/{invite['code']}/accept", headers=XIAOLIN)
    assert accepted.status_code == 200, accepted.text


async def test_pet_crud_is_independent_from_members(client: AsyncClient) -> None:
    family_id = await _create_family(client)
    created = await client.post(
        f"/api/v1/families/{family_id}/pets",
        json={"name": "  团子  ", "emoji": "🐈", "species": "猫", "breed": "英短"},
    )
    assert created.status_code == 201, created.text
    pet = created.json()["data"]
    assert pet["name"] == "团子"
    assert pet["photo_url"] is None

    family = (await client.get(f"/api/v1/families/{family_id}")).json()["data"]
    assert family["member_count"] == 1
    assert family["pet_count"] == 1
    members = (await client.get(f"/api/v1/families/{family_id}/members")).json()["data"]
    assert len(members) == 1

    updated = await client.patch(
        f"/api/v1/families/{family_id}/pets/{pet['id']}",
        json={"name": "团团", "notes": "怕生"},
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["data"]["name"] == "团团"

    archived = await client.delete(f"/api/v1/families/{family_id}/pets/{pet['id']}")
    assert archived.status_code == 200
    assert archived.json()["data"]["archived_at"] is not None
    assert (await client.get(f"/api/v1/families/{family_id}/pets")).json()["data"] == []


async def test_pet_write_requires_admin_and_cross_family_is_hidden(client: AsyncClient) -> None:
    family_id = await _create_family(client)
    other_family_id = await _create_family(client)
    await _add_member(client, family_id)

    denied = await client.post(
        f"/api/v1/families/{family_id}/pets",
        json={"name": "无权限"},
        headers=XIAOLIN,
    )
    assert denied.status_code == 403

    pet = (await client.post(f"/api/v1/families/{family_id}/pets", json={"name": "豆包"})).json()[
        "data"
    ]
    hidden = await client.get(f"/api/v1/families/{other_family_id}/pets/{pet['id']}")
    assert hidden.status_code == 404


async def test_pet_photo_version_and_emoji_fallback(client: AsyncClient) -> None:
    family_id = await _create_family(client)
    pet = (
        await client.post(
            f"/api/v1/families/{family_id}/pets", json={"name": "奶盖", "emoji": "🐶"}
        )
    ).json()["data"]
    assert pet["photo_version"] == 0
    assert pet["photo_url"] is None

    uploaded = await client.post(
        f"/api/v1/families/{family_id}/pets/{pet['id']}/photo",
        files={"file": ("pet.jpg", _jpeg_bytes(), "image/jpeg")},
    )
    assert uploaded.status_code == 200, uploaded.text
    with_photo = uploaded.json()["data"]
    assert with_photo["photo_version"] == 1
    assert with_photo["photo_url"].endswith("?v=1")
    image = await client.get(with_photo["photo_url"])
    assert image.status_code == 200
    assert image.headers["content-type"].startswith("image/")

    removed = await client.delete(f"/api/v1/families/{family_id}/pets/{pet['id']}/photo")
    assert removed.status_code == 200
    assert removed.json()["data"]["photo_version"] == 2
    assert removed.json()["data"]["photo_url"] is None
    assert removed.json()["data"]["emoji"] == "🐶"


async def test_pet_role_is_rejected(client: AsyncClient) -> None:
    family_id = await _create_family(client)
    invitation = await client.post(
        f"/api/v1/families/{family_id}/invitations", json={"role": "pet"}
    )
    assert invitation.status_code == 422
