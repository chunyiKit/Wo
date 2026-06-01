"""Password hashing — non-reversible, salted, via stdlib scrypt.

We deliberately use `hashlib.scrypt` (Python standard library) rather than
bcrypt/argon2:
- zero extra dependencies (no Rust/cffi build — safe on the server's Python),
- scrypt is a salted, memory-hard KDF, so hashes can't be reversed and are
  expensive to brute-force on GPUs.

Stored format is self-describing so parameters can change later without
breaking existing hashes:

    scrypt$<n>$<r>$<p>$<base64 salt>$<base64 hash>

`verify_password` re-derives with the stored parameters and compares in
constant time. Plaintext passwords are never stored or logged.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets

# Cost parameters. n must be a power of two; memory ≈ 128 * n * r bytes
# (here ≈ 16 MB), comfortably under scrypt's default 32 MB maxmem cap.
_N = 2**14
_R = 8
_P = 1
_SALT_BYTES = 16
_DKLEN = 32
_SCHEME = "scrypt"


def hash_password(plain: str) -> str:
    """Hash a plaintext password into the self-describing stored format."""
    salt = secrets.token_bytes(_SALT_BYTES)
    derived = hashlib.scrypt(
        plain.encode("utf-8"), salt=salt, n=_N, r=_R, p=_P, dklen=_DKLEN
    )
    return "$".join(
        [
            _SCHEME,
            str(_N),
            str(_R),
            str(_P),
            base64.b64encode(salt).decode("ascii"),
            base64.b64encode(derived).decode("ascii"),
        ]
    )


def verify_password(plain: str, stored: str | None) -> bool:
    """Constant-time check of `plain` against a stored hash. False on any
    malformed/empty stored value rather than raising."""
    if not stored:
        return False
    try:
        scheme, n_s, r_s, p_s, salt_b64, hash_b64 = stored.split("$")
        if scheme != _SCHEME:
            return False
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(hash_b64)
        derived = hashlib.scrypt(
            plain.encode("utf-8"),
            salt=salt,
            n=int(n_s),
            r=int(r_s),
            p=int(p_s),
            dklen=len(expected),
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(derived, expected)


__all__ = ["hash_password", "verify_password"]
