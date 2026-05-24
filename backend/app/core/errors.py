"""Application errors and global exception handlers.

Raise `AppError` anywhere in routes/services to short-circuit with a structured
error response. The registered handlers also catch FastAPI's `HTTPException`
and `RequestValidationError`, mapping them into the same envelope so the client
sees a consistent shape regardless of where the failure originated.
"""

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


# Error codes — keep this list in sync with docs/backend-contract.md §4.6.
class ErrorCode:
    UNAUTHORIZED = "UNAUTHORIZED"
    FORBIDDEN = "FORBIDDEN"
    NOT_FOUND = "NOT_FOUND"
    VALIDATION_ERROR = "VALIDATION_ERROR"
    FAMILY_NOT_FOUND = "FAMILY_NOT_FOUND"
    INVITATION_EXPIRED = "INVITATION_EXPIRED"
    INVITATION_INVALID = "INVITATION_INVALID"
    PLUGIN_ALREADY_INSTALLED = "PLUGIN_ALREADY_INSTALLED"
    LAYOUT_CONFLICT = "LAYOUT_CONFLICT"
    ALREADY_MEMBER = "ALREADY_MEMBER"
    FILE_TOO_LARGE = "FILE_TOO_LARGE"
    INVALID_IMAGE = "INVALID_IMAGE"
    RATE_LIMIT = "RATE_LIMIT"
    INTERNAL = "INTERNAL"


class AppError(Exception):
    """Domain error with a structured payload.

    Example:
        raise AppError(ErrorCode.FAMILY_NOT_FOUND, "家庭不存在或已解散",
                       status_code=404, details={"family_id": fid})
    """

    def __init__(
        self,
        code: str,
        message: str,
        status_code: int = status.HTTP_400_BAD_REQUEST,
        details: dict | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.details = details


# Map HTTP status codes from raw HTTPException → our error code catalog.
_HTTP_STATUS_TO_CODE: dict[int, str] = {
    status.HTTP_401_UNAUTHORIZED: ErrorCode.UNAUTHORIZED,
    status.HTTP_403_FORBIDDEN: ErrorCode.FORBIDDEN,
    status.HTTP_404_NOT_FOUND: ErrorCode.NOT_FOUND,
    status.HTTP_413_CONTENT_TOO_LARGE: ErrorCode.FILE_TOO_LARGE,
    status.HTTP_429_TOO_MANY_REQUESTS: ErrorCode.RATE_LIMIT,
    status.HTTP_500_INTERNAL_SERVER_ERROR: ErrorCode.INTERNAL,
}


def _error_body(code: str, message: str, details: dict | None = None) -> dict:
    """Shape a JSON body that matches `ApiResponse` with `success=False`."""
    return {
        "success": False,
        "data": None,
        "error": {"code": code, "message": message, "details": details},
        "meta": None,
    }


def register_exception_handlers(app: FastAPI) -> None:
    """Attach global handlers so all errors come out wrapped in the envelope."""

    @app.exception_handler(AppError)
    async def _app_error(_: Request, exc: AppError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content=_error_body(exc.code, exc.message, exc.details),
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_exc(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _HTTP_STATUS_TO_CODE.get(exc.status_code, "ERROR")
        return JSONResponse(
            status_code=exc.status_code,
            content=_error_body(code, str(exc.detail)),
        )

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            content=_error_body(
                ErrorCode.VALIDATION_ERROR,
                "请求参数错误",
                {"errors": exc.errors()},
            ),
        )
