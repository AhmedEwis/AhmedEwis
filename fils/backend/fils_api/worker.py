"""Background worker: `python -m fils_api.worker`. Safe to run several replicas (SKIP LOCKED)."""
from __future__ import annotations

import logging
import os
import signal
import socket
import time
import uuid
from datetime import timedelta

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from .config import get_settings
from .db import get_sessionmaker
from .logging_setup import setup_logging
from .models import (
    AIUsage,
    AuditEvent,
    AuthNonce,
    BillingEvent,
    ConsentRecord,
    DeviceSession,
    Entitlement,
    Household,
    HouseholdInvitation,
    HouseholdMember,
    IdempotencyKey,
    Job,
    ParserSample,
    PurchaseLink,
    RefreshToken,
    SyncRecord,
    TempBlob,
    User,
    AuthIdentity,
)
from .providers.documents import ProviderNotConfigured, build_ocr
from .security import now
from .services import jobs
from .services.blobs import read_blob, store_blob
from .services.documents import extract_csv, extract_lines, extract_pdf
from .services.exporter import build_export

log = logging.getLogger("fils.worker")


class PermanentJobError(Exception):
    pass


def handle_export(db: Session, job: Job) -> dict:
    data = build_export(db, job.user_id)
    blob = store_blob(db, job.user_id, "export", f"fils-export-{now().date().isoformat()}.zip", "application/zip", data)
    return {"blob_id": str(blob.id), "bytes": len(data)}


def handle_account_delete(db: Session, job: Job) -> dict:
    uid = job.user_id
    user = db.get(User, uid)
    if user is None:
        return {"deleted": True, "already": True}
    owned = [h.id for h in db.scalars(select(Household).where(Household.owner_user_id == uid))]
    if owned:
        db.execute(delete(SyncRecord).where(SyncRecord.household_id.in_(owned)))
        db.execute(delete(Household).where(Household.id.in_(owned)))
    counts = {}
    for model, col in (
        (SyncRecord, SyncRecord.owner_user_id),
        (TempBlob, TempBlob.user_id),
        (ParserSample, ParserSample.user_id),
        (ConsentRecord, ConsentRecord.user_id),
        (AIUsage, AIUsage.user_id),
        (PurchaseLink, PurchaseLink.user_id),
        (Entitlement, Entitlement.user_id),
        (HouseholdMember, HouseholdMember.user_id),
        (HouseholdInvitation, HouseholdInvitation.created_by),
        (AuditEvent, AuditEvent.user_id),
        (AuthIdentity, AuthIdentity.user_id),
    ):
        counts[model.__tablename__] = db.execute(delete(model).where(col == uid)).rowcount
    sess_ids = [s.id for s in db.scalars(select(DeviceSession).where(DeviceSession.user_id == uid))]
    if sess_ids:
        db.execute(delete(RefreshToken).where(RefreshToken.session_id.in_(sess_ids)))
        db.execute(delete(DeviceSession).where(DeviceSession.id.in_(sess_ids)))
    db.execute(delete(IdempotencyKey).where(IdempotencyKey.scope == f"user:{uid}"))
    db.execute(delete(Job).where(Job.user_id == uid, Job.id != job.id))
    db.delete(user)
    db.add(AuditEvent(user_id=None, action="account_deleted", detail={"job_id": str(job.id)}))
    return {"deleted": True, "counts": counts}


def handle_document(db: Session, job: Job) -> dict:
    blob = db.get(TempBlob, uuid.UUID(job.payload["blob_id"]))
    if blob is None or blob.user_id != job.user_id:
        raise PermanentJobError("upload_missing")
    data = read_blob(blob)
    kind = job.payload.get("kind")
    try:
        if kind == "csv":
            rows = extract_csv(data)
        elif kind == "pdf":
            rows = extract_pdf(data)
            if not rows:
                raise PermanentJobError("no_transactions_found_in_pdf")
        elif kind == "image":
            text = build_ocr(get_settings()).read_text(data, blob.content_type)
            rows = extract_lines(text)
        else:
            raise PermanentJobError("unsupported_kind")
    except ProviderNotConfigured as e:
        raise PermanentJobError("provider_not_configured") from e
    except ValueError as e:
        raise PermanentJobError(str(e) or "unreadable_document") from e
    finally:
        db.delete(blob)  # never keep the upload after processing
    return {"candidates": rows, "count": len(rows)}


def run_retention(db: Session) -> dict:
    s = get_settings()
    t = now()
    out = {
        "blobs": db.execute(delete(TempBlob).where(TempBlob.expires_at < t)).rowcount,
        "nonces": db.execute(delete(AuthNonce).where(AuthNonce.expires_at < t - timedelta(hours=1))).rowcount,
        "idempotency": db.execute(delete(IdempotencyKey).where(IdempotencyKey.created_at < t - timedelta(hours=24))).rowcount,
        "refresh_tokens": db.execute(delete(RefreshToken).where(RefreshToken.expires_at < t)).rowcount,
        "invitations": db.execute(delete(HouseholdInvitation).where(HouseholdInvitation.expires_at < t - timedelta(days=30))).rowcount,
        "billing_events": db.execute(delete(BillingEvent).where(BillingEvent.received_at < t - timedelta(days=180))).rowcount,
    }
    # Document candidates contain financial data: drop results after the blob TTL.
    out["document_results"] = db.execute(
        update(Job)
        .where(Job.kind == "document_extract", Job.finished_at < t - timedelta(hours=s.temp_blob_ttl_hours), Job.result.is_not(None))
        .values(result=None)
    ).rowcount
    out["old_jobs"] = db.execute(delete(Job).where(Job.finished_at < t - timedelta(days=30))).rowcount
    return out


HANDLERS = {"export": handle_export, "account_delete": handle_account_delete, "document_extract": handle_document}


def run_once(worker_id: str = "worker") -> bool:
    """Process at most one job. Returns True if a job was processed."""
    Session = get_sessionmaker()
    with Session() as db:
        job = jobs.claim_next(db, worker_id)
        db.commit()
        if job is None:
            return False
        job_id = job.id
    with Session() as db:
        job = db.get(Job, job_id)
        handler = HANDLERS.get(job.kind)
        try:
            if handler is None:
                raise PermanentJobError(f"unknown job kind {job.kind}")
            result = handler(db, job)
            jobs.complete(db, job, result)
            db.commit()
            log.info("job_succeeded", extra={"job_id": str(job_id), "job_kind": job.kind})
        except PermanentJobError as e:
            db.rollback()
            job = db.get(Job, job_id)
            if job.kind == "document_extract":
                db.execute(delete(TempBlob).where(TempBlob.id == uuid.UUID(job.payload["blob_id"])))
            jobs.fail(db, job, str(e), permanent=True)
            db.commit()
            log.warning("job_failed_permanently", extra={"job_id": str(job_id), "job_kind": job.kind})
        except Exception as e:  # noqa: BLE001
            db.rollback()
            job = db.get(Job, job_id)
            jobs.fail(db, job, type(e).__name__)
            db.commit()
            log.exception("job_failed", extra={"job_id": str(job_id), "job_kind": job.kind})
    return True


def main() -> None:
    s = get_settings()
    setup_logging(s.log_level)
    worker_id = f"{socket.gethostname()}-{os.getpid()}"
    stop = {"flag": False}

    def _stop(*_):
        stop["flag"] = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    last_retention = 0.0
    log.info("worker_started")
    while not stop["flag"]:
        if time.time() - last_retention > 3600:
            with get_sessionmaker()() as db:
                res = run_retention(db)
                db.commit()
            log.info(f"retention {res}")
            last_retention = time.time()
        if not run_once(worker_id):
            time.sleep(s.worker_poll_seconds)
    log.info("worker_stopped")


if __name__ == "__main__":
    main()
