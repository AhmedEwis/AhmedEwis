"""User data export: a ZIP with full JSON plus CSVs safe to open in spreadsheet apps."""
from __future__ import annotations

import csv
import io
import json
import uuid
import zipfile
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import ConsentRecord, Entitlement, HouseholdMember, SyncRecord, User
from .textguard import eff_exponent

FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r", "\n", "|", "%")


def csv_safe(value) -> str:
    """Neutralise spreadsheet formula injection (CWE-1236)."""
    if value is None:
        return ""
    s = str(value)
    if s and (s[0] in FORMULA_PREFIXES or s.lstrip()[:1] in ("=", "+", "@")):
        return "'" + s
    return s


def format_minor(minor: int | None, currency: str | None) -> str:
    if minor is None or not currency:
        return ""
    exp = eff_exponent(currency)
    sign = "-" if minor < 0 else ""
    m = abs(int(minor))
    if exp == 0:
        return f"{sign}{m}"
    return f"{sign}{m // 10**exp}.{m % 10**exp:0{exp}d}"


def build_export(db: Session, user_id: uuid.UUID) -> bytes:
    user = db.get(User, user_id)
    records = db.scalars(
        select(SyncRecord).where(SyncRecord.owner_user_id == user_id, SyncRecord.deleted.is_(False)).order_by(SyncRecord.entity)
    ).all()
    consents = db.scalars(select(ConsentRecord).where(ConsentRecord.user_id == user_id).order_by(ConsentRecord.seq)).all()
    ent = db.get(Entitlement, user_id)
    memberships = db.scalars(select(HouseholdMember).where(HouseholdMember.user_id == user_id)).all()

    doc = {
        "exported_at": datetime.now(UTC).isoformat(),
        "format": "fils-export-v1",
        "note": "Amounts are integer minor units (KWD: 1000 fils = 1 dinar).",
        "user": {"id": str(user.id), "display_name": user.display_name, "email": user.email, "locale": user.locale,
                 "created_at": user.created_at.isoformat()},
        "consents": [{"kind": c.kind, "granted": c.granted, "policy_version": c.policy_version, "at": c.created_at.isoformat()} for c in consents],
        "entitlement": None if ent is None else {"plan": ent.plan, "source": ent.source, "expires_at": ent.expires_at.isoformat() if ent.expires_at else None},
        "households": [{"household_id": str(m.household_id), "role": m.role} for m in memberships],
        "records": {},
    }
    for r in records:
        doc["records"].setdefault(r.entity, []).append({"id": str(r.id), "version": r.version, **r.payload})

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("fils-export.json", json.dumps(doc, ensure_ascii=False, indent=2))
        tx = doc["records"].get("transaction", [])
        cats = {c["id"]: c for c in doc["records"].get("category", [])}
        accts = {a["id"]: a for a in doc["records"].get("account", [])}
        out = io.StringIO()
        w = csv.writer(out)
        w.writerow(["date", "account", "kind", "status", "amount", "currency", "merchant", "category", "note", "source"])
        for t in tx:
            w.writerow(
                [
                    csv_safe(t.get("occurred_at")),
                    csv_safe(accts.get(t.get("account_id"), {}).get("name")),
                    csv_safe(t.get("kind")),
                    csv_safe(t.get("status")),
                    format_minor(t.get("amount_minor"), t.get("currency")),
                    csv_safe(t.get("currency")),
                    csv_safe(t.get("merchant")),
                    csv_safe(cats.get(t.get("category_id"), {}).get("name_en") or t.get("category_id")),
                    csv_safe(t.get("note")),
                    csv_safe(t.get("source")),
                ]
            )
        z.writestr("transactions.csv", "﻿" + out.getvalue())
        out = io.StringIO()
        w = csv.writer(out)
        w.writerow(["name", "kind", "currency", "opening_balance", "archived"])
        for a in accts.values():
            w.writerow([csv_safe(a.get("name")), csv_safe(a.get("kind")), csv_safe(a.get("currency")),
                        format_minor(a.get("opening_balance_minor"), a.get("currency")), a.get("archived")])
        z.writestr("accounts.csv", "﻿" + out.getvalue())
    return buf.getvalue()
