from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session

from ..config import get_settings
from ..db import get_db
from ..security import CurrentUser, get_current_user
from ..services.consents import require_consent

router = APIRouter(prefix="/v1/voice", tags=["voice"])


@router.get("/config")
def voice_config(request: Request, current: CurrentUser = Depends(get_current_user)):
    s = get_settings()
    sp = request.app.state.speech
    return {
        "enabled": sp.enabled,
        "provider": sp.name,
        "stt_locales": s.speech_stt_locales,
        "tts_voices": {"ar": s.speech_tts_voice_ar, "en": s.speech_tts_voice_en},
    }


@router.post("/token")
def voice_token(request: Request, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    require_consent(db, current.id, "cloud_voice")
    tok = request.app.state.speech.issue_token()
    return {
        "provider": tok.provider,
        "region": tok.region,
        "token": tok.token,
        "expires_at": datetime.fromtimestamp(tok.expires_at, UTC).isoformat(),
    }
