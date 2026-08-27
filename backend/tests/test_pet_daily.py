"""宠物日常 plugin API and recurrence tests."""

import asyncio
import uuid
from datetime import date

from httpx import AsyncClient

from app.plugins.pet.service import advance_date

BASE = "/api/v1/families/{fid}/plugins/pet"
XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}
XIAOBAO = {"X-User-Id": "019000a0-1100-7000-8000-000000000003"}


async def _family_pet(client: AsyncClient) -> tuple[str, dict]:
    family = await client.post(
        "/api/v1/families", json={"name": f"宠物日常-{uuid.uuid4().hex[:8]}"}
    )
    family_id = family.json()["data"]["id"]
    pet = await client.post(
        f"/api/v1/families/{family_id}/pets",
        json={"name": "团子", "emoji": "🐈", "breed": "英短"},
    )
    return family_id, pet.json()["data"]


async def _types(client: AsyncClient, family_id: str) -> list[dict]:
    response = await client.get(f"{BASE.format(fid=family_id)}/record-types")
    assert response.status_code == 200, response.text
    return response.json()["data"]


def test_recurrence_clamps_month_end_and_leap_day() -> None:
    assert advance_date(date(2025, 1, 31), "month", 1) == date(2025, 2, 28)
    assert advance_date(date(2024, 2, 29), "year", 1) == date(2025, 2, 28)
    assert advance_date(date(2025, 3, 1), "week", 2) == date(2025, 3, 15)
    assert advance_date(date(2025, 3, 1), "none", 1) is None


async def test_default_and_custom_record_types_are_flexible(client: AsyncClient) -> None:
    family_id, _pet = await _family_pet(client)
    first = await _types(client, family_id)
    second = await _types(client, family_id)
    assert [item["name"] for item in first] == [
        "喂食",
        "遛狗",
        "铲砂",
        "喂药",
        "驱虫",
        "疫苗",
        "体检",
        "体重",
        "洗护",
        "其他",
    ]
    assert [item["id"] for item in first] == [item["id"] for item in second]

    custom = await client.post(
        f"{BASE.format(fid=family_id)}/record-types",
        json={"name": "剪指甲", "emoji": "✂️", "data_kind": "general"},
    )
    assert custom.status_code == 201, custom.text
    custom_id = custom.json()["data"]["id"]
    archived = await client.patch(
        f"{BASE.format(fid=family_id)}/record-types/{custom_id}", json={"archived": True}
    )
    assert archived.status_code == 200
    assert archived.json()["data"]["archived"] is True


async def test_default_record_type_initialization_is_concurrency_safe(
    client: AsyncClient,
) -> None:
    family_id, _pet = await _family_pet(client)
    url = f"{BASE.format(fid=family_id)}/record-types"
    first, second = await asyncio.gather(client.get(url), client.get(url))
    assert first.status_code == second.status_code == 200
    assert len(first.json()["data"]) == len(second.json()["data"]) == 10
    assert len({item["name"] for item in first.json()["data"]}) == 10


async def test_record_snapshot_weight_validation_and_pagination(client: AsyncClient) -> None:
    family_id, pet = await _family_pet(client)
    types = await _types(client, family_id)
    weight_type = next(item for item in types if item["data_kind"] == "weight")
    vaccine_type = next(item for item in types if item["name"] == "疫苗")
    base = BASE.format(fid=family_id)

    missing_weight = await client.post(
        f"{base}/pets/{pet['id']}/records",
        json={
            "record_type_id": weight_type["id"],
            "name": "晨间体重",
            "occurred_on": "2026-08-10",
        },
    )
    assert missing_weight.status_code == 400

    weight = await client.post(
        f"{base}/pets/{pet['id']}/records",
        json={
            "record_type_id": weight_type["id"],
            "name": "晨间体重",
            "occurred_on": "2026-08-10",
            "weight_kg": "4.850",
        },
    )
    assert weight.status_code == 201, weight.text
    assert "/members/" in weight.json()["data"]["creator_avatar_url"]

    vaccine = await client.post(
        f"{base}/pets/{pet['id']}/records",
        json={
            "record_type_id": vaccine_type["id"],
            "name": "猫三联",
            "occurred_on": "2026-08-11",
            "note": "第二针",
        },
    )
    assert vaccine.status_code == 201, vaccine.text
    changed_type = await client.patch(
        f"{base}/record-types/{vaccine_type['id']}", json={"name": "年度疫苗", "emoji": "🧪"}
    )
    assert changed_type.status_code == 200
    immutable_kind = await client.patch(
        f"{base}/record-types/{vaccine_type['id']}", json={"data_kind": "weight"}
    )
    assert immutable_kind.status_code == 409

    page1 = await client.get(f"{base}/pets/{pet['id']}/records", params={"limit": 1})
    assert page1.status_code == 200
    assert page1.json()["data"][0]["type_name"] == "疫苗"
    cursor = page1.json()["meta"]["cursor"]
    page2 = await client.get(
        f"{base}/pets/{pet['id']}/records", params={"limit": 1, "cursor": cursor}
    )
    assert page2.json()["data"][0]["type_name"] == "体重"
    trend = await client.get(f"{base}/pets/{pet['id']}/weights")
    assert trend.json()["data"][0]["weight_kg"] == "4.850"


async def test_plan_completion_is_idempotent_and_dashboard_aggregates(
    client: AsyncClient,
) -> None:
    family_id, pet = await _family_pet(client)
    types = await _types(client, family_id)
    deworm = next(item for item in types if item["name"] == "驱虫")
    base = BASE.format(fid=family_id)
    plan = await client.post(
        f"{base}/pets/{pet['id']}/plans",
        json={
            "record_type_id": deworm["id"],
            "name": "体内驱虫",
            "recurrence_unit": "month",
            "recurrence_interval": 3,
            "next_due_date": "2026-08-14",
        },
    )
    assert plan.status_code == 201, plan.text
    plan_id = plan.json()["data"]["id"]
    body = {"occurred_on": "2026-08-16", "scheduled_due_date": "2026-08-14"}
    first, second = await asyncio.gather(
        client.post(f"{base}/pets/{pet['id']}/plans/{plan_id}/completions", json=body),
        client.post(f"{base}/pets/{pet['id']}/plans/{plan_id}/completions", json=body),
    )
    assert first.status_code == second.status_code == 201
    assert first.json()["data"]["id"] == second.json()["data"]["id"]

    plans = await client.get(f"{base}/pets/{pet['id']}/plans")
    assert plans.json()["data"][0]["next_due_date"] == "2026-11-16"
    dashboard = await client.get(f"{base}/pets/{pet['id']}")
    assert dashboard.status_code == 200, dashboard.text
    assert dashboard.json()["data"]["records"][0]["name"] == "体内驱虫"
    pet_list = await client.get(f"{base}/pets")
    assert pet_list.status_code == 200
    assert pet_list.json()["data"][0]["next_plan"]["name"] == "体内驱虫"


async def test_record_attachment_and_creator_delete_permission(client: AsyncClient) -> None:
    family_id, pet = await _family_pet(client)
    types = await _types(client, family_id)
    checkup = next(item for item in types if item["name"] == "体检")
    base = BASE.format(fid=family_id)
    invite = (
        await client.post(f"/api/v1/families/{family_id}/invitations", json={"role": "member"})
    ).json()["data"]
    await client.post(f"/api/v1/invitations/{invite['code']}/accept", headers=XIAOLIN)
    record = await client.post(
        f"{base}/pets/{pet['id']}/records",
        json={
            "record_type_id": checkup["id"],
            "name": "年度体检",
            "occurred_on": "2026-08-14",
        },
        headers=XIAOLIN,
    )
    assert record.status_code == 201, record.text
    record_id = record.json()["data"]["id"]
    attachment = await client.post(
        f"{base}/records/{record_id}/attachments",
        files={"file": ("report.pdf", b"%PDF-1.4\npet", "application/pdf")},
        headers=XIAOLIN,
    )
    assert attachment.status_code == 201, attachment.text
    attachment_data = attachment.json()["data"]
    downloaded = await client.get(attachment_data["url"], headers=XIAOLIN)
    assert downloaded.status_code == 200
    assert downloaded.headers["content-type"] == "application/pdf"

    other_family_id, _other_pet = await _family_pet(client)
    isolated = await client.get(attachment_data["url"].replace(family_id, other_family_id))
    assert isolated.status_code == 404

    invite_other = (
        await client.post(f"/api/v1/families/{family_id}/invitations", json={"role": "member"})
    ).json()["data"]
    await client.post(f"/api/v1/invitations/{invite_other['code']}/accept", headers=XIAOBAO)
    forbidden_upload = await client.post(
        f"{base}/records/{record_id}/attachments",
        files={"file": ("other.pdf", b"%PDF-1.4\nother", "application/pdf")},
        headers=XIAOBAO,
    )
    assert forbidden_upload.status_code == 403
    forbidden = await client.delete(f"{base}/pets/{pet['id']}/records/{record_id}", headers=XIAOBAO)
    assert forbidden.status_code == 403

    another_member_delete = await client.delete(f"{base}/pets/{pet['id']}/records/{record_id}")
    assert another_member_delete.status_code == 200  # family owner/admin may delete
