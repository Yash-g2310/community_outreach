"""Authentication endpoints for the FastAPI service."""

from __future__ import annotations

from datetime import timezone, datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from fastapi_app.core.config import get_settings
from fastapi_app.core.security import (
    create_access_token,
    hash_password,
    hash_refresh_token,
    new_refresh_token,
    verify_password,
)
from fastapi_app.db.models.driver import DriverProfile
from fastapi_app.db.models.identity import AuthSession, User, UserDevice, UserRole
from fastapi_app.db.session import get_db_session

router = APIRouter(prefix="/auth", tags=["authentication"])


class RegisterRequest(BaseModel):
    """Create a rider or driver. Old Flutter field names remain accepted during migration."""

    model_config = ConfigDict(populate_by_name=True, str_strip_whitespace=True)
    phone: str = Field(validation_alias="phone_number", min_length=6, max_length=20)
    email: str | None = Field(default=None, max_length=320)
    first_name: str | None = Field(default=None, min_length=1, max_length=100)
    username: str | None = Field(default=None, min_length=1, max_length=100)
    last_name: str | None = Field(default=None, max_length=100)
    password: str = Field(min_length=8, max_length=128)
    role: str = "rider"
    vehicle_license_number: str | None = Field(default=None, validation_alias="vehicle_number", max_length=50)
    device_identifier: str | None = Field(default=None, max_length=255)
    platform: str | None = None
    push_token: str | None = None

    @model_validator(mode="after")
    def validate_role_and_name(self) -> "RegisterRequest":
        if self.role == "user":  # Compatibility with the old Flutter client.
            self.role = "rider"
        if self.role not in {"rider", "driver"}:
            raise ValueError("role must be rider or driver")
        if not self.first_name and not self.username:
            raise ValueError("first_name is required")
        if self.role == "driver" and not self.vehicle_license_number:
            raise ValueError("vehicle_license_number is required for drivers")
        if (self.device_identifier is None) != (self.platform is None):
            raise ValueError("device_identifier and platform must be sent together")
        if self.platform and self.platform not in {"android", "ios", "web"}:
            raise ValueError("platform must be android, ios, or web")
        return self

    @field_validator("email")
    @classmethod
    def validate_email(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.lower()
        if "@" not in value or value.startswith("@") or value.endswith("@"):
            raise ValueError("email must be a valid email address")
        return value


class LoginRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True, str_strip_whitespace=True)
    identifier: str = Field(validation_alias="username", min_length=1, max_length=320)
    password: str = Field(min_length=1, max_length=128)
    device_identifier: str | None = Field(default=None, max_length=255)
    platform: str | None = None
    push_token: str | None = None

    @model_validator(mode="after")
    def validate_device(self) -> "LoginRequest":
        if (self.device_identifier is None) != (self.platform is None):
            raise ValueError("device_identifier and platform must be sent together")
        if self.platform and self.platform not in {"android", "ios", "web"}:
            raise ValueError("platform must be android, ios, or web")
        return self


class RefreshRequest(BaseModel):
    refresh: str = Field(min_length=32, max_length=512)


def _user_response(user: User, roles: list[str]) -> dict[str, object]:
    primary_role = "driver" if "driver" in roles else "rider"
    return {
        "id": str(user.id),
        "phone": user.phone,
        "email": user.email,
        "first_name": user.first_name,
        "last_name": user.last_name,
        "username": user.first_name,  # transitional field consumed by the current Flutter UI
        "role": primary_role,
        "roles": roles,
    }


async def _upsert_device(session: AsyncSession, user_id: UUID, request: RegisterRequest | LoginRequest) -> UserDevice | None:
    if not request.device_identifier or not request.platform:
        return None
    device = await session.scalar(
        select(UserDevice).where(
            UserDevice.user_id == user_id,
            UserDevice.device_identifier == request.device_identifier,
        )
    )
    if device is None:
        device = UserDevice(user_id=user_id, device_identifier=request.device_identifier, platform=request.platform)
        session.add(device)
    device.push_token = request.push_token
    device.is_active = True
    device.last_seen_at = datetime.now(timezone.utc)
    return device


async def _issue_tokens(session: AsyncSession, user: User, roles: list[str], device: UserDevice | None) -> dict[str, str]:
    refresh = new_refresh_token()
    settings = get_settings()
    auth_session = AuthSession(
        user_id=user.id,
        device_id=device.id if device else None,
        refresh_token_hash=hash_refresh_token(refresh),
        expires_at=datetime.now(timezone.utc) + timedelta(days=settings.refresh_token_expire_days),
    )
    session.add(auth_session)
    await session.flush()
    return {"access": create_access_token(user_id=user.id, session_id=auth_session.id, roles=roles), "refresh": refresh}


@router.post("/register", status_code=status.HTTP_201_CREATED)
async def register(payload: RegisterRequest, session: AsyncSession = Depends(get_db_session)) -> dict[str, object]:
    """Register a local account and immediately create a signed-in session."""

    uniqueness_checks = [User.phone == payload.phone]
    if payload.email is not None:
        uniqueness_checks.append(User.email == payload.email)
    existing = await session.scalar(select(User.id).where(or_(*uniqueness_checks)))
    if existing is not None:
        raise HTTPException(status_code=409, detail="A user with that phone number or email already exists")

    user = User(
        phone=payload.phone,
        email=str(payload.email) if payload.email else None,
        first_name=payload.first_name or payload.username or "",
        last_name=payload.last_name,
        password_hash=hash_password(payload.password),
        status="active",
        phone_verified_at=None,
    )
    session.add(user)
    await session.flush()
    session.add(UserRole(user_id=user.id, role=payload.role))
    if payload.role == "driver":
        session.add(DriverProfile(user_id=user.id, vehicle_license_number=payload.vehicle_license_number or ""))
    device = await _upsert_device(session, user.id, payload)
    tokens = await _issue_tokens(session, user, [payload.role], device)
    await session.commit()
    return {"message": "User registered successfully", "user": _user_response(user, [payload.role]), "tokens": tokens}


@router.post("/login")
async def login(payload: LoginRequest, session: AsyncSession = Depends(get_db_session)) -> dict[str, object]:
    """Log in with a registered phone number or email."""

    user = await session.scalar(select(User).where(or_(User.phone == payload.identifier, User.email == payload.identifier)))
    if user is None or user.status != "active" or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid phone/email or password")
    roles = list(await session.scalars(select(UserRole.role).where(UserRole.user_id == user.id)))
    device = await _upsert_device(session, user.id, payload)
    tokens = await _issue_tokens(session, user, roles, device)
    await session.commit()
    return {"message": "Login successful", "user": _user_response(user, roles), "tokens": tokens}


@router.post("/refresh")
async def refresh(payload: RefreshRequest, session: AsyncSession = Depends(get_db_session)) -> dict[str, object]:
    """Rotate a valid refresh token and return a new access/refresh pair."""

    auth_session = await session.scalar(
        select(AuthSession).where(AuthSession.refresh_token_hash == hash_refresh_token(payload.refresh))
    )
    now = datetime.now(timezone.utc)
    if auth_session is None or auth_session.revoked_at is not None or auth_session.expires_at <= now:
        raise HTTPException(status_code=401, detail="Invalid or expired refresh token")
    auth_session.revoked_at = now
    user = await session.get(User, auth_session.user_id)
    if user is None or user.status != "active":
        raise HTTPException(status_code=401, detail="User account is unavailable")
    roles = list(await session.scalars(select(UserRole.role).where(UserRole.user_id == user.id)))
    refresh_token = new_refresh_token()
    replacement = AuthSession(
        user_id=user.id,
        device_id=auth_session.device_id,
        refresh_token_hash=hash_refresh_token(refresh_token),
        expires_at=now + timedelta(days=get_settings().refresh_token_expire_days),
    )
    session.add(replacement)
    await session.flush()
    await session.commit()
    return {"access": create_access_token(user_id=user.id, session_id=replacement.id, roles=roles), "refresh": refresh_token}


@router.get("/me")
async def current_user(request: Request, session: AsyncSession = Depends(get_db_session)) -> dict[str, object]:
    """Return the account associated with the current access token."""

    from fastapi_app.api.routes.websocket import get_authenticated_claims

    claims = await get_authenticated_claims(request, session)
    user = await session.get(User, UUID(str(claims["sub"])))
    return {"user": _user_response(user, list(claims["roles"]))}  # type: ignore[arg-type]


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(request: Request, session: AsyncSession = Depends(get_db_session)) -> None:
    """Revoke the current refresh session; its access token remains valid only briefly."""

    from fastapi_app.api.routes.websocket import get_authenticated_claims

    claims = await get_authenticated_claims(request, session)
    auth_session = await session.get(AuthSession, UUID(claims["sid"]))
    if auth_session is not None:
        auth_session.revoked_at = datetime.now(timezone.utc)
        await session.commit()
