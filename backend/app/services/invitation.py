"""Invitation business logic — code generation, normalization, accept flow.

The invitation `code` is stored as an 8-char slug (PK). For display we wrap
it as `WO-XXXX-XXXX`. The URL form drops the prefix and hyphens. All three
forms are accepted by the API — `normalize_code` makes them interchangeable.
"""

import secrets
from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_admin, require_membership
from app.models.family import Family
from app.models.invitation import Invitation
from app.models.membership import INVITABLE_ROLES, Membership
from app.models.user import User
from app.services import notification as notification_service

# Char set avoids ambiguous glyphs (no I/L/O/0/1).
_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_SLUG_LEN = 8
_DEFAULT_TTL_SECONDS = 7 * 24 * 3600  # 7 days
_MAX_TTL_SECONDS = 30 * 24 * 3600  # cap at 30 days
_VALID_CHANNELS: tuple[str, ...] = ("qr", "link", "code")


def _generate_slug() -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(_SLUG_LEN))


def format_code_for_display(slug: str) -> str:
    """`W4M9P2KX` → `WO-W4M9-P2KX`."""
    return f"WO-{slug[:4]}-{slug[4:]}"


def normalize_code(raw: str) -> str:
    """Accept any of the three forms and return the canonical slug."""
    cleaned = raw.upper().replace("-", "").replace(" ", "")
    if cleaned.startswith("WO"):
        cleaned = cleaned[2:]
    if len(cleaned) != _SLUG_LEN or any(c not in _ALPHABET for c in cleaned):
        raise AppError(
            ErrorCode.INVITATION_INVALID,
            "邀请码格式错误",
            status_code=400,
        )
    return cleaned


def build_link(slug: str) -> str:
    return f"{settings.web_base_url}/join/{slug}"


def build_qr_payload(slug: str) -> str:
    return f"{settings.deep_link_scheme}://join?c={slug}"


async def create_invitation(
    session: AsyncSession,
    inviter: User,
    family_id: UUID,
    role: str,
    ttl_seconds: int,
    channel: str,
) -> Invitation:
    """Generate an invitation. Inviter must be Admin or Owner of the family."""
    # Permission check first — never reveal validation errors to non-members.
    membership = await require_membership(session, inviter.id, family_id)
    require_admin(membership)

    if role not in INVITABLE_ROLES:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"非法 role：{role}",
            status_code=422,
            details={"allowed": list(INVITABLE_ROLES)},
        )
    if channel not in _VALID_CHANNELS:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"非法 channel：{channel}",
            status_code=422,
            details={"allowed": list(_VALID_CHANNELS)},
        )
    if ttl_seconds <= 0 or ttl_seconds > _MAX_TTL_SECONDS:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"ttl_seconds 必须在 1 ~ {_MAX_TTL_SECONDS} 之间",
            status_code=422,
        )

    # Generate a unique slug (retry on the astronomically rare collision).
    slug = ""
    for _ in range(5):
        candidate = _generate_slug()
        if await session.get(Invitation, candidate) is None:
            slug = candidate
            break
    if not slug:
        raise AppError(
            ErrorCode.INTERNAL,
            "无法生成邀请码（连续 5 次冲突）",
            status_code=500,
        )

    now = datetime.now(UTC)
    invitation = Invitation(
        code=slug,
        family_id=family_id,
        inviter_id=inviter.id,
        role=role,
        channel=channel,
        expires_at=now + timedelta(seconds=ttl_seconds),
        created_at=now,
    )
    session.add(invitation)
    await session.commit()
    await session.refresh(invitation)
    return invitation


async def get_usable_invitation(
    session: AsyncSession,
    raw_code: str,
) -> Invitation:
    """Look up + validate: exists, not expired, not used. Else raise."""
    slug = normalize_code(raw_code)
    invitation = await session.get(Invitation, slug)
    if invitation is None:
        raise AppError(
            ErrorCode.INVITATION_INVALID,
            "邀请码不存在",
            status_code=400,
        )
    if invitation.used_at is not None:
        raise AppError(
            ErrorCode.INVITATION_INVALID,
            "邀请码已被使用",
            status_code=400,
        )
    if invitation.expires_at <= datetime.now(UTC):
        raise AppError(
            ErrorCode.INVITATION_EXPIRED,
            "邀请码已过期",
            status_code=410,
        )
    return invitation


async def accept_invitation(
    session: AsyncSession,
    invitation: Invitation,
    user: User,
) -> tuple[Family, Membership]:
    """Apply an invitation: create membership, mark invitation used.

    Atomic — if any step fails, nothing is persisted.
    """
    family = await session.get(Family, invitation.family_id)
    if family is None:
        raise AppError(
            ErrorCode.FAMILY_NOT_FOUND,
            "邀请所属的家庭已不存在",
            status_code=404,
        )

    # Already a member?
    existing_stmt = select(Membership).where(
        Membership.user_id == user.id,
        Membership.family_id == family.id,
    )
    if (await session.execute(existing_stmt)).scalar_one_or_none() is not None:
        raise AppError(
            ErrorCode.ALREADY_MEMBER,
            "你已经是该家庭成员",
            status_code=409,
        )

    membership = Membership(
        user_id=user.id,
        family_id=family.id,
        role=invitation.role,
        display_name=user.display_name,
        avatar_emoji=user.avatar_emoji,
    )
    session.add(membership)

    invitation.used_at = datetime.now(UTC)
    invitation.used_by_user_id = user.id
    session.add(invitation)

    # Auto-switch into the new family for users who don't have one yet.
    if user.current_family_id is None:
        user.current_family_id = family.id
        session.add(user)

    # Notify every other active member. The notifier just stages rows on
    # this session; the commit below makes it atomic with the join itself —
    # either everyone sees the new member and gets pinged, or no change at all.
    await notification_service.notify_member_joined(session, family=family, joining_user=user)

    await session.commit()
    await session.refresh(membership)
    await session.refresh(family)
    return family, membership
