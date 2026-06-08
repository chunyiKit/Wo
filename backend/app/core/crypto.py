"""Symmetric encryption for secrets stored at rest (AI API keys).

Uses Fernet (AES-128-CBC + HMAC) keyed by `settings.ai_secret_key`. The key is a
url-safe base64 32-byte value; generate one with:

    python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"

`encrypt_secret`/`decrypt_secret` are the only surface callers need. When the key
is unset, `encrypt_secret` raises `CryptoNotConfiguredError` so the API can return
a clear "server not configured" message rather than persisting plaintext.
"""

from __future__ import annotations

from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken

from app.core.config import settings


class CryptoError(Exception):
    """Encryption/decryption failed (bad key, corrupted token, key unset)."""


class CryptoNotConfiguredError(CryptoError):
    """`ai_secret_key` is unset — refuse to store a secret as plaintext."""


@lru_cache(maxsize=1)
def _fernet() -> Fernet:
    key = settings.ai_secret_key
    if not key:
        raise CryptoNotConfiguredError(
            "服务端未配置密钥（AI_SECRET_KEY），无法安全保存 API Key"
        )
    try:
        return Fernet(key.encode("utf-8"))
    except (ValueError, TypeError) as exc:  # malformed key
        raise CryptoError(f"AI_SECRET_KEY 格式非法: {exc}") from exc


def encrypt_secret(plaintext: str) -> str:
    """Encrypt a secret to a url-safe token. Raises `CryptoNotConfiguredError`
    when no key is set."""
    return _fernet().encrypt(plaintext.encode("utf-8")).decode("ascii")


def decrypt_secret(token: str) -> str:
    """Decrypt a token produced by `encrypt_secret`. Raises `CryptoError` on a
    corrupted token or wrong key."""
    try:
        return _fernet().decrypt(token.encode("ascii")).decode("utf-8")
    except InvalidToken as exc:
        raise CryptoError("密文损坏或密钥不匹配，无法解密") from exc


def reset_cache() -> None:
    """Drop the cached Fernet (tests that swap `ai_secret_key` at runtime)."""
    _fernet.cache_clear()


__all__ = [
    "CryptoError",
    "CryptoNotConfiguredError",
    "encrypt_secret",
    "decrypt_secret",
    "reset_cache",
]
