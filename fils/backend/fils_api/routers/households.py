from __future__ import annotations

import secrets
import uuid
from datetime import timedelta
from typing import Literal

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel, Field
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from ..db import get_db
from ..errors import APIError
from ..models import AuditEvent, Household, HouseholdInvitation, HouseholdMember, SyncRecord, User
from ..security import CurrentUser, get_current_user, now, sha256_hex

router = APIRouter(prefix="/v1/households", tags=["households"])

CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no ambiguous chars
MAX_MEMBERS = 12


class HouseholdIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)


class InviteIn(BaseModel):
    role: Literal["member", "viewer"] = "member"
    expires_in_hours: int = Field(default=72, ge=1, le=24 * 14)


class JoinIn(BaseModel):
    code: str = Field(min_length=6, max_length=40)


def _norm_code(code: str) -> str:
    return "".join(ch for ch in code.upper() if ch.isalnum())


def _membership(db: Session, household_id: uuid.UUID, user_id: uuid.UUID) -> HouseholdMember | None:
    return db.get(HouseholdMember, (household_id, user_id))


def _household_out(db: Session, h: Household, me: uuid.UUID) -> dict:
    members = db.scalars(select(HouseholdMember).where(HouseholdMember.household_id == h.id)).all()
    out_members = []
    for m in members:
        u = db.get(User, m.user_id)
        out_members.append(
            {"user_id": str(m.user_id), "role": m.role, "display_name": u.display_name if u else None, "joined_at": m.joined_at.isoformat()}
        )
    my_role = next((m.role for m in members if m.user_id == me), None)
    return {"id": str(h.id), "name": h.name, "owner_user_id": str(h.owner_user_id), "my_role": my_role, "members": out_members}


@router.post("", status_code=201)
def create_household(body: HouseholdIn, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    h = Household(name=body.name, owner_user_id=current.id)
    db.add(h)
    db.flush()
    db.add(HouseholdMember(household_id=h.id, user_id=current.id, role="owner"))
    db.add(AuditEvent(user_id=current.id, action="household_created", detail={"household_id": str(h.id)}))
    db.commit()
    return _household_out(db, h, current.id)


@router.get("")
def list_households(current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    ids = [m.household_id for m in db.scalars(select(HouseholdMember).where(HouseholdMember.user_id == current.id))]
    return [_household_out(db, db.get(Household, i), current.id) for i in ids]


@router.post("/{household_id}/invitations", status_code=201)
def invite(household_id: uuid.UUID, body: InviteIn, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    m = _membership(db, household_id, current.id)
    if m is None:
        raise APIError(404, "not_found", "Household not found")
    if m.role != "owner":
        raise APIError(403, "forbidden", "Only the owner can invite")
    code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(10))
    inv = HouseholdInvitation(
        household_id=household_id,
        code_hash=sha256_hex(code),
        role=body.role,
        created_by=current.id,
        expires_at=now() + timedelta(hours=body.expires_in_hours),
    )
    db.add(inv)
    db.add(AuditEvent(user_id=current.id, action="household_invite_created", detail={"household_id": str(household_id), "role": body.role}))
    db.commit()
    pretty = f"{code[:5]}-{code[5:]}"
    return {"invitation_id": str(inv.id), "code": pretty, "role": inv.role, "expires_at": inv.expires_at.isoformat()}


@router.post("/join")
def join(body: JoinIn, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    h = sha256_hex(_norm_code(body.code))
    inv = db.scalar(select(HouseholdInvitation).where(HouseholdInvitation.code_hash == h).with_for_update())
    if inv is None or inv.revoked_at is not None or inv.used_at is not None or inv.expires_at <= now():
        raise APIError(404, "invalid_invitation", "Invitation code is invalid or expired")
    if _membership(db, inv.household_id, current.id) is not None:
        raise APIError(409, "already_member", "Already a member")
    count = len(db.scalars(select(HouseholdMember).where(HouseholdMember.household_id == inv.household_id)).all())
    if count >= MAX_MEMBERS:
        raise APIError(409, "household_full", "Household is full")
    inv.used_at = now()
    inv.used_by = current.id
    mem = HouseholdMember(household_id=inv.household_id, user_id=current.id, role=inv.role)
    db.add(mem)
    db.add(AuditEvent(user_id=current.id, action="household_joined", detail={"household_id": str(inv.household_id), "role": inv.role}))
    db.commit()
    return {"household_id": str(inv.household_id), "user_id": str(current.id), "role": mem.role}


@router.delete("/{household_id}/members/{user_id}", status_code=204)
def remove_member(household_id: uuid.UUID, user_id: uuid.UUID, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    me = _membership(db, household_id, current.id)
    if me is None:
        raise APIError(404, "not_found", "Household not found")
    target = _membership(db, household_id, user_id)
    if target is None:
        raise APIError(404, "not_found", "Member not found")
    if user_id != current.id and me.role != "owner":
        raise APIError(403, "forbidden", "Only the owner can remove members")
    if target.role == "owner":
        # Owner leaving dissolves the household (shared copies are deleted; personal data untouched).
        if user_id != current.id:
            raise APIError(403, "forbidden", "Owner cannot be removed")
        db.execute(delete(SyncRecord).where(SyncRecord.household_id == household_id))
        db.execute(delete(Household).where(Household.id == household_id))
        db.add(AuditEvent(user_id=current.id, action="household_dissolved", detail={"household_id": str(household_id)}))
    else:
        db.delete(target)
        db.add(AuditEvent(user_id=current.id, action="household_member_removed", detail={"household_id": str(household_id), "user_id": str(user_id)}))
    db.commit()
    return Response(status_code=204)


@router.delete("/{household_id}/invitations/{invitation_id}", status_code=204)
def revoke_invitation(household_id: uuid.UUID, invitation_id: uuid.UUID, current: CurrentUser = Depends(get_current_user), db: Session = Depends(get_db)):
    me = _membership(db, household_id, current.id)
    if me is None or me.role != "owner":
        raise APIError(404, "not_found", "Invitation not found")
    inv = db.get(HouseholdInvitation, invitation_id)
    if inv is None or inv.household_id != household_id:
        raise APIError(404, "not_found", "Invitation not found")
    if inv.revoked_at is None:
        inv.revoked_at = now()
        db.commit()
    return Response(status_code=204)
