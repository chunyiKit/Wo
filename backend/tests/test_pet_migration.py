"""Deterministic unit coverage for legacy role=pet conversion."""

from datetime import UTC, datetime
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from uuid import UUID


class _Rows:
    def __init__(self, rows=None, scalar=None):
        self._rows = rows or []
        self._scalar = scalar

    def mappings(self):
        return self

    def all(self):
        return self._rows

    def scalar_one_or_none(self):
        return self._scalar


class _Bind:
    def __init__(self):
        self.calls: list[tuple[str, dict]] = []
        self.user_id = UUID("019000a0-1100-7000-8000-000000000003")
        self.family_id = UUID("019000a0-2200-7000-8000-000000000001")

    def execute(self, statement, params=None):
        sql = " ".join(str(statement).split())
        self.calls.append((sql, params or {}))
        if "FROM memberships m JOIN users u" in sql:
            return _Rows(
                [
                    {
                        "user_id": self.user_id,
                        "family_id": self.family_id,
                        "display_name": "团子",
                        "avatar_emoji": "🐈",
                        "joined_at": datetime(2024, 1, 2, tzinfo=UTC),
                        "avatar_storage_key": "avatars/legacy.jpg",
                        "avatar_content_type": "image/jpeg",
                        "avatar_version": 3,
                        "current_family_id": self.family_id,
                    }
                ]
            )
        if "SELECT family_id FROM memberships" in sql:
            return _Rows(scalar=None)
        return _Rows()


def test_legacy_pet_membership_conversion_preserves_identity_and_user(monkeypatch) -> None:
    path = Path(__file__).parents[1] / "alembic/versions/d0e1f2a3b4c5_p40_pet_daily.py"
    spec = spec_from_file_location("pet_migration", path)
    assert spec and spec.loader
    migration = module_from_spec(spec)
    spec.loader.exec_module(migration)
    bind = _Bind()
    monkeypatch.setattr(migration.op, "get_bind", lambda: bind)

    migration._migrate_legacy_pet_memberships()

    pet_insert = next(call for call in bind.calls if "INSERT INTO pets" in call[0])
    assert pet_insert[1]["family_id"] == bind.family_id
    assert pet_insert[1]["name"] == "团子"
    assert pet_insert[1]["emoji"] == "🐈"
    assert pet_insert[1]["legacy_user_id"] == bind.user_id
    assert pet_insert[1]["photo_storage_key"] == "avatars/legacy.jpg"
    assert any("DELETE FROM memberships" in sql for sql, _ in bind.calls)
    assert any("DELETE FROM invitations WHERE role = 'pet'" in sql for sql, _ in bind.calls)
    assert not any("DELETE FROM users" in sql for sql, _ in bind.calls)
    current_family_update = next(
        call for call in bind.calls if "UPDATE users SET current_family_id" in call[0]
    )
    assert current_family_update[1]["next_family"] is None
