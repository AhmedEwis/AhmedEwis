from __future__ import annotations

import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..errors import APIError
from ..models import ConsentRecord

CONSENT_KINDS = ("cloud_backup", "cloud_sync", "cloud_ai", "cloud_voice", "sample_submission", "analytics", "marketing")


def consent_state(db: Session, user_id: uuid.UUID) -> dict[str, bool]:
    state = {k: False for k in CONSENT_KINDS}
    rows = db.scalars(
        select(ConsentRecord).where(ConsentRecord.user_id == user_id).order_by(ConsentRecord.seq.asc())
    )
    for r in rows:
        state[r.kind] = r.granted
    return state


def has_consent(db: Session, user_id: uuid.UUID, *kinds: str) -> bool:
    st = consent_state(db, user_id)
    return any(st.get(k, False) for k in kinds)


def require_consent(db: Session, user_id: uuid.UUID, *kinds: str) -> None:
    if not has_consent(db, user_id, *kinds):
        raise APIError(403, "consent_required", f"Consent required: {' or '.join(kinds)}", {"kinds": list(kinds)})


def record_consent(db: Session, user_id: uuid.UUID, kind: str, granted: bool, policy_version: str, source: str) -> ConsentRecord:
    if kind not in CONSENT_KINDS:
        raise APIError(422, "invalid_consent_kind", "Unknown consent kind")
    rec = ConsentRecord(user_id=user_id, kind=kind, granted=granted, policy_version=policy_version, source=source)
    db.add(rec)
    db.flush()
    return rec
