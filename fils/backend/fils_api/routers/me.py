from __future__ import annotations

import uuid
from typing import Literal

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import get_db
from ..errors import APIError
from ..models import AuditEvent, ConsentRecord, DeviceSession, TempBlob
from ..security import CurrentUser, get_current_user, now, require_reauth
from ..services import jobs
from ..services.blobs import read_blob
from ..services.consents import CONSENT_KINDS, consent_state, record_consent
from .auth import user_out

router = APIRouter(prefix="/v1", tags=["me"])


class ConsentIn(BaseModel):
    kind: Literal[CONSENT_KINDS]  # type: ignore[valid-type]
    granted: bool
    policy_version: str = Field(min_length=1, max_length=32)
    source: str = Field(default="app", max_length=32)


@router.get("/me")
def me(current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    return user_out(db, current.user)


@router.get("/me/sessions")
def sessions(current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    rows = db.scalars(
        select(DeviceSession).where(DeviceSession.user_id == current.id).order_by(DeviceSession.created_at.desc())
    ).all()
    return [
        {
            "id": str(r.id),
            "device_id": r.device_id,
            "platform": r.platform,
            "app_version": r.app_version,
            "name": r.device_name,
            "created_at": r.created_at.isoformat(),
            "last_used_at": r.last_used_at.isoformat(),
            "revoked_at": r.revoked_at.isoformat() if r.revoked_at else None,
            "current": r.id == current.session.id,
        }
        for r in rows
    ]


@router.delete("/me/sessions/{session_id}", status_code=204)
def revoke_session(session_id: uuid.UUID, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    sess = db.get(DeviceSession, session_id)
    if sess is None or sess.user_id != current.id:
        raise APIError(404, "not_found", "Session not found")
    if sess.revoked_at is None:
        sess.revoked_at = now()
        sess.revoke_reason = "user_revoked"
        db.add(AuditEvent(user_id=current.id, action="session_revoked", detail={"session_id": str(session_id)}))
        db.commit()
    return Response(status_code=204)


@router.get("/me/consents")
def get_consents(current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    hist = db.scalars(
        select(ConsentRecord).where(ConsentRecord.user_id == current.id).order_by(ConsentRecord.seq.desc())
    ).all()
    return {
        "state": consent_state(db, current.id),
        "history": [
            {
                "id": str(h.id),
                "kind": h.kind,
                "granted": h.granted,
                "policy_version": h.policy_version,
                "source": h.source,
                "created_at": h.created_at.isoformat(),
            }
            for h in hist
        ],
    }


@router.post("/me/consents")
def post_consent(body: ConsentIn, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    record_consent(db, current.id, body.kind, body.granted, body.policy_version, body.source)
    db.commit()
    return {"state": consent_state(db, current.id)}


@router.post("/me/export", status_code=202)
def start_export(current: CurrentUser = Depends(require_reauth), db: Session = Depends(get_db)):
    job = jobs.enqueue(db, "export", current.id)
    db.add(AuditEvent(user_id=current.id, action="export_requested", detail={"job_id": str(job.id)}))
    db.commit()
    return jobs.job_out(job)


@router.get("/jobs/{job_id}")
def get_job(job_id: uuid.UUID, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    job = jobs.get_owned_job(db, job_id, current.id)
    if job is None:
        raise APIError(404, "not_found", "Job not found")
    return jobs.job_out(job)


@router.get("/jobs/{job_id}/download")
def download_job(job_id: uuid.UUID, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    job = jobs.get_owned_job(db, job_id, current.id)
    if job is None or job.status != "succeeded" or not (job.result or {}).get("blob_id"):
        raise APIError(404, "not_found", "No downloadable result")
    blob = db.get(TempBlob, uuid.UUID(job.result["blob_id"]))
    if blob is None or blob.user_id != current.id or blob.expires_at <= now():
        raise APIError(410, "expired", "Export has expired; request a new one")
    return Response(
        content=read_blob(blob),
        media_type=blob.content_type,
        headers={"Content-Disposition": f'attachment; filename="{blob.filename}"', "Cache-Control": "no-store"},
    )


@router.delete("/me", status_code=202)
def delete_account(current: CurrentUser = Depends(require_reauth), db: Session = Depends(get_db)):
    user = current.user
    user.status = "deleting"
    for s in db.scalars(select(DeviceSession).where(DeviceSession.user_id == user.id, DeviceSession.revoked_at.is_(None))):
        s.revoked_at = now()
        s.revoke_reason = "account_deleted"
    job = jobs.enqueue(db, "account_delete", user.id, max_attempts=10)
    db.add(AuditEvent(user_id=None, action="account_deletion_requested", detail={"job_id": str(job.id)}))
    db.commit()
    return jobs.job_out(job)
