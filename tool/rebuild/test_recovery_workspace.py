#!/usr/bin/env python3
"""独立 Python SQLite/文件语义 oracle + Dart 源码契约检查。

本文件不导入、不执行 Dart/Flutter/SDK，不证明手机实现通过。
模型只接收合成的已校验包；不模拟 vault 密钥认证、操作来源认证或平台相册权限。
SQLite事务、文件独占创建、SHA读取与tar再打包由Python实际执行。
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import tarfile
import tempfile
import unittest
import uuid
from dataclasses import dataclass, replace
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
CHUNK = 65536
MAX_RECORDS = 32 * 1024 * 1024
# 同仓库准备测试中的合成1x1 JPEG；不读取个人照片。
THUMBNAIL = base64.b64decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzGiiiuw5T/9k=')
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}")


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_file(path: Path) -> tuple[int, str]:
    total, digest = 0, hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK):
            digest.update(chunk)
            total += len(chunk)
    return total, digest.hexdigest()


class OracleError(Exception):
    pass


class Interrupted(OracleError):
    pass


@dataclass(frozen=True)
class Entry:
    source_id: str
    kind: str
    size: int
    digest: str
    exact: bool = False
    missing: str = ""
    source: Path | None = None

    def manifest(self) -> dict:
        return dict(id=self.source_id, kind=self.kind, size=self.size, sha256=self.digest,
                    source_exact=self.exact, missing_reason=self.missing)


@dataclass(frozen=True)
class Package:
    stage: Path
    family: str
    entries: tuple[Entry, ...]

    @property
    def manifest(self) -> dict:
        return dict(version=1, family_id=self.family, entries=[e.manifest() for e in self.entries])

    @property
    def fingerprint(self) -> str:
        return sha(canonical(self.manifest))


class LegacyHandles:
    """若模型误用归档中的旧权限/URI，此陷阱会使测试失败。"""
    def __init__(self):
        self.calls = []

    def resolve(self, value):
        self.calls.append(value)
        raise AssertionError("不得解析旧Photos/Files URI或handle")


class WorkspaceOracle:
    """独立参考模型，刻意不是生产Dart实现或其翻译执行器。

    一个Python catalog表示发布事务；objects表示独立归属媒体。
    importing和已复制对象可持久化；history+ready必须同事务发布。
    """
    def __init__(self, root: Path, legacy: LegacyHandles | None = None,
                 asset_ids: Callable[[], str] | None = None):
        self.root, self.legacy = root, legacy or LegacyHandles()
        if root.is_symlink():
            raise OracleError("private_root_required")
        root.mkdir(mode=0o700, parents=False, exist_ok=True)
        if not root.is_dir() or stat.S_IMODE(root.stat().st_mode) & 0o077:
            raise OracleError("private_root_required")
        self.objects = root / "objects"
        if self.objects.is_symlink():
            raise OracleError("unsafe_objects")
        self.objects.mkdir(mode=0o700, exist_ok=True)
        self.path = root / "library.sqlite"
        for suffix in ("", "-wal", "-shm", "-journal"):
            path = Path(str(self.path) + suffix)
            if path.is_symlink() or path.exists() and not path.is_file():
                raise OracleError("unsafe_database")
        self.db = sqlite3.connect(self.path)
        self.db.row_factory = sqlite3.Row
        os.chmod(self.path, 0o600)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS workspaces(
            id TEXT PRIMARY KEY, fingerprint TEXT UNIQUE NOT NULL, owner TEXT NOT NULL,
            source_family TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('importing','ready')),
            document_count INTEGER NOT NULL, missing_count INTEGER NOT NULL,
            unverified_count INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS history(
            workspace TEXT NOT NULL, ordinal INTEGER NOT NULL, payload BLOB NOT NULL,
            PRIMARY KEY(workspace,ordinal));
          CREATE TABLE IF NOT EXISTS assets(
            id TEXT PRIMARY KEY, workspace TEXT NOT NULL, import_key TEXT NOT NULL,
            descriptor TEXT NOT NULL, status TEXT NOT NULL,
            UNIQUE(workspace,import_key));
          CREATE TABLE IF NOT EXISTS orphans(id TEXT PRIMARY KEY);
        """)
        self._asset_ids = asset_ids or (lambda: "o_" + secrets.token_hex(16))

    def close(self):
        if self.db is not None:
            self.db.close()
            self.db = None

    @staticmethod
    def _hit(fault, point):
        if fault == point:
            raise Interrupted(point)

    def _source(self, package: Package, entry: Entry):
        path = entry.source
        if path is None or path.is_symlink() or not path.is_file():
            raise OracleError("unsafe_source")
        if path.resolve().parent != package.stage.resolve():
            raise OracleError("source_outside_verified_stage")
        if path.stat().st_size != entry.size:
            raise OracleError("actual_source_size")
        if digest_file(path) != (entry.size, entry.digest):
            raise OracleError("source_integrity")

    def preview(self, package: Package, expected_family: str) -> dict:
        if package.family != expected_family:
            raise OracleError("cross_family")
        seen, documents = set(), []
        for entry in package.entries:
            if not ID.fullmatch(entry.source_id) or entry.source_id in seen:
                raise OracleError("invalid_or_duplicate_id")
            seen.add(entry.source_id)
            if entry.kind not in ("records", "photo", "video", "thumbnail"):
                raise OracleError("invalid_kind")
            if entry.missing:
                if entry.source is not None or entry.size or entry.digest or entry.exact:
                    raise OracleError("invalid_missing")
                continue
            if entry.kind == "records" and entry.size > MAX_RECORDS:
                raise OracleError("record_limit")
            self._source(package, entry)
            if entry.kind == "records":
                data = json.loads(entry.source.read_bytes())
                if data["family_id"] != expected_family or data["records_applied"] is not False:
                    raise OracleError("historical_wrapper")
                documents.extend(data["documents"])
        return dict(fingerprint=package.fingerprint, documents=documents,
                    missing=sum(bool(e.missing) for e in package.entries),
                    unverified=sum(e.kind in ("photo", "video") and not e.missing and not e.exact
                                   for e in package.entries))

    def _fresh(self) -> str:
        for _ in range(16):
            value = self._asset_ids()
            if not re.fullmatch(r"o_[a-f0-9]{32}", value):
                raise OracleError("invalid_random_id")
            path = self.objects / (value + ".blob")
            occupied = self.db.execute("SELECT 1 FROM assets WHERE id=?", (value,)).fetchone()
            orphan = self.db.execute("SELECT 1 FROM orphans WHERE id=?", (value,)).fetchone()
            if not occupied and not orphan and not path.exists() and not path.is_symlink():
                return value
        raise OracleError("id_collision")

    def _asset(self, workspace: str, entry: Entry, fault=None):
        descriptor = canonical(entry.manifest()).decode()
        row = self.db.execute("SELECT * FROM assets WHERE workspace=? AND import_key=?",
                              (workspace, entry.source_id)).fetchone()
        if row and row["descriptor"] != descriptor:
            raise OracleError("immutable_import_mapping")
        if row is None:
            identity = self._fresh()
            with self.db:
                self.db.execute("INSERT INTO assets VALUES(?,?,?,?,?)",
                                (identity, workspace, entry.source_id, descriptor,
                                 "missing" if entry.missing else "copying"))
            row = self.db.execute("SELECT * FROM assets WHERE id=?", (identity,)).fetchone()
        if entry.missing:
            return row["id"]
        path = self.objects / (row["id"] + ".blob")
        if path.is_symlink():
            raise OracleError("unsafe_owned_file")
        if path.exists():
            if digest_file(path) == (entry.size, entry.digest):
                with self.db:
                    self.db.execute("UPDATE assets SET status='ready' WHERE id=?", (row["id"],))
                return row["id"]
            if row["status"] == "ready":
                raise OracleError("published_asset_integrity")
            # 不截断失败对象；重试以新ID保留旧的私有残片。
            identity = self._fresh()
            with self.db:
                self.db.execute("INSERT INTO orphans VALUES(?)", (row["id"],))
                self.db.execute("UPDATE assets SET id=?,status='copying' WHERE id=?", (identity, row["id"]))
            row = self.db.execute("SELECT * FROM assets WHERE id=?", (identity,)).fetchone()
            path = self.objects / (identity + ".blob")
        self._hit(fault, "after_reserve")
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as target, entry.source.open("rb") as source:
                while chunk := source.read(CHUNK):
                    target.write(chunk)
                    if entry.kind == "photo":
                        self._hit(fault, "during_copy")
                target.flush()
                os.fsync(target.fileno())
            if digest_file(path) != (entry.size, entry.digest):
                raise OracleError("owned_integrity")
            with self.db:
                self.db.execute("UPDATE assets SET status='ready' WHERE id=?", (row["id"],))
            self._hit(fault, "after_copy")
            return row["id"]
        except BaseException:
            with self.db:
                self.db.execute("UPDATE assets SET status='failed' WHERE id=?", (row["id"],))
            raise

    def import_package(self, package: Package, *, expected_family: str, confirmed: bool,
                       fingerprint: str, fault=None, observe: Callable | None = None) -> str:
        if not confirmed:
            raise OracleError("confirmation_required")
        plan = self.preview(package, expected_family)
        if fingerprint != plan["fingerprint"]:
            raise OracleError("confirmation_changed")
        row = self.db.execute("SELECT * FROM workspaces WHERE fingerprint=?", (fingerprint,)).fetchone()
        if row and row["state"] == "ready":
            return row["id"]
        if row is None:
            identity, owner = str(uuid.uuid4()), str(uuid.uuid4())
            with self.db:
                self.db.execute("INSERT INTO workspaces VALUES(?,?,?,?,?,?,?,?)",
                                (identity, fingerprint, owner, package.family, "importing",
                                 len(plan["documents"]), plan["missing"], plan["unverified"]))
        else:
            identity = row["id"]
        self._hit(fault, "after_workspace_reserve")
        for entry in package.entries:
            self._asset(identity, entry, fault)
        self._hit(fault, "before_publish")
        self.db.execute("BEGIN IMMEDIATE")
        try:
            self.db.execute("DELETE FROM history WHERE workspace=?", (identity,))
            for ordinal, document in enumerate(plan["documents"]):
                self.db.execute("INSERT INTO history VALUES(?,?,?)", (identity, ordinal, canonical(document)))
                if ordinal == 0:
                    if observe:
                        observe()
                    self._hit(fault, "during_publish")
            self.db.execute("UPDATE workspaces SET state='ready' WHERE id=? AND state='importing'", (identity,))
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise
        self._hit(fault, "after_publish")
        return identity

    def ready(self) -> list[dict]:
        return [dict(r) for r in self.db.execute("SELECT * FROM workspaces WHERE state='ready'")]

    def flags(self, workspace: str) -> dict:
        row = self.db.execute("SELECT * FROM workspaces WHERE id=? AND state='ready'", (workspace,)).fetchone()
        if row is None:
            raise OracleError("workspace_unavailable")
        return dict(normalImportAllowed=False, peerExportable=False, recordsApplied=False,
                    fullDeviceComplete=False, restricted=True,
                    declaredBytesComplete=row["missing_count"] == 0 and row["unverified_count"] == 0)

    def read(self, workspace: str, asset: str) -> bytes:
        self.flags(workspace)
        row = self.db.execute("SELECT * FROM assets WHERE workspace=? AND id=?", (workspace, asset)).fetchone()
        if row is None or row["status"] != "ready":
            raise OracleError("owned_unavailable")
        descriptor = json.loads(row["descriptor"])
        path = self.objects / (asset + ".blob")
        if path.is_symlink() or not path.is_file() or digest_file(path) != (descriptor["size"], descriptor["sha256"]):
            raise OracleError("owned_integrity")
        return path.read_bytes()

    def repack(self, workspace: str) -> bytes:
        """实际tar打包，仅证明独立模型字节语义，不声称Wo/vault线协议兼容。"""
        self.flags(workspace)
        rows = list(self.db.execute("SELECT * FROM assets WHERE workspace=? ORDER BY import_key", (workspace,)))
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for row in rows:
                descriptor = json.loads(row["descriptor"])
                if row["status"] == "missing":
                    continue
                data = self.read(workspace, row["id"])
                member = tarfile.TarInfo("entries/" + descriptor["id"])
                member.mode, member.mtime, member.size = 0o600, 0, len(data)
                tar.addfile(member, io.BytesIO(data))
        return stream.getvalue()


def fixture(parent: Path, *, missing=False, exact=True, old_uri="content://synthetic-old-device/Photos/1") -> Package:
    stage = parent / ("verified-" + secrets.token_hex(5))
    stage.mkdir(mode=0o700)
    records = canonical(dict(version=1, family_id="source-family", records_applied=False, documents=[
        dict(space="source-family", collection="/families/source-family/members", id="old-device",
             fields=dict(role="owner", status="active", user_id="old-device")),
        dict(space="p_old", collection="/families/p_old/plugins/memory/memories", id="memory-old",
             fields=dict(title="合成私密历史", body="仅历史文本：" + old_uri, visibility="private")),
    ]))
    entries = []
    payloads = (("records-v1", "records", records, False),
                ("thumb_photo-old", "thumbnail", THUMBNAIL, False),
                ("photo-old", "photo", b"synthetic-original-EXIF-GPS\x00" + bytes(range(256)) * 600, exact),
                ("video-old", "video", b"synthetic-original-video\x00" + bytes(range(255)) * 700, True))
    for source_id, kind, data, source_exact in payloads:
        if missing and kind == "photo":
            entries.append(Entry(source_id, kind, 0, "", False, "source_unavailable"))
            continue
        path = stage / (secrets.token_hex(16) + ".blob")
        path.write_bytes(data)
        os.chmod(path, 0o600)
        entries.append(Entry(source_id, kind, len(data), sha(data), source_exact, source=path))
    return Package(stage, "source-family", tuple(entries))


class RecoveryOracleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wo-recovery-oracle-")
        self.parent = Path(self.temp.name)
        self.legacy = LegacyHandles()
        self.model = WorkspaceOracle(self.parent / "private", self.legacy)
        self.package = fixture(self.parent)

    def tearDown(self):
        self.model.close()
        self.temp.cleanup()

    def run_import(self, **kwargs):
        return self.model.import_package(self.package, expected_family=self.package.family,
                                        confirmed=True, fingerprint=self.package.fingerprint, **kwargs)

    def test_new_identity_private_files_reopen_and_same_bytes_repack(self):
        identity = self.run_import()
        row = self.model.ready()[0]
        self.assertNotEqual(identity, "source-family")
        self.assertNotEqual(row["owner"], "old-device")
        self.assertEqual(len(row["owner"]), 36)
        self.assertEqual(stat.S_IMODE(self.model.root.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.model.path.stat().st_mode), 0o600)
        original = next(e for e in self.package.entries if e.kind == "photo")
        asset = self.model.db.execute("SELECT * FROM assets WHERE import_key=?", (original.source_id,)).fetchone()
        self.assertNotEqual(asset["id"], original.source_id)
        self.assertEqual(stat.S_IMODE((self.model.objects / (asset["id"] + ".blob")).stat().st_mode), 0o600)
        self.model.close()
        self.model = WorkspaceOracle(self.parent / "private", self.legacy)
        self.assertEqual(sha(self.model.read(identity, asset["id"])), original.digest)
        packed = self.model.repack(identity)
        with tarfile.open(fileobj=io.BytesIO(packed), mode="r:") as tar:
            restored = tar.extractfile("entries/" + original.source_id).read()
        self.assertEqual(restored, original.source.read_bytes())
        self.assertEqual(sha(restored), original.digest)
        with tarfile.open(fileobj=io.BytesIO(packed), mode="r:") as tar:
            for entry in self.package.entries:
                if entry.kind in ("photo", "video"):
                    raw = tar.extractfile("entries/" + entry.source_id).read()
                    self.assertEqual(raw, entry.source.read_bytes())
                    self.assertEqual(sha(raw), entry.digest)
        self.assertFalse(self.model.flags(identity)["fullDeviceComplete"])
        self.assertEqual(self.legacy.calls, [])

    def test_missing_original_preserves_thumbnail_and_never_claims_complete(self):
        self.package = fixture(self.parent, missing=True)
        identity = self.run_import()
        rows = list(self.model.db.execute("SELECT * FROM assets WHERE workspace=?", (identity,)))
        self.assertEqual(sum(r["status"] == "missing" for r in rows), 1)
        thumb = next(r for r in rows if json.loads(r["descriptor"])["kind"] == "thumbnail")
        self.assertEqual(self.model.read(identity, thumb["id"]), THUMBNAIL)
        flags = self.model.flags(identity)
        self.assertFalse(flags["declaredBytesComplete"])
        self.assertFalse(flags["normalImportAllowed"])
        self.assertFalse(flags["peerExportable"])
        self.assertFalse(flags["recordsApplied"])
        self.assertTrue(flags["restricted"])

    def test_unverified_provenance_is_not_upgraded_by_matching_sha(self):
        self.package = fixture(self.parent, exact=False)
        identity = self.run_import()
        self.assertFalse(self.model.flags(identity)["declaredBytesComplete"])
        self.assertEqual(self.model.ready()[0]["unverified_count"], 1)

    def test_publication_is_atomic_to_second_sqlite_connection_and_retry(self):
        observer = sqlite3.connect(self.model.path)
        observations = []
        def observe():
            observations.append((observer.execute("SELECT count(*) FROM history").fetchone()[0],
                                 observer.execute("SELECT count(*) FROM workspaces WHERE state='ready'").fetchone()[0]))
        with self.assertRaises(Interrupted):
            self.run_import(fault="during_publish", observe=observe)
        self.assertEqual(observations, [(0, 0)])
        self.assertEqual(self.model.ready(), [])
        self.assertEqual(self.model.db.execute("SELECT count(*) FROM history").fetchone()[0], 0)
        reserved = dict(self.model.db.execute("SELECT * FROM workspaces").fetchone())
        identity = self.run_import(observe=observe)
        self.assertEqual(identity, reserved["id"])
        self.assertEqual(self.model.ready()[0]["owner"], reserved["owner"])
        self.assertEqual(observer.execute("SELECT count(*) FROM history").fetchone()[0], 2)
        self.assertEqual(observer.execute("SELECT count(*) FROM workspaces WHERE state='ready'").fetchone()[0], 1)
        observer.close()

    def test_interrupted_partial_copy_keeps_old_bytes_and_allocates_new_id(self):
        with self.assertRaises(Interrupted):
            self.run_import(fault="during_copy")
        failed = self.model.db.execute("SELECT * FROM assets WHERE status='failed'").fetchone()
        old = self.model.objects / (failed["id"] + ".blob")
        old_bytes = old.read_bytes()
        self.assertEqual(self.model.ready(), [])
        self.model.close()
        self.model = WorkspaceOracle(self.parent / "private", self.legacy)
        identity = self.run_import()
        replacement = self.model.db.execute("SELECT * FROM assets WHERE workspace=? AND import_key=?", (identity, failed["import_key"])).fetchone()
        self.assertLess(len(old_bytes), json.loads(failed["descriptor"])["size"])
        self.assertNotEqual(replacement["id"], failed["id"])
        self.assertIsNotNone(self.model.db.execute("SELECT 1 FROM orphans WHERE id=?", (failed["id"],)).fetchone())
        self.assertEqual(old.read_bytes(), old_bytes)
        self.assertEqual(len(self.model.ready()), 1)

    def test_before_and_after_publication_interruptions_resume_without_duplicate_workspace(self):
        for point in ("after_workspace_reserve", "after_reserve", "after_copy", "before_publish", "after_publish"):
            with self.subTest(point=point):
                self.model.close()
                self.model = WorkspaceOracle(self.parent / ("case-" + point), self.legacy)
                with self.assertRaises(Interrupted):
                    self.run_import(fault=point)
                identity = self.run_import()
                again = self.run_import()
                self.assertEqual(identity, again)
                self.assertEqual(len(self.model.ready()), 1)
                self.assertEqual(self.model.db.execute("SELECT count(*) FROM history").fetchone()[0], 2)

    def test_existing_user_library_and_old_uri_are_never_touched(self):
        live = self.parent / "existing-user.sqlite"
        conn = sqlite3.connect(live)
        conn.executescript("CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE documents(id TEXT PRIMARY KEY,body TEXT); CREATE TABLE operations(actor TEXT,sequence INTEGER); CREATE TABLE device_refs(id TEXT,locator TEXT);")
        conn.execute("INSERT INTO meta VALUES('device','current-device')")
        conn.execute("INSERT INTO documents VALUES('existing','原有资料')")
        conn.execute("INSERT INTO operations VALUES('current-device',17)")
        conn.execute("INSERT INTO device_refs VALUES('private-existing','untouched-current-handle')")
        conn.commit(); before_dump = tuple(conn.iterdump()); conn.close()
        before_bytes = live.read_bytes()
        self.package = fixture(self.parent, old_uri="file://" + str(live) + " content://old/Photos/1")
        identity = self.run_import()
        conn = sqlite3.connect(live)
        self.assertEqual(tuple(conn.iterdump()), before_dump)
        conn.close()
        self.assertEqual(live.read_bytes(), before_bytes)
        self.assertNotEqual(self.model.ready()[0]["owner"], "current-device")
        self.assertFalse(self.model.flags(identity)["normalImportAllowed"])
        self.assertEqual(self.legacy.calls, [])

    def test_confirmation_cross_family_and_changed_source_fail_before_publication(self):
        for args in (dict(expected_family="other", confirmed=True, fingerprint=self.package.fingerprint),
                     dict(expected_family=self.package.family, confirmed=False, fingerprint=self.package.fingerprint),
                     dict(expected_family=self.package.family, confirmed=True, fingerprint="0" * 64)):
            with self.assertRaises(OracleError):
                self.model.import_package(self.package, **args)
        original = next(e for e in self.package.entries if e.kind == "records")
        with original.source.open("ab") as out:
            out.write(b"unexpected-growth")
        with self.assertRaisesRegex(OracleError, "actual_source_size"):
            self.run_import()
        self.assertEqual(self.model.ready(), [])
        self.assertEqual(self.model.db.execute("SELECT count(*) FROM workspaces").fetchone()[0], 0)

    def test_sources_outside_verified_stage_and_symlinks_are_refused(self):
        original = self.package.entries[0]
        outside = self.parent / "outside-source"
        outside.write_bytes(original.source.read_bytes())
        forged = replace(self.package, entries=(replace(original, source=outside), *self.package.entries[1:]))
        with self.assertRaisesRegex(OracleError, "source_outside_verified_stage"):
            self.model.preview(forged, self.package.family)
        linked = self.package.stage / "linked.blob"
        linked.symlink_to(outside)
        forged = replace(self.package, entries=(replace(original, source=linked), *self.package.entries[1:]))
        with self.assertRaisesRegex(OracleError, "unsafe_source"):
            self.model.preview(forged, self.package.family)
        self.assertEqual(self.model.ready(), [])

    def test_preexisting_target_is_not_overwritten_even_when_random_collides(self):
        occupied_id = "o_" + "0" * 32
        occupied = self.model.objects / (occupied_id + ".blob")
        occupied.write_bytes(b"existing-owner-bytes")
        self.model._asset_ids = lambda: occupied_id
        with self.assertRaisesRegex(OracleError, "id_collision"):
            self.run_import()
        self.assertEqual(occupied.read_bytes(), b"existing-owner-bytes")
        self.assertEqual(self.model.ready(), [])
        self.model._asset_ids = lambda: "o_" + secrets.token_hex(16)
        self.run_import()
        self.assertEqual(occupied.read_bytes(), b"existing-owner-bytes")

    def test_corrupted_or_symlinked_owned_bytes_are_not_repacked_as_verified(self):
        identity = self.run_import()
        row = self.model.db.execute("SELECT * FROM assets WHERE workspace=? LIMIT 1", (identity,)).fetchone()
        path = self.model.objects / (row["id"] + ".blob")
        path.write_bytes(b"corrupted")
        with self.assertRaisesRegex(OracleError, "owned_integrity"):
            self.model.repack(identity)
        path.unlink()
        victim = self.parent / "not-an-owned-file"
        victim.write_bytes(b"must-not-read")
        path.symlink_to(victim)
        with self.assertRaisesRegex(OracleError, "owned_integrity"):
            self.model.read(identity, row["id"])
        self.assertEqual(victim.read_bytes(), b"must-not-read")


class DartSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.recovery = (ROOT / "lib/local/backup/recovery_workspace.dart").read_text()
        cls.owned = (ROOT / "lib/local/media/owned_media_store.dart").read_text()

    def test_fixed_readonly_flags_and_restricted_rebackup(self):
        for flag in ("normalImportAllowed", "peerExportable", "fullDeviceComplete", "recordsApplied"):
            self.assertRegex(self.recovery, rf"bool\s+get\s+{flag}\s*=>\s*false")
        self.assertRegex(self.owned, r"bool\s+get\s+restricted\s*=>\s*true")
        self.assertIn("BackupPrivacy get privacy=>BackupPrivacy.restricted", self.owned)
        self.assertIn("omittedScopes:", self.recovery)
        self.assertIn("外层公开", self.recovery)
        self.assertIn("成员授权与撤权证明未重建", self.recovery)

    def test_no_live_store_route_or_sync_import_or_invocation(self):
        for source in (self.recovery, self.owned):
            imports = re.findall(r"^\s*import\s+['\"]([^'\"]+)['\"]", source, re.M)
            for name in imports:
                self.assertNotRegex(name, r"(?:^|/)(?:local_store|local_api|local_backend|local_runtime)\.dart$")
                self.assertNotIn("/sync/", name)
                self.assertNotIn("/plugins/", name)
            self.assertNotRegex(source, r"\b(?:LocalStore|LocalApiBackend|PeerRegistry|LocalSyncCoordinator|[A-Za-z]+Routes)\s*(?:\(|\.)")
            self.assertNotRegex(source, r"\bNativeMedia\s*\(")
            self.assertNotRegex(source, r"\.(?:prepareOriginal|resolve|openOriginal|pick)\s*\(")
            self.assertNotIn("historicalExport", source)
        # 只允许复用静态JPEG校验，不构造带LocalStore的Repository。
        self.assertNotRegex(self.owned, r"\bLocalMediaRepository\s*\(")
        self.assertIn("LocalMediaRepository.validateThumbnail", self.owned)
        self.assertIn("required RecoveryFieldValidator validateFields", self.recovery)

    def test_fixed_private_roots_fresh_ids_and_exclusive_file_creation(self):
        self.assertIn("crypto.privateDirectory('recovery-library-v1')", self.recovery)
        self.assertIn("privateDirectoryName='owned-media-v1'", self.owned)
        self.assertIn("'owner':const Uuid().v4()", self.recovery)
        self.assertIn("await target.create(exclusive:true)", self.owned)
        self.assertLess(self.owned.index("await target.create(exclusive:true)"), self.owned.index("await target.open(mode:FileMode.writeOnly)"))
        self.assertIn("owned_orphans", self.owned)
        self.assertIn("followLinks:false", self.owned)
        self.assertIn("await _verify(asset)", self.owned)

    def test_publication_and_retry_source_contract(self):
        publish = self.recovery.split("await _db.transaction((tx)async{", 1)[1].split("return get(id)", 1)[0]
        self.assertIn("tx.insert('history'", publish)
        self.assertIn("tx.update('workspaces',{'state':'ready'}", publish)
        self.assertIn("state=?", self.recovery)
        self.assertIn("whereArgs:['ready']", self.recovery)
        self.assertIn("where:'fingerprint=?'", self.recovery)
        self.assertIn("recovery_confirmation_changed", self.recovery)
        self.assertIn("recovery_confirmation_required", self.recovery)

    def test_record_use_time_size_bound_and_sha_are_checked(self):
        self.assertNotIn("source.file.readAsBytes()", self.recovery)
        self.assertIn("source.file.openRead()", self.recovery)
        self.assertRegex(self.recovery, r"(?:count|length|size|received)\s*>\s*entry\.size")
        self.assertIn("hashing.sha256.convert(raw).toString()!=entry.sha256", self.recovery)
        self.assertIn("recovery_records_integrity", self.recovery)
        self.assertIn("owned_integrity", self.owned)
        self.assertIn("p.dirname(resolved)!=parent", self.owned)
        self.assertIn("file.parent.resolveSymbolicLinks()!=parent", self.owned)


if __name__ == "__main__":
    print("独立Python SQLite/文件oracle + Dart源码契约；未执行Dart/Flutter/SDK/原生代码。", flush=True)
    unittest.main(verbosity=2)
