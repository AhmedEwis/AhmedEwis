"""Versioned sync with conflicts, tombstones and household scoping.

Ordering guarantee: pushes take a transaction-scoped advisory lock before allocating
change sequence numbers, so commit order == change_seq order and a pull cursor can never
skip a record that commits later with a lower sequence. This serialises pushes globally,
which is acceptable at the expected scale (documented in docs/backend.md).
"""
from __future__ import annotations

import base64
import uuid
from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from sqlalchemy import or_, select, text
from sqlalchemy.orm import Session

from ..errors import APIError
from ..models import HouseholdMember, SyncRecord
from ..security import now
from .sync_schemas import ENTITY_MODELS, ENTITY_ORDER, REFERENCES, SYSTEM_CATEGORY_SLUG

SYNC_LOCK_KEY = 0x46494C53  # "FILS"


class Envelope(BaseModel):
    model_config = ConfigDict(extra="forbid")
    entity: str
    id: uuid.UUID
    version: int | None = None
    base_version: int = Field(ge=0)
    deleted: bool = False
    updated_at: datetime | None = None
    household_id: uuid.UUID | None = None
    payload: dict[str, Any] = Field(default_factory=dict)


def encode_cursor(seq: int) -> str:
    return base64.urlsafe_b64encode(f"v1:{seq}".encode()).decode()


def decode_cursor(cursor: str | None) -> int:
    if not cursor:
        return 0
    try:
        raw = base64.urlsafe_b64decode(cursor.encode()).decode()
        prefix, seq = raw.split(":", 1)
        if prefix != "v1":
            raise ValueError
        return int(seq)
    except Exception as e:  # noqa: BLE001
        raise APIError(400, "invalid_cursor", "Cursor is invalid") from e


def membership_roles(db: Session, user_id: uuid.UUID) -> dict[uuid.UUID, str]:
    return {m.household_id: m.role for m in db.scalars(select(HouseholdMember).where(HouseholdMember.user_id == user_id))}


def record_out(r: SyncRecord) -> dict:
    return {
        "entity": r.entity,
        "id": str(r.id),
        "version": r.version,
        "deleted": r.deleted,
        "updated_at": (r.client_updated_at or r.server_updated_at).isoformat(),
        "server_updated_at": r.server_updated_at.isoformat(),
        "household_id": str(r.household_id) if r.household_id else None,
        "payload": r.payload,
    }


def _in_scope(rec: SyncRecord, user_id: uuid.UUID, roles: dict[uuid.UUID, str]) -> bool:
    if rec.household_id is not None:
        return rec.household_id in roles
    return rec.owner_user_id == user_id


def _check_refs(db: Session, entity: str, payload: dict, scope_owner: uuid.UUID, household_id: uuid.UUID | None) -> str | None:
    refs = list(REFERENCES.get(entity, []))
    values: list[tuple[str, str]] = []
    for field, ref_entity in refs:
        v = payload.get(field)
        if v:
            values.append((str(v), ref_entity))
    if entity == "transaction":
        for sp in payload.get("splits") or []:
            values.append((str(sp["category_id"]), "category"))
    for ref_id, ref_entity in values:
        if ref_entity == "category" and SYSTEM_CATEGORY_SLUG.fullmatch(ref_id):
            continue  # built-in system category, present on every device
        rec = db.get(SyncRecord, (ref_entity, uuid.UUID(ref_id)))
        if rec is None:
            return f"{ref_entity}:{ref_id} not found"
        if household_id is not None:
            # Household records may reference household records, or (for categories) the pusher's own.
            if rec.household_id != household_id and not (rec.household_id is None and rec.owner_user_id == scope_owner):
                return f"{ref_entity}:{ref_id} is outside this scope"
        elif rec.household_id is not None or rec.owner_user_id != scope_owner:
            return f"{ref_entity}:{ref_id} is outside this scope"
    return None


def push(db: Session, user_id: uuid.UUID, device_id: str, ops: list[dict]) -> dict:
    db.execute(text("SELECT pg_advisory_xact_lock(:k)"), {"k": SYNC_LOCK_KEY})
    roles = membership_roles(db, user_id)
    results: list[dict | None] = [None] * len(ops)

    parsed: list[tuple[int, Envelope]] = []
    for i, raw in enumerate(ops):
        try:
            env = Envelope.model_validate(raw)
        except ValidationError:
            results[i] = {"id": str(raw.get("id")), "entity": raw.get("entity"), "status": "rejected", "error": {"code": "invalid_envelope"}}
            continue
        if env.entity not in ENTITY_MODELS:
            results[i] = {"id": str(env.id), "entity": env.entity, "status": "rejected", "error": {"code": "unknown_entity"}}
            continue
        parsed.append((i, env))

    order = {e: n for n, e in enumerate(ENTITY_ORDER)}
    parsed.sort(key=lambda t: (order[t[1].entity], t[0]))

    for i, env in parsed:
        results[i] = _apply(db, user_id, device_id, roles, env)

    # Push does not advance the pull cursor: other devices' changes may be interleaved.
    return {"results": results, "cursor": None}


def _rej(env: Envelope, code: str, message: str = "") -> dict:
    return {"id": str(env.id), "entity": env.entity, "status": "rejected", "error": {"code": code, "message": message}}


def _apply(db: Session, user_id: uuid.UUID, device_id: str, roles: dict, env: Envelope) -> dict:
    if env.household_id is not None:
        role = roles.get(env.household_id)
        if role is None:
            return _rej(env, "forbidden", "Not a member of this household")
        if role == "viewer":
            return _rej(env, "forbidden", "Viewers cannot modify shared data")

    existing = db.get(SyncRecord, (env.entity, env.id), with_for_update=True)
    if existing is not None and not _in_scope(existing, user_id, roles):
        # Do not reveal anything about records owned by someone else.
        return _rej(env, "invalid_id", "Record id is not available")
    if existing is not None and existing.household_id != env.household_id:
        return _rej(env, "scope_change_not_allowed", "Records cannot move between personal and household scope")

    if existing is not None and existing.deleted:
        if env.deleted:
            return {"id": str(env.id), "entity": env.entity, "status": "applied", "server_version": existing.version}
        return _rej(env, "tombstoned", "Record was deleted and cannot be recreated")

    current_version = existing.version if existing else 0
    if env.base_version != current_version:
        if existing is None:
            return _rej(env, "not_found", "Record does not exist on server")
        return {
            "id": str(env.id),
            "entity": env.entity,
            "status": "conflict",
            "server_version": existing.version,
            "server_record": record_out(existing),
        }

    if env.deleted:
        if existing is None:
            # Tombstone for a record the server never saw: store it so it can't be created later.
            payload: dict = {}
        else:
            payload = {}
    else:
        model = ENTITY_MODELS[env.entity]
        body = dict(env.payload)
        body["id"] = str(env.id)
        try:
            validated = model.model_validate(body)
        except (ValidationError, ValueError) as e:
            errs = e.errors() if isinstance(e, ValidationError) else [{"msg": str(e)}]
            safe = [{"loc": list(x.get("loc", [])), "msg": x.get("msg")} for x in errs][:10]
            return {**_rej(env, "invalid_payload", "Payload failed validation"), "error": {"code": "invalid_payload", "details": safe}}
        payload = validated.model_dump(mode="json")
        scope_owner = existing.owner_user_id if existing else user_id
        ref_err = _check_refs(db, env.entity, payload, scope_owner, env.household_id)
        if ref_err:
            return _rej(env, "invalid_reference", ref_err)

    seq = db.execute(text("SELECT nextval('sync_change_seq')")).scalar_one()
    if existing is None:
        rec = SyncRecord(
            entity=env.entity,
            id=env.id,
            owner_user_id=user_id,
            household_id=env.household_id,
            version=1,
            deleted=env.deleted,
            payload=payload,
            client_updated_at=env.updated_at,
            server_updated_at=now(),
            change_seq=seq,
            last_device_id=device_id,
        )
        db.add(rec)
    else:
        rec = existing
        rec.version = existing.version + 1
        rec.deleted = env.deleted
        rec.payload = payload
        rec.client_updated_at = env.updated_at
        rec.server_updated_at = now()
        rec.change_seq = seq
        rec.last_device_id = device_id
    db.flush()
    return {"id": str(env.id), "entity": env.entity, "status": "applied", "server_version": rec.version}


def pull(db: Session, user_id: uuid.UUID, cursor: str | None, limit: int) -> dict:
    since = decode_cursor(cursor)
    roles = membership_roles(db, user_id)
    conds = [(SyncRecord.owner_user_id == user_id) & (SyncRecord.household_id.is_(None))]
    if roles:
        conds.append(SyncRecord.household_id.in_(list(roles.keys())))
    rows = db.scalars(
        select(SyncRecord)
        .where(or_(*conds), SyncRecord.change_seq > since)
        .order_by(SyncRecord.change_seq.asc())
        .limit(limit + 1)
    ).all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    new_cursor = rows[-1].change_seq if rows else since
    return {"records": [record_out(r) for r in rows], "cursor": encode_cursor(new_cursor), "has_more": has_more}
