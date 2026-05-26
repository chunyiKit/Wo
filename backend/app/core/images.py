"""Shared image validation.

Uploaded images (photos, recipe covers, user avatars) all run through the same
allow-list + Pillow check before they hit storage. This lives in core so both
plugins and core routes can import it without cross-plugin dependencies.
"""

from io import BytesIO

from PIL import Image, UnidentifiedImageError

from app.core.errors import AppError, ErrorCode

# Pillow understands these natively. HEIC/HEIF would need `pillow-heif` —
# defer until we actually see real-world demand.
_ALLOWED_FORMATS: dict[str, tuple[str, str]] = {
    # pillow_format → (canonical_content_type, file_ext)
    "JPEG": ("image/jpeg", "jpg"),
    "PNG": ("image/png", "png"),
    "WEBP": ("image/webp", "webp"),
    "GIF": ("image/gif", "gif"),
}


def validate_image(data: bytes) -> tuple[str, str, int, int]:
    """Verify bytes are a real, supported image and return (content_type, ext, w, h).

    Raises `AppError(INVALID_IMAGE)` on anything Pillow refuses or that isn't
    in our allow-list. We open the image twice: once with `verify()` (which
    consumes the stream), once to read dimensions.
    """
    try:
        Image.open(BytesIO(data)).verify()
    except (UnidentifiedImageError, OSError) as exc:
        raise AppError(
            ErrorCode.INVALID_IMAGE,
            "上传内容不是合法图片",
            status_code=400,
        ) from exc

    img = Image.open(BytesIO(data))
    fmt = img.format or ""
    if fmt not in _ALLOWED_FORMATS:
        raise AppError(
            ErrorCode.INVALID_IMAGE,
            f"暂不支持 {fmt or '未知'} 格式（支持 JPEG/PNG/WEBP/GIF）",
            status_code=400,
            details={"got_format": fmt, "allowed": list(_ALLOWED_FORMATS)},
        )
    content_type, ext = _ALLOWED_FORMATS[fmt]
    width, height = img.size
    return content_type, ext, width, height
