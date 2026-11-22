from __future__ import annotations

import base64
import json
import logging
import uuid
from typing import Literal

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..config import get_settings
from ..db import get_db
from ..errors import APIError
from ..models import AuditEvent, BillingEvent, PurchaseLink
from ..security import CurrentUser, get_current_user, now, sha256_hex
from ..services.apple_jws import JWSVerificationError, ms_to_dt, verify_jws
from ..services.entitlements import entitlements_for, upsert_entitlement
from ..services.google_play import ACTIVE_STATES, parse_rfc3339, verify_pubsub_oidc

log = logging.getLogger("fils.billing")
router = APIRouter(prefix="/v1", tags=["billing"])


class AppleVerifyIn(BaseModel):
    signed_transaction: str = Field(max_length=20000)


class GoogleVerifyIn(BaseModel):
    product_id: str = Field(max_length=120)
    purchase_token: str = Field(max_length=2000)


class RestoreIn(BaseModel):
    platform: Literal["ios", "android"]
    signed_transactions: list[str] = Field(default_factory=list, max_length=50)
    purchase_tokens: list[str] = Field(default_factory=list, max_length=50)


@router.get("/billing/products")
def products():
    s = get_settings()
    return {
        "apple": [{"product_id": p, "plan": "premium"} for p in s.apple_product_ids],
        "google": [{"product_id": p, "plan": "premium"} for p in s.google_product_ids],
        "note": "Prices are shown from StoreKit / Google Play, never from this server.",
    }


# ---------------------------------------------------------------- Apple

def _verify_apple(request: Request, token: str) -> dict:
    try:
        return verify_jws(token, request.app.state.apple_roots)
    except JWSVerificationError as e:
        raise APIError(401, "invalid_signed_payload", "Signed payload failed verification") from e


def _link(db: Session, platform: str, key: str, user_id: uuid.UUID, product_id: str) -> None:
    link = db.get(PurchaseLink, (platform, key))
    if link is None:
        db.add(PurchaseLink(platform=platform, purchase_key=key, user_id=user_id, product_id=product_id))
        db.flush()
    elif link.user_id != user_id:
        raise APIError(409, "purchase_belongs_to_other_account", "This purchase is linked to a different Fils account")


def _apply_apple_tx(db: Session, tx: dict, user_id: uuid.UUID | None, grace: bool = False) -> uuid.UUID | None:
    s = get_settings()
    if tx.get("bundleId") != s.apple_bundle_id:
        raise APIError(422, "wrong_bundle", "Transaction is for a different app")
    product = tx.get("productId")
    if product not in s.apple_product_ids:
        raise APIError(422, "unknown_product", "Unknown product")
    env = tx.get("environment", "Production")
    if env == "Sandbox" and s.is_production and not s.apple_allow_sandbox:
        raise APIError(422, "sandbox_not_allowed", "Sandbox purchases are not accepted")
    otid = str(tx.get("originalTransactionId") or "")
    if not otid:
        raise APIError(422, "invalid_transaction", "Missing originalTransactionId")
    if user_id is not None:
        token = tx.get("appAccountToken")
        if token and str(token).lower() != str(user_id).lower():
            raise APIError(409, "purchase_belongs_to_other_account", "Purchase was made for a different account")
        _link(db, "apple", otid, user_id, product)
    else:
        link = db.get(PurchaseLink, ("apple", otid))
        if link is None:
            return None
        user_id = link.user_id
    revoked = ms_to_dt(tx.get("revocationDate"))
    upsert_entitlement(
        db,
        user_id,
        plan="premium" if revoked is None else "free",
        source="apple",
        product_id=product,
        expires_at=ms_to_dt(tx.get("expiresDate")),
        in_grace_period=grace,
        revoked_at=revoked,
        environment=env,
    )
    return user_id


@router.post("/billing/apple/verify")
def apple_verify(body: AppleVerifyIn, request: Request, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    tx = _verify_apple(request, body.signed_transaction)
    _apply_apple_tx(db, tx, current.id)
    db.add(AuditEvent(user_id=current.id, action="purchase_verified", detail={"platform": "apple", "product": tx.get("productId")}))
    db.commit()
    return entitlements_for(db, current.id)


def _record_event(db: Session, platform: str, key: str, event_type: str, payload: dict) -> bool:
    """Returns False if this event was already processed (replay / provider retry)."""
    try:
        with db.begin_nested():
            db.add(BillingEvent(platform=platform, event_key=key, event_type=event_type, payload=payload))
            db.flush()
        return True
    except IntegrityError:
        return False


@router.post("/webhooks/apple")
def apple_webhook(body: dict, request: Request, db: Session = Depends(get_db)):
    signed = body.get("signedPayload")
    if not isinstance(signed, str):
        raise APIError(400, "invalid_payload", "signedPayload missing")
    n = _verify_apple(request, signed)
    uuid_key = n.get("notificationUUID")
    ntype = n.get("notificationType", "")
    subtype = n.get("subtype")
    if not uuid_key:
        raise APIError(400, "invalid_payload", "notificationUUID missing")
    if not _record_event(db, "apple", uuid_key, ntype, {"type": ntype, "subtype": subtype}):
        db.rollback()
        return {"status": "duplicate"}
    data = n.get("data") or {}
    if data.get("bundleId") and data.get("bundleId") != get_settings().apple_bundle_id:
        db.commit()
        return {"status": "ignored"}
    signed_tx = data.get("signedTransactionInfo")
    if ntype == "TEST" or not signed_tx:
        db.commit()
        return {"status": "ok"}
    tx = _verify_apple(request, signed_tx)
    if ntype in ("EXPIRED", "GRACE_PERIOD_EXPIRED"):
        link = db.get(PurchaseLink, ("apple", str(tx.get("originalTransactionId"))))
        if link:
            upsert_entitlement(db, link.user_id, plan="free", source="apple", product_id=tx.get("productId"),
                               expires_at=ms_to_dt(tx.get("expiresDate")), environment=tx.get("environment"))
    elif ntype in ("REFUND", "REVOKE"):
        link = db.get(PurchaseLink, ("apple", str(tx.get("originalTransactionId"))))
        if link:
            upsert_entitlement(db, link.user_id, plan="free", source="apple", product_id=tx.get("productId"),
                               expires_at=ms_to_dt(tx.get("expiresDate")), revoked_at=ms_to_dt(tx.get("revocationDate")) or now(),
                               environment=tx.get("environment"))
    else:
        grace = ntype == "DID_FAIL_TO_RENEW" and subtype == "GRACE_PERIOD"
        _apply_apple_tx(db, tx, None, grace=grace)
    db.commit()
    return {"status": "ok"}


# ---------------------------------------------------------------- Google

def _apply_google(db: Session, request: Request, token: str, user_id: uuid.UUID | None, expect_product: str | None = None) -> uuid.UUID | None:
    s = get_settings()
    client = request.app.state.play_client
    sub = client.get_subscription(s.google_package_name, token)
    items = sub.get("lineItems") or []
    product = items[0].get("productId") if items else None
    if product not in s.google_product_ids or (expect_product and product != expect_product):
        raise APIError(422, "unknown_product", "Unknown product")
    key = sha256_hex(token)
    if user_id is not None:
        obf = (sub.get("externalAccountIdentifiers") or {}).get("obfuscatedExternalAccountId")
        if obf and obf != sha256_hex(str(user_id)):
            raise APIError(409, "purchase_belongs_to_other_account", "Purchase was made for a different account")
        _link(db, "google", key, user_id, product)
    else:
        link = db.get(PurchaseLink, ("google", key))
        if link is None:
            return None
        user_id = link.user_id
    state = sub.get("subscriptionState")
    expiry = max((parse_rfc3339(i.get("expiryTime")) for i in items if i.get("expiryTime")), default=None)
    revoked = None  # revocation arrives via RTDN SUBSCRIPTION_REVOKED (handled in the webhook)
    upsert_entitlement(
        db,
        user_id,
        plan="premium" if state in ACTIVE_STATES or state == "SUBSCRIPTION_STATE_CANCELED" else "free",
        source="google",
        product_id=product,
        expires_at=expiry,
        in_grace_period=state == "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
        revoked_at=revoked,
        environment="test" if sub.get("testPurchase") is not None else "production",
    )
    if sub.get("acknowledgementState") == "ACKNOWLEDGEMENT_STATE_PENDING" and state in ACTIVE_STATES:
        client.acknowledge(s.google_package_name, product, token)
    return user_id


@router.post("/billing/google/verify")
def google_verify(body: GoogleVerifyIn, request: Request, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    _apply_google(db, request, body.purchase_token, current.id, expect_product=body.product_id)
    db.add(AuditEvent(user_id=current.id, action="purchase_verified", detail={"platform": "google", "product": body.product_id}))
    db.commit()
    return entitlements_for(db, current.id)


@router.post("/billing/restore")
def restore(body: RestoreIn, request: Request, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    errors = []
    if body.platform == "ios":
        for t in body.signed_transactions:
            try:
                _apply_apple_tx(db, _verify_apple(request, t), current.id)
            except APIError as e:
                errors.append(e.code)
    else:
        for t in body.purchase_tokens:
            try:
                _apply_google(db, request, t, current.id)
            except APIError as e:
                errors.append(e.code)
    db.commit()
    out = entitlements_for(db, current.id)
    out["restore_errors"] = errors
    return out


GOOGLE_EXPIRED_TYPES = {13}  # SUBSCRIPTION_EXPIRED
GOOGLE_REVOKED_TYPES = {12}  # SUBSCRIPTION_REVOKED


@router.post("/webhooks/google")
def google_webhook(body: dict, request: Request, db: Session = Depends(get_db)):
    s = get_settings()
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        raise APIError(401, "invalid_push_token", "Missing push token")
    verify_pubsub_oidc(auth[7:], request.app.state.google_oidc_cache, s.google_pubsub_audience, s.google_pubsub_service_account)
    msg = body.get("message") or {}
    mid = msg.get("messageId") or msg.get("message_id")
    if not mid or "data" not in msg:
        raise APIError(400, "invalid_payload", "Pub/Sub message missing")
    try:
        note = json.loads(base64.b64decode(msg["data"]))
    except Exception as e:  # noqa: BLE001
        raise APIError(400, "invalid_payload", "Undecodable message data") from e
    if note.get("packageName") != s.google_package_name:
        raise APIError(400, "invalid_payload", "Wrong package")
    sn = note.get("subscriptionNotification")
    etype = str(sn.get("notificationType")) if sn else ("test" if note.get("testNotification") else "other")
    if not _record_event(db, "google", str(mid), etype, {"type": etype}):
        db.rollback()
        return {"status": "duplicate"}
    if sn and sn.get("purchaseToken"):
        token = sn["purchaseToken"]
        link = db.get(PurchaseLink, ("google", sha256_hex(token)))
        if link is not None:
            if int(sn.get("notificationType", 0)) in GOOGLE_REVOKED_TYPES:
                upsert_entitlement(db, link.user_id, plan="free", source="google", product_id=link.product_id,
                                   expires_at=now(), revoked_at=now())
            else:
                _apply_google(db, request, token, None)
    db.commit()
    return {"status": "ok"}
