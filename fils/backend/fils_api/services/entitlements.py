from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from sqlalchemy.orm import Session

from ..config import get_settings
from ..models import Entitlement
from ..security import now

PREMIUM_FEATURES = {
    "unlimited_voice": True,
    "assistant": True,
    "cloud_sync": True,
    "household": True,
    "document_import": True,
    "export": True,
    "advanced_analytics": True,
}
FREE_FEATURES = {
    "unlimited_voice": False,
    "assistant": True,  # metered by quota
    "cloud_sync": True,
    "household": False,
    "document_import": True,
    "export": True,
    "advanced_analytics": False,
}


def entitlements_for(db: Session, user_id: uuid.UUID) -> dict:
    s = get_settings()
    if s.features_unlocked:
        return {
            "plan": "premium",
            "source": "dev_unlocked",
            "expires_at": None,
            "in_grace_period": False,
            "features": dict(PREMIUM_FEATURES),
        }
    ent = db.get(Entitlement, user_id)
    if ent is None or ent.revoked_at is not None:
        return {"plan": "free", "source": "none", "expires_at": None, "in_grace_period": False, "features": dict(FREE_FEATURES)}
    t = now()
    active = ent.plan == "premium" and (ent.expires_at is None or ent.expires_at > t)
    grace = ent.in_grace_period and ent.expires_at is not None and ent.expires_at + timedelta(days=s.billing_grace_days) > t
    if active or grace:
        return {
            "plan": "premium",
            "source": ent.source,
            "expires_at": ent.expires_at.isoformat() if ent.expires_at else None,
            "in_grace_period": bool(grace and not active),
            "features": dict(PREMIUM_FEATURES),
        }
    return {
        "plan": "free",
        "source": ent.source,
        "expires_at": ent.expires_at.isoformat() if ent.expires_at else None,
        "in_grace_period": False,
        "features": dict(FREE_FEATURES),
    }


def upsert_entitlement(
    db: Session,
    user_id: uuid.UUID,
    *,
    plan: str,
    source: str,
    product_id: str | None,
    expires_at: datetime | None,
    in_grace_period: bool = False,
    revoked_at: datetime | None = None,
    environment: str | None = None,
) -> Entitlement:
    ent = db.get(Entitlement, user_id)
    if ent is None:
        ent = Entitlement(user_id=user_id)
        db.add(ent)
    ent.plan = plan
    ent.source = source
    ent.product_id = product_id
    ent.expires_at = expires_at
    ent.in_grace_period = in_grace_period
    ent.revoked_at = revoked_at
    ent.environment = environment
    ent.updated_at = now()
    db.flush()
    return ent
