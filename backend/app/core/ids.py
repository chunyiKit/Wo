"""ID generation for the Wo backend.

We use UUIDv7 (RFC 9562) for all primary keys. UUIDv7 is time-sortable, so
inserts cluster nicely in B-tree indexes, and clients can generate IDs offline
without coordinating with the server (matches the contract's offline-friendly
design).
"""

from uuid import UUID

from uuid_utils.compat import uuid7

# Fixed seed user ids used in dev mode (P5 will replace auth with real JWT and
# these constants become irrelevant). They are valid UUIDv7 layouts: version
# nibble = 7, variant high bits = 10xx (so '8', '9', 'a', or 'b').
#
# Three users exist so we can test multi-user flows (invite/accept) without
# real auth — pick the actor via the `X-User-Id` dev header.
SEED_USER_ID = UUID("019000a0-1100-7000-8000-000000000001")  # 老陈   — owner-typical
SEED_USER_ID_2 = UUID("019000a0-1100-7000-8000-000000000002")  # 小林   — spouse-typical
SEED_USER_ID_3 = UUID("019000a0-1100-7000-8000-000000000003")  # 小宝   — child-typical


def new_uuid7() -> UUID:
    """Generate a fresh UUIDv7. Use this as `default_factory` on SQLModel id columns."""
    return uuid7()
