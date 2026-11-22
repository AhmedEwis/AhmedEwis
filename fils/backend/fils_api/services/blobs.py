"""AES-256-GCM encrypted temporary blobs (uploads awaiting extraction, export archives)."""
from __future__ import annotations

import os
import uuid
from datetime import timedelta

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from sqlalchemy.orm import Session

from ..config import get_settings
from ..models import TempBlob
from ..security import now


def _aad(blob_id: uuid.UUID, user_id: uuid.UUID) -> bytes:
    return f"{blob_id}:{user_id}".encode()


def store_blob(db: Session, user_id: uuid.UUID, purpose: str, filename: str, content_type: str, data: bytes) -> TempBlob:
    s = get_settings()
    blob_id = uuid.uuid4()
    nonce = os.urandom(12)
    ct = AESGCM(s.effective_data_key()).encrypt(nonce, data, _aad(blob_id, user_id))
    blob = TempBlob(
        id=blob_id,
        user_id=user_id,
        purpose=purpose,
        filename=filename[:200],
        content_type=content_type[:100],
        data=nonce + ct,
        expires_at=now() + timedelta(hours=s.temp_blob_ttl_hours),
    )
    db.add(blob)
    db.flush()
    return blob


def read_blob(blob: TempBlob) -> bytes:
    s = get_settings()
    raw = bytes(blob.data)
    return AESGCM(s.effective_data_key()).decrypt(raw[:12], raw[12:], _aad(blob.id, blob.user_id))
