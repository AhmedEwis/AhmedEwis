"""Durable Postgres job queue (FOR UPDATE SKIP LOCKED), with retries, backoff and dead-lettering."""
from __future__ import annotations

import uuid
from datetime import timedelta

from sqlalchemy import select, text, update
from sqlalchemy.orm import Session

from ..config import get_settings
from ..models import Job
from ..security import now


def enqueue(db: Session, kind: str, user_id: uuid.UUID | None, payload: dict | None = None, max_attempts: int | None = None) -> Job:
    job = Job(
        kind=kind,
        user_id=user_id,
        payload=payload or {},
        status="queued",
        max_attempts=max_attempts or get_settings().job_max_attempts,
        run_after=now(),
    )
    db.add(job)
    db.flush()
    return job


def job_out(job: Job) -> dict:
    result_url = None
    if job.status == "succeeded" and job.kind == "export" and job.result and job.result.get("blob_id"):
        result_url = f"/v1/jobs/{job.id}/download"
    result = None
    if job.status == "succeeded" and job.kind == "document_extract":
        result = job.result
    return {
        "id": str(job.id),
        "kind": job.kind,
        "status": job.status,
        "result_url": result_url,
        "result": result,
        "error": job.error if job.status == "failed" else None,
        "created_at": job.created_at.isoformat() if job.created_at else None,
    }


def claim_next(db: Session, worker_id: str) -> Job | None:
    """Atomically claim one runnable job. Must be called inside a transaction; caller commits."""
    s = get_settings()
    # Recover jobs whose worker died mid-run.
    db.execute(
        update(Job)
        .where(Job.status == "running", Job.locked_at < now() - timedelta(minutes=s.job_stale_minutes))
        .values(status="queued", locked_at=None, locked_by=None)
    )
    row = db.execute(
        text(
            """
            SELECT id FROM jobs
            WHERE status = 'queued' AND run_after <= now()
            ORDER BY run_after, created_at
            FOR UPDATE SKIP LOCKED
            LIMIT 1
            """
        )
    ).first()
    if row is None:
        return None
    job = db.get(Job, row[0])
    job.status = "running"
    job.attempts += 1
    job.locked_at = now()
    job.locked_by = worker_id
    db.flush()
    return job


def complete(db: Session, job: Job, result: dict | None) -> None:
    job.status = "succeeded"
    job.result = result
    job.error = None
    job.finished_at = now()
    job.locked_at = None


def fail(db: Session, job: Job, error: str, permanent: bool = False) -> None:
    job.error = error[:2000]
    job.locked_at = None
    job.locked_by = None
    if permanent or job.attempts >= job.max_attempts:
        job.status = "failed"  # dead letter: kept for inspection
        job.finished_at = now()
    else:
        job.status = "queued"
        job.run_after = now() + timedelta(seconds=min(3600, 10 * (2 ** (job.attempts - 1))))


def get_owned_job(db: Session, job_id: uuid.UUID, user_id: uuid.UUID) -> Job | None:
    return db.scalar(select(Job).where(Job.id == job_id, Job.user_id == user_id))
