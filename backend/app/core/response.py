"""Standard API response envelope.

Every successful response is wrapped in `{success: true, data, error: null, meta}`.
Every error response is wrapped in `{success: false, data: null, error, meta: null}`.
This matches the contract in docs/backend-contract.md §4.2.
"""

from pydantic import BaseModel


class ApiError(BaseModel):
    """Error payload inside the response envelope."""

    code: str
    message: str
    details: dict | None = None


class Meta(BaseModel):
    """Pagination metadata. Present only on paginated list responses."""

    total: int | None = None
    cursor: str | None = None
    limit: int | None = None


class ApiResponse[T](BaseModel):
    """Unified response envelope. Use `response_model=ApiResponse[SomeSchema]` on routes."""

    success: bool
    data: T | None = None
    error: ApiError | None = None
    meta: Meta | None = None


def ok[T](data: T | None = None, meta: Meta | None = None) -> ApiResponse[T]:
    """Build a success envelope. Use inside route handlers: `return ok(user)`."""
    return ApiResponse(success=True, data=data, meta=meta)
