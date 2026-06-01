"""In-app update endpoints — version check, APK download, and publishing.

There is exactly one published release at a time (see `services.app_release`).

- `GET  /app/version`  — latest release metadata (public; null when none).
- `GET  /app/download` — fetch the published APK (public). Streams locally in
                          dev/tests; 302-redirects to COS in prod.
- `POST /app/release`  — publish/replace the release, guarded by a shared token.

`version_code` is the Android versionCode (the `+N` in pubspec `version`), a
monotonically increasing int. The client compares it against its own build
number to decide whether an update is available.

In **COS mode**, `/version`'s `download_url` is the full COS public URL so the
app downloads directly from `<bucket>.cos.<region>.myqcloud.com`, offloading
bandwidth from this CVM. `/app/download` is kept as a 302-redirect tombstone
for any old client still hitting the relative path.
"""

from typing import Annotated

from fastapi import APIRouter, File, Form, Header, UploadFile
from fastapi.responses import FileResponse, RedirectResponse
from pydantic import BaseModel

from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.response import ApiResponse, ok
from app.services import app_release as release_service

router = APIRouter(prefix="/app", tags=["app-update"])

_CHUNK = 1024 * 1024


class ReleaseRead(BaseModel):
    """Latest release metadata returned to the client."""

    version_name: str
    version_code: int
    notes: str
    size: int
    sha256: str
    published_at: str
    # Path (host-relative, includes /api/v1) the client prepends baseUrl to.
    download_url: str


def _resolve_download_url(m: release_service.ReleaseManifest) -> str:
    """Pick the URL clients should download from for this release.

    COS-mode releases hand back the full COS public URL so the app bypasses
    this server entirely. Local-mode releases keep returning the relative
    `/api/v1/app/download` path (the app prepends its `baseUrl`), matching
    pre-COS behaviour for dev/tests and any legacy on-disk release.
    """
    if m.cos_url:
        return m.cos_url
    return f"/api/v1/app/download?v={m.version_code}"


def _to_read(m: release_service.ReleaseManifest) -> ReleaseRead:
    return ReleaseRead(
        version_name=m.version_name,
        version_code=m.version_code,
        notes=m.notes,
        size=m.size,
        sha256=m.sha256,
        published_at=m.published_at,
        download_url=_resolve_download_url(m),
    )


@router.get("/version", response_model=ApiResponse[ReleaseRead | None])
async def latest_version() -> ApiResponse[ReleaseRead | None]:
    """Latest published release, or null when nothing is published yet."""
    manifest = release_service.get_manifest()
    return ok(_to_read(manifest) if manifest is not None else None)


@router.get("/download", response_model=None)
async def download_apk() -> FileResponse | RedirectResponse:
    """Fetch the published APK.

    - Local-mode release: stream the on-disk APK directly (legacy path).
    - COS-mode release: 302-redirect to the COS public URL. We keep this
      endpoint instead of just removing it because already-installed old
      clients have the relative URL baked in — they need a working path until
      they upgrade past the COS cutover.

    `?v=` is just a cache-buster, ignored here.
    """
    manifest = release_service.get_manifest()
    if manifest is None:
        raise AppError(ErrorCode.NOT_FOUND, "尚无可用更新", status_code=404)
    if manifest.cos_url:
        # 302 (not 301) — we want clients to keep asking us, so future
        # republishes / config changes can move the target.
        return RedirectResponse(manifest.cos_url, status_code=302)

    path = release_service.apk_path_for_download()
    if path is None:
        raise AppError(ErrorCode.NOT_FOUND, "尚无可用更新", status_code=404)
    filename = f"wo-{manifest.version_name}.apk"
    return FileResponse(
        path,
        media_type="application/vnd.android.package-archive",
        filename=filename,
    )


@router.post("/release", response_model=ApiResponse[ReleaseRead])
async def publish_release(
    file: Annotated[UploadFile, File(...)],
    version_name: Annotated[str, Form(...)],
    version_code: Annotated[int, Form(...)],
    notes: Annotated[str, Form()] = "",
    x_release_token: Annotated[str | None, Header(alias="X-Release-Token")] = None,
) -> ApiResponse[ReleaseRead]:
    """Publish/replace the latest release. Guarded by the shared release token."""
    expected = settings.app_release_token
    if not expected:
        raise AppError(
            ErrorCode.FORBIDDEN, "发布功能未启用（未配置 token）", status_code=403
        )
    if x_release_token != expected:
        raise AppError(ErrorCode.UNAUTHORIZED, "无效的发布 token", status_code=401)
    if version_code < 1:
        raise AppError(
            ErrorCode.VALIDATION_ERROR, "version_code 必须为正整数", status_code=400
        )

    async def _stream():
        while chunk := await file.read(_CHUNK):
            yield chunk

    try:
        manifest = await release_service.publish(
            _stream(),
            version_name=version_name.strip(),
            version_code=version_code,
            notes=notes.strip(),
            max_bytes=settings.app_release_max_bytes,
        )
    except ValueError as exc:
        msg = str(exc)
        if "size limit" in msg:
            cap = settings.app_release_max_bytes // (1024 * 1024)
            raise AppError(
                ErrorCode.FILE_TOO_LARGE,
                f"APK 超过上限 {cap} MB",
                status_code=413,
            ) from exc
        raise AppError(ErrorCode.INVALID_IMAGE, "上传内容无效", status_code=400) from exc

    return ok(_to_read(manifest))
