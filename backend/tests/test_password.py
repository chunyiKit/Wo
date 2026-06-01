"""Password hashing unit tests — salting, verify, malformed input."""

from app.core.password import hash_password, verify_password


def test_hash_is_not_plaintext_and_salted() -> None:
    h1 = hash_password("hunter2")
    h2 = hash_password("hunter2")
    assert "hunter2" not in h1
    assert h1.startswith("scrypt$")
    # Random salt → same password hashes differently each time.
    assert h1 != h2


def test_verify_correct_and_wrong() -> None:
    h = hash_password("correct horse")
    assert verify_password("correct horse", h) is True
    assert verify_password("wrong", h) is False
    assert verify_password("", h) is False


def test_verify_malformed_or_empty_returns_false() -> None:
    assert verify_password("x", None) is False
    assert verify_password("x", "") is False
    assert verify_password("x", "not-a-valid-hash") is False
    assert verify_password("x", "scrypt$bad$format") is False
    assert verify_password("x", "bcrypt$1$2$3$aa$bb") is False


def test_unicode_password_roundtrips() -> None:
    h = hash_password("密码🔐abc")
    assert verify_password("密码🔐abc", h) is True
    assert verify_password("密码abc", h) is False
