"""Backend-issued tokens, hashing helpers and the authenticated-user dependency."""
from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import jwt
from fastapi import Depends, Header, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import get_settings
from .db import get_db
from .errors import APIError
from .models import DeviceSession, User


def now() -> datetime:
    return datetime.now(UTC)


def sha256_hex(value: str | bytes) -> str:
    if isinstance(value, str):
        value = value.encode()
    return hashlib.sha256(value).hexdigest()


def random_token(nbytes: int = 48) -> str:
    return secrets.token_urlsafe(nbytes)


def _encode(claims: dict) -> str:
    s = get_settings()
    return jwt.encode(claims, s.effective_jwt_secret(), algorithm="HS256")


def _decode(token: str, typ: str) -> dict:
    s = get_settings()
    try:
        claims = jwt.decode(
            token,
            s.effective_jwt_secret(),
            algorithms=["HS256"],
            issuer=s.jwt_issuer,
            audience="fils-app",
            options={"require": ["exp", "iat", "sub", "typ", "iss", "aud"]},
        )
    except jwt.ExpiredSignatureError as e:
        raise APIError(401, "token_expired", "Token expired") from e
    except jwt.PyJWTError as e:
        raise APIError(401, "invalid_token", "Invalid token") from e
    if claims.get("typ") != typ:
        raise APIError(401, "invalid_token", "Wrong token type")
    return claims


def issue_access_token(user_id: uuid.UUID, session_id: uuid.UUID) -> tuple[str, datetime]:
    s = get_settings()
    iat = now()
    exp = iat + timedelta(seconds=s.access_ttl_seconds)
    tok = _encode(
        {
            "sub": str(user_id),
            "sid": str(session_id),
            "typ": "access",
            "iat": int(iat.timestamp()),
            "exp": int(exp.timestamp()),
            "iss": s.jwt_issuer,
            "aud": "fils-app",
            "jti": secrets.token_hex(8),
        }
    )
    return tok, exp


def issue_reauth_token(user_id: uuid.UUID, session_id: uuid.UUID) -> tuple[str, datetime]:
    s = get_settings()
    iat = now()
    exp = iat + timedelta(seconds=s.reauth_ttl_seconds)
    tok = _encode(
        {
            "sub": str(user_id),
            "sid": str(session_id),
            "typ": "reauth",
            "iat": int(iat.timestamp()),
            "exp": int(exp.timestamp()),
            "iss": s.jwt_issuer,
            "aud": "fils-app",
        }
    )
    return tok, exp


@dataclass
class CurrentUser:
    user: User
    session: DeviceSession

    @property
    def id(self) -> uuid.UUID:
        return self.user.id


def decode_access_subject(token: str) -> str | None:
    """Best-effort subject extraction for middleware (rate limit/idempotency scoping). No DB."""
    try:
        return _decode(token, "access")["sub"]
    except APIError:
        return None


def get_current_user(request: Request, db: Session = Depends(get_db)) -> CurrentUser:
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        raise APIError(401, "unauthorized", "Missing bearer token")
    claims = _decode(auth[7:].strip(), "access")
    try:
        uid = uuid.UUID(claims["sub"])
        sid = uuid.UUID(claims["sid"])
    except (KeyError, ValueError) as e:
        raise APIError(401, "invalid_token", "Invalid token") from e
    sess = db.get(DeviceSession, sid)
    if sess is None or sess.user_id != uid or sess.revoked_at is not None:
        raise APIError(401, "session_revoked", "Session is no longer valid")
    user = db.get(User, uid)
    if user is None or user.status != "active":
        raise APIError(401, "account_unavailable", "Account is not active")
    request.state.user_id = str(uid)
    return CurrentUser(user=user, session=sess)


def require_reauth(
    current: CurrentUser = Depends(get_current_user),
    x_reauth: str | None = Header(default=None, alias="X-Reauth"),
) -> CurrentUser:
    if not x_reauth:
        raise APIError(403, "reauth_required", "Recent re-authentication required")
    claims = _decode(x_reauth, "reauth")
    if claims.get("sub") != str(current.id) or claims.get("sid") != str(current.session.id):
        raise APIError(403, "reauth_required", "Re-authentication token does not match session")
    return current


def find_user_session(db: Session, user_id: uuid.UUID) -> list[DeviceSession]:
    return list(db.scalars(select(DeviceSession).where(DeviceSession.user_id == user_id)))
