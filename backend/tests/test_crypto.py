"""Secret encryption round-trip + the unset-key guard."""

import pytest
from cryptography.fernet import Fernet

from app.core import crypto
from app.core.config import settings
from app.core.crypto import CryptoNotConfiguredError, decrypt_secret, encrypt_secret


@pytest.fixture
def _key(monkeypatch):
    monkeypatch.setattr(settings, "ai_secret_key", Fernet.generate_key().decode())
    crypto.reset_cache()
    yield
    crypto.reset_cache()


def test_encrypt_decrypt_round_trip(_key) -> None:
    token = encrypt_secret("sk-secret-1234")
    assert token != "sk-secret-1234"  # actually encrypted
    assert decrypt_secret(token) == "sk-secret-1234"


def test_ciphertext_is_non_deterministic(_key) -> None:
    # Fernet embeds an IV — same plaintext encrypts to different tokens.
    assert encrypt_secret("same") != encrypt_secret("same")
    assert decrypt_secret(encrypt_secret("same")) == "same"


def test_encrypt_without_key_raises(monkeypatch) -> None:
    monkeypatch.setattr(settings, "ai_secret_key", "")
    crypto.reset_cache()
    with pytest.raises(CryptoNotConfiguredError):
        encrypt_secret("x")
    crypto.reset_cache()
