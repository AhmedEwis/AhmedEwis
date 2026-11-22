from __future__ import annotations

import uuid
from datetime import timedelta
from typing import Literal

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from ..config import get_settings
from ..db import get_db
from ..errors import APIError
from ..models import AuditEvent, AuthIdentity, AuthNonce, DeviceSession, RefreshToken, User
from ..providers.identity import VerifiedIdentity
from ..security import (
    CurrentUser,
    get_current_user,
    issue_access_token,
    issue_reauth_token,
    now,
    random_token,
    require_reauth,
    sha256_hex,
)
from ..services.consents import consent_state
from ..services.entitlements import entitlements_for

router = APIRouter(prefix="/v1", tags=["auth"])


class DeviceInfo(BaseModel):
    device_id: str = Field(min_length=8, max_length=128)
    platform: Literal["ios", "android"]
    app_version: str = Field(max_length=32)
    name: str | None = Field(default=None, max_length=120)


class AppleSignIn(BaseModel):
    identity_token: str = Field(max_length=8192)
    nonce: str = Field(min_length=16, max_length=128)
    authorization_code: str | None = Field(default=None, max_length=1024)
    device: DeviceInfo
    full_name: str | None = Field(default=None, max_length=120)


class GoogleSignIn(BaseModel):
    id_token: str = Field(max_length=8192)
    nonce: str = Field(min_length=16, max_length=128)
    device: DeviceInfo


class RefreshIn(BaseModel):
    refresh_token: str = Field(max_length=256)


class ReauthIn(BaseModel):
    provider: Literal["apple", "google"]
    token: str = Field(max_length=8192)
    nonce: str = Field(min_length=16, max_length=128)


class LinkIn(BaseModel):
    token: str = Field(max_length=8192)
    nonce: str = Field(min_length=16, max_length=128)


def user_out(db: Session, user: User) -> dict:
    idents = db.scalars(select(AuthIdentity).where(AuthIdentity.user_id == user.id)).all()
    return {
        "id": str(user.id),
        "display_name": user.display_name,
        "email": user.email,
        "email_verified": user.email_verified,
        "created_at": user.created_at.isoformat() if user.created_at else None,
        "locale": user.locale,
        "is_demo": user.is_demo,
        "identities": [{"provider": i.provider, "subject_hint": i.subject[-4:]} for i in idents],
        "entitlements": entitlements_for(db, user.id),
        "consents": consent_state(db, user.id),
    }


def _consume_nonce(db: Session, raw_nonce: str, token_nonce: str | None) -> None:
    """The provider token must carry sha256(raw_nonce); the nonce must be server-issued, unused, unexpired."""
    h = sha256_hex(raw_nonce)
    if token_nonce != h:
        raise APIError(401, "nonce_mismatch", "Token nonce does not match")
    res = db.execute(
        update(AuthNonce)
        .where(AuthNonce.nonce_hash == h, AuthNonce.used_at.is_(None), AuthNonce.expires_at > now())
        .values(used_at=now())
    )
    if res.rowcount != 1:
        raise APIError(401, "nonce_invalid", "Nonce is unknown, expired or already used")


def _verify(request: Request, provider: str, token: str) -> VerifiedIdentity:
    verifiers = request.app.state.identity_verifiers
    return verifiers[provider].verify(token)


def _issue_session(db: Session, user: User, device: DeviceInfo) -> dict:
    s = get_settings()
    sess = DeviceSession(
        user_id=user.id,
        device_id=device.device_id,
        platform=device.platform,
        app_version=device.app_version,
        device_name=device.name,
    )
    db.add(sess)
    db.flush()
    return _issue_tokens(db, sess, s)


def _issue_tokens(db: Session, sess: DeviceSession, s) -> dict:
    raw = random_token()
    rt = RefreshToken(session_id=sess.id, token_hash=sha256_hex(raw), expires_at=now() + timedelta(days=s.refresh_ttl_days))
    db.add(rt)
    access, access_exp = issue_access_token(sess.user_id, sess.id)
    sess.last_used_at = now()
    db.flush()
    return {
        "access_token": access,
        "access_expires_at": access_exp.isoformat(),
        "refresh_token": raw,
        "refresh_expires_at": rt.expires_at.isoformat(),
    }


def _sign_in(db: Session, ident: VerifiedIdentity, device: DeviceInfo, full_name: str | None = None) -> dict:
    existing = db.scalar(
        select(AuthIdentity).where(AuthIdentity.provider == ident.provider, AuthIdentity.subject == ident.subject)
    )
    is_new = False
    if existing is not None:
        user = db.get(User, existing.user_id)
        if user is None or user.status != "active":
            raise APIError(403, "account_unavailable", "This account is being deleted")
    else:
        # A new provider identity ALWAYS creates a new account. Matching email never links.
        is_new = True
        user = User(
            display_name=full_name,
            email=ident.email,
            email_verified=ident.email_verified,
        )
        db.add(user)
        db.flush()
        db.add(AuthIdentity(user_id=user.id, provider=ident.provider, subject=ident.subject, email=ident.email))
        db.add(AuditEvent(user_id=user.id, action="account_created", detail={"provider": ident.provider}))
    tokens = _issue_session(db, user, device)
    db.add(AuditEvent(user_id=user.id, action="sign_in", detail={"provider": ident.provider, "platform": device.platform}))
    db.commit()
    return {**tokens, "user": user_out(db, user), "is_new_user": is_new}


@router.post("/auth/nonce")
def create_nonce(db: Session = Depends(get_db)):
    s = get_settings()
    raw = random_token(32)
    exp = now() + timedelta(seconds=s.nonce_ttl_seconds)
    db.add(AuthNonce(nonce_hash=sha256_hex(raw), expires_at=exp))
    db.commit()
    return {"nonce": raw, "expires_at": exp.isoformat()}


@router.post("/auth/apple")
def sign_in_apple(body: AppleSignIn, request: Request, db: Session = Depends(get_db)):
    ident = _verify(request, "apple", body.identity_token)
    _consume_nonce(db, body.nonce, ident.nonce)
    return _sign_in(db, ident, body.device, body.full_name)


@router.post("/auth/google")
def sign_in_google(body: GoogleSignIn, request: Request, db: Session = Depends(get_db)):
    ident = _verify(request, "google", body.id_token)
    _consume_nonce(db, body.nonce, ident.nonce)
    return _sign_in(db, ident, body.device)


@router.post("/auth/refresh")
def refresh(body: RefreshIn, db: Session = Depends(get_db)):
    s = get_settings()
    h = sha256_hex(body.refresh_token)
    rt = db.scalar(select(RefreshToken).where(RefreshToken.token_hash == h).with_for_update())
    if rt is None:
        raise APIError(401, "invalid_refresh_token", "Unknown refresh token")
    sess = db.get(DeviceSession, rt.session_id)
    if sess is None or sess.revoked_at is not None:
        raise APIError(401, "session_revoked", "Session revoked")
    if rt.used_at is not None:
        # Reuse of a rotated token => likely theft. Revoke the whole session family.
        sess.revoked_at = now()
        sess.revoke_reason = "refresh_reuse"
        db.add(AuditEvent(user_id=sess.user_id, action="refresh_reuse_detected", detail={"session_id": str(sess.id)}))
        db.commit()
        raise APIError(401, "refresh_token_reused", "Refresh token reuse detected; session revoked")
    if rt.expires_at <= now():
        raise APIError(401, "refresh_token_expired", "Refresh token expired")
    user = db.get(User, sess.user_id)
    if user is None or user.status != "active":
        raise APIError(401, "account_unavailable", "Account not active")
    rt.used_at = now()
    tokens = _issue_tokens(db, sess, s)
    db.commit()
    return {**tokens, "user": user_out(db, user), "is_new_user": False}


@router.post("/auth/logout", status_code=204)
def logout(body: RefreshIn, db: Session = Depends(get_db)):
    rt = db.scalar(select(RefreshToken).where(RefreshToken.token_hash == sha256_hex(body.refresh_token)))
    if rt is not None:
        sess = db.get(DeviceSession, rt.session_id)
        if sess and sess.revoked_at is None:
            sess.revoked_at = now()
            sess.revoke_reason = "logout"
            db.commit()
    return Response(status_code=204)


@router.post("/auth/reauth")
def reauth(body: ReauthIn, request: Request, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    ident = _verify(request, body.provider, body.token)
    _consume_nonce(db, body.nonce, ident.nonce)
    owned = db.scalar(
        select(AuthIdentity).where(
            AuthIdentity.provider == ident.provider,
            AuthIdentity.subject == ident.subject,
            AuthIdentity.user_id == current.id,
        )
    )
    if owned is None:
        db.commit()
        raise APIError(403, "reauth_identity_mismatch", "That identity does not belong to this account")
    tok, exp = issue_reauth_token(current.id, current.session.id)
    db.commit()
    return {"reauth_token": tok, "expires_at": exp.isoformat()}


@router.post("/me/identities/{provider}")
def link_identity(
    provider: Literal["apple", "google"],
    body: LinkIn,
    request: Request,
    current: CurrentUser = Depends(require_reauth),
    db: Session = Depends(get_db),
):
    ident = _verify(request, provider, body.token)
    _consume_nonce(db, body.nonce, ident.nonce)
    existing = db.scalar(select(AuthIdentity).where(AuthIdentity.provider == provider, AuthIdentity.subject == ident.subject))
    if existing is not None and existing.user_id != current.id:
        db.commit()
        raise APIError(409, "identity_in_use", "This sign-in is already used by another account")
    if existing is None:
        db.add(AuthIdentity(user_id=current.id, provider=provider, subject=ident.subject, email=ident.email))
        db.add(AuditEvent(user_id=current.id, action="identity_linked", detail={"provider": provider}))
    db.commit()
    return user_out(db, current.user)


@router.post("/demo/session")
def demo_session(device: DeviceInfo, db: Session = Depends(get_db)):
    if get_settings().is_production:
        raise APIError(404, "not_found", "Not Found")
    user = User(display_name="Demo", is_demo=True, locale="ar")
    db.add(user)
    db.flush()
    db.add(AuthIdentity(user_id=user.id, provider="demo", subject=f"demo-{uuid.uuid4()}"))
    tokens = _issue_session(db, user, device)
    db.commit()
    return {**tokens, "user": user_out(db, user), "is_new_user": True}
