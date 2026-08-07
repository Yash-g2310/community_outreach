"""Password and JWT helpers used by both HTTP and WebSocket authentication."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from datetime import timezone, datetime, timedelta
from typing import Any
from uuid import UUID

from fastapi import HTTPException, status

from app.core.config import get_settings

_PBKDF2_ITERATIONS = 600_000


def hash_password(password: str) -> str:
    """Create a salted PBKDF2-SHA256 password hash; never retain raw passwords."""

    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _PBKDF2_ITERATIONS)
    return "pbkdf2_sha256${}${}${}".format(
        _PBKDF2_ITERATIONS,
        _b64url(salt),
        _b64url(digest),
    )


def verify_password(password: str, encoded: str) -> bool:
    """Compare a candidate password without timing leaks."""

    try:
        scheme, iterations, salt, expected = encoded.split("$", 3)
        if scheme != "pbkdf2_sha256":
            return False
        actual = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), _b64url_decode(salt), int(iterations)
        )
        return hmac.compare_digest(actual, _b64url_decode(expected))
    except (TypeError, ValueError):
        return False


def new_refresh_token() -> str:
    """Return an opaque refresh credential that is safe to hash before storage."""

    return secrets.token_urlsafe(48)


def hash_refresh_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create_access_token(*, user_id: UUID, session_id: UUID, roles: list[str]) -> str:
    """Create a short-lived, signed access token bound to one refresh session."""

    settings = get_settings()
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "sid": str(session_id),
        "roles": roles,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=settings.access_token_expire_minutes)).timestamp()),
        "typ": "access",
    }
    return _encode_jwt(payload, settings.require_jwt_secret())


def decode_access_token(token: str) -> dict[str, Any]:
    """Verify an access token's signature, type, and expiry."""

    try:
        header_b64, payload_b64, signature_b64 = token.split(".")
        signing_input = f"{header_b64}.{payload_b64}".encode()
        expected = hmac.new(
            get_settings().require_jwt_secret().encode(), signing_input, hashlib.sha256
        ).digest()
        if not hmac.compare_digest(expected, _b64url_decode(signature_b64)):
            raise ValueError("Invalid signature")
        header = json.loads(_b64url_decode(header_b64))
        payload = json.loads(_b64url_decode(payload_b64))
        if header != {"alg": "HS256", "typ": "JWT"} or payload.get("typ") != "access":
            raise ValueError("Invalid token type")
        if not isinstance(payload.get("exp"), int) or payload["exp"] <= datetime.now(timezone.utc).timestamp():
            raise ValueError("Expired token")
        UUID(payload["sub"])
        UUID(payload["sid"])
        if not isinstance(payload.get("roles"), list):
            raise ValueError("Invalid roles")
        return payload
    except (KeyError, TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired access token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from None


def _encode_jwt(payload: dict[str, Any], secret: str) -> str:
    header = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    signature = hmac.new(secret.encode(), f"{header}.{body}".encode(), hashlib.sha256).digest()
    return f"{header}.{body}.{_b64url(signature)}"


def _b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def _b64url_decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
