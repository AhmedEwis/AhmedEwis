from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from ..db import get_db
from ..security import CurrentUser, get_current_user
from ..services import sync as sync_service
from ..services.consents import require_consent

router = APIRouter(prefix="/v1/sync", tags=["sync"])


class PushIn(BaseModel):
    device_id: str = Field(min_length=1, max_length=128)
    ops: list[dict[str, Any]] = Field(max_length=500)


@router.post("/push")
def push(body: PushIn, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    require_consent(db, current.id, "cloud_sync", "cloud_backup")
    out = sync_service.push(db, current.id, body.device_id, body.ops)
    db.commit()
    return out


@router.get("/pull")
def pull(
    cursor: str | None = Query(default=None, max_length=200),
    limit: int = Query(default=500, ge=1, le=500),
    current: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    require_consent(db, current.id, "cloud_sync", "cloud_backup")
    return sync_service.pull(db, current.id, cursor, limit)
