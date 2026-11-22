"""Database schema. Every user-owned table carries user_id for tenant isolation."""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    Sequence,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base

sync_change_seq = Sequence("sync_change_seq", metadata=Base.metadata)


def _uuid() -> uuid.UUID:
    return uuid.uuid4()


def utcnow_col(**kw):
    return mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False, **kw)


class User(Base):
    __tablename__ = "users"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    display_name: Mapped[str | None] = mapped_column(String(120))
    email: Mapped[str | None] = mapped_column(String(320))
    email_verified: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    locale: Mapped[str] = mapped_column(String(10), default="ar", nullable=False)
    status: Mapped[str] = mapped_column(String(16), default="active", nullable=False)  # active|deleting
    is_demo: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = utcnow_col()


class AuthIdentity(Base):
    __tablename__ = "auth_identities"
    __table_args__ = (UniqueConstraint("provider", "subject", name="uq_identity_provider_subject"),)
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    provider: Mapped[str] = mapped_column(String(16))  # apple|google|demo
    subject: Mapped[str] = mapped_column(String(255))
    email: Mapped[str | None] = mapped_column(String(320))
    created_at: Mapped[datetime] = utcnow_col()


class AuthNonce(Base):
    __tablename__ = "auth_nonces"
    # sha256 hex of the raw nonce == the value the client hands to Apple/Google
    nonce_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class DeviceSession(Base):
    __tablename__ = "sessions"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    device_id: Mapped[str] = mapped_column(String(128))
    platform: Mapped[str] = mapped_column(String(16))
    app_version: Mapped[str] = mapped_column(String(32))
    device_name: Mapped[str | None] = mapped_column(String(120))
    created_at: Mapped[datetime] = utcnow_col()
    last_used_at: Mapped[datetime] = utcnow_col()
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoke_reason: Mapped[str | None] = mapped_column(String(32))


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    session_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("sessions.id", ondelete="CASCADE"), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    created_at: Mapped[datetime] = utcnow_col()
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class ConsentRecord(Base):
    """Append-only consent history. Current state = latest row per kind."""

    __tablename__ = "consent_records"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(32))
    granted: Mapped[bool] = mapped_column(Boolean)
    policy_version: Mapped[str] = mapped_column(String(32))
    source: Mapped[str] = mapped_column(String(32))
    created_at: Mapped[datetime] = utcnow_col()
    seq: Mapped[int] = mapped_column(BigInteger, Sequence("consent_seq"), server_default=Sequence("consent_seq").next_value())


class SyncRecord(Base):
    __tablename__ = "sync_records"
    __table_args__ = (
        Index("ix_sync_owner_seq", "owner_user_id", "change_seq"),
        Index("ix_sync_household_seq", "household_id", "change_seq"),
    )
    entity: Mapped[str] = mapped_column(String(24), primary_key=True)
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    owner_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    household_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("households.id", ondelete="CASCADE"))
    version: Mapped[int] = mapped_column(Integer)
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    payload: Mapped[dict] = mapped_column(JSONB)
    client_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    server_updated_at: Mapped[datetime] = utcnow_col()
    change_seq: Mapped[int] = mapped_column(BigInteger)
    last_device_id: Mapped[str | None] = mapped_column(String(128))


class IdempotencyKey(Base):
    __tablename__ = "idempotency_keys"
    scope: Mapped[str] = mapped_column(String(80), primary_key=True)  # user id or "anon:<ip>"
    key: Mapped[str] = mapped_column(String(128), primary_key=True)
    request_hash: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16), default="pending")  # pending|done
    response_status: Mapped[int | None] = mapped_column(Integer)
    response_body: Mapped[bytes | None] = mapped_column(LargeBinary)
    response_content_type: Mapped[str | None] = mapped_column(String(100))
    created_at: Mapped[datetime] = utcnow_col()


class Job(Base):
    __tablename__ = "jobs"
    __table_args__ = (Index("ix_jobs_claim", "status", "run_after"),)
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    kind: Mapped[str] = mapped_column(String(32))
    user_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), index=True)  # no FK: survives deletion
    status: Mapped[str] = mapped_column(String(16), default="queued")  # queued|running|succeeded|failed
    payload: Mapped[dict] = mapped_column(JSONB, default=dict)
    result: Mapped[dict | None] = mapped_column(JSONB)
    error: Mapped[str | None] = mapped_column(Text)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    max_attempts: Mapped[int] = mapped_column(Integer, default=5)
    run_after: Mapped[datetime] = utcnow_col()
    locked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    locked_by: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = utcnow_col()
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class TempBlob(Base):
    """AES-GCM encrypted temporary file (uploads, exports). Purged after expiry."""

    __tablename__ = "temp_blobs"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), index=True)
    purpose: Mapped[str] = mapped_column(String(16))  # upload|export
    filename: Mapped[str] = mapped_column(String(200))
    content_type: Mapped[str] = mapped_column(String(100))
    data: Mapped[bytes] = mapped_column(LargeBinary)
    created_at: Mapped[datetime] = utcnow_col()
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Household(Base):
    __tablename__ = "households"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    name: Mapped[str] = mapped_column(String(80))
    owner_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = utcnow_col()


class HouseholdMember(Base):
    __tablename__ = "household_members"
    household_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("households.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True, index=True)
    role: Mapped[str] = mapped_column(String(16))  # owner|member|viewer
    joined_at: Mapped[datetime] = utcnow_col()


class HouseholdInvitation(Base):
    __tablename__ = "household_invitations"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    household_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("households.id", ondelete="CASCADE"), index=True)
    code_hash: Mapped[str] = mapped_column(String(64), unique=True)
    role: Mapped[str] = mapped_column(String(16))
    created_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = utcnow_col()
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    used_by: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    failed_attempts: Mapped[int] = mapped_column(Integer, default=0)


class Entitlement(Base):
    __tablename__ = "entitlements"
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    plan: Mapped[str] = mapped_column(String(16), default="free")
    source: Mapped[str] = mapped_column(String(16), default="none")
    product_id: Mapped[str | None] = mapped_column(String(120))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    in_grace_period: Mapped[bool] = mapped_column(Boolean, default=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    environment: Mapped[str | None] = mapped_column(String(16))
    updated_at: Mapped[datetime] = utcnow_col()


class PurchaseLink(Base):
    """Maps a store purchase to exactly one account (prevents sharing one purchase across accounts)."""

    __tablename__ = "purchase_links"
    platform: Mapped[str] = mapped_column(String(8), primary_key=True)  # apple|google
    purchase_key: Mapped[str] = mapped_column(String(255), primary_key=True)  # originalTransactionId|purchaseToken hash
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    product_id: Mapped[str] = mapped_column(String(120))
    created_at: Mapped[datetime] = utcnow_col()


class BillingEvent(Base):
    __tablename__ = "billing_events"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    platform: Mapped[str] = mapped_column(String(8))
    event_key: Mapped[str] = mapped_column(String(255), unique=True)  # notificationUUID / pubsub messageId
    event_type: Mapped[str] = mapped_column(String(64))
    payload: Mapped[dict] = mapped_column(JSONB)
    received_at: Mapped[datetime] = utcnow_col()


class AIUsage(Base):
    __tablename__ = "ai_usage"
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    month: Mapped[str] = mapped_column(String(7), primary_key=True)
    input_tokens: Mapped[int] = mapped_column(BigInteger, default=0)
    output_tokens: Mapped[int] = mapped_column(BigInteger, default=0)
    requests: Mapped[int] = mapped_column(Integer, default=0)


class ParserSample(Base):
    __tablename__ = "parser_samples"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    bank_id: Mapped[str | None] = mapped_column(String(40))
    sender: Mapped[str | None] = mapped_column(String(64))
    sanitized_text: Mapped[str] = mapped_column(Text)
    kind_hint: Mapped[str | None] = mapped_column(String(32))
    app_version: Mapped[str] = mapped_column(String(32))
    created_at: Mapped[datetime] = utcnow_col()


class AuditEvent(Base):
    __tablename__ = "audit_events"
    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=_uuid)
    user_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), index=True)
    action: Mapped[str] = mapped_column(String(48))
    detail: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[datetime] = utcnow_col()
