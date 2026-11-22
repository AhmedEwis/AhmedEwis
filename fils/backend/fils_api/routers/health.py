from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from sqlalchemy import text

from ..db import get_engine

router = APIRouter(tags=["health"])

ALEMBIC_INI = Path(__file__).resolve().parents[2] / "alembic.ini"


def alembic_head() -> str | None:
    from alembic.config import Config
    from alembic.script import ScriptDirectory

    cfg = Config(str(ALEMBIC_INI))
    cfg.set_main_option("script_location", str(ALEMBIC_INI.parent / "alembic"))
    return ScriptDirectory.from_config(cfg).get_current_head()


@router.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.get("/readyz")
def readyz():
    try:
        with get_engine().connect() as conn:
            conn.execute(text("SELECT 1"))
            current = conn.execute(text("SELECT version_num FROM alembic_version")).scalar()
    except Exception:  # noqa: BLE001
        return JSONResponse({"status": "unavailable", "database": False}, status_code=503)
    head = alembic_head()
    if current != head:
        return JSONResponse({"status": "migrations_pending", "database": True, "current": current, "head": head}, status_code=503)
    return {"status": "ready", "database": True, "migration": current}
