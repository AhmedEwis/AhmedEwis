from __future__ import annotations

import csv
import io
import json
import zipfile

from conftest import auth, grant, new_id, reauth_header, sign_in
from sqlalchemy import func, select
from test_sync import account, push, tx

from fils_api.db import get_sessionmaker
from fils_api.models import Job, SyncRecord, TempBlob, User
from fils_api.services import jobs as jobsvc
from fils_api.services.exporter import csv_safe
from fils_api.worker import run_once, run_retention


def test_export_requires_reauth_and_escapes_formulas(client, rsa_keys):
    a = sign_in(client, rsa_keys, "exp-1")
    grant(client, a, "cloud_sync")
    aid = new_id()
    push(client, a, [account(aid, name="=HYPERLINK(\"http://evil\")"), tx(new_id(), aid, merchant="+cmd|' /C calc'!A0", note="@SUM(1)")])
    assert client.post("/v1/me/export", headers=auth(a)).status_code == 403
    h = reauth_header(client, rsa_keys, a, "exp-1")
    job = client.post("/v1/me/export", headers=h).json()
    assert job["status"] == "queued"
    assert run_once() is True
    j = client.get(f"/v1/jobs/{job['id']}", headers=auth(a)).json()
    assert j["status"] == "succeeded" and j["result_url"]
    r = client.get(j["result_url"], headers=auth(a))
    assert r.status_code == 200 and r.headers["content-type"] == "application/zip"
    z = zipfile.ZipFile(io.BytesIO(r.content))
    data = json.loads(z.read("fils-export.json"))
    assert data["records"]["transaction"][0]["amount_minor"] == 5250
    rows = list(csv.reader(io.StringIO(z.read("transactions.csv").decode("utf-8-sig"))))
    assert rows[1][4] == "5.250"  # KWD three decimals
    assert rows[1][1].startswith("'=") and rows[1][6].startswith("'+") and rows[1][8].startswith("'@")
    # another user cannot read the job or download the file
    b = sign_in(client, rsa_keys, "exp-2")
    assert client.get(f"/v1/jobs/{job['id']}", headers=auth(b)).status_code == 404
    assert client.get(j["result_url"], headers=auth(b)).status_code == 404


def test_csv_safe_unit():
    assert csv_safe("=1+1") == "'=1+1"
    assert csv_safe("-5") == "'-5"
    assert csv_safe("  =cmd") == "'  =cmd"
    assert csv_safe("Talabat") == "Talabat"
    assert csv_safe(None) == ""


def test_account_deletion_removes_everything(client, rsa_keys):
    a = sign_in(client, rsa_keys, "del-1")
    b = sign_in(client, rsa_keys, "del-2")
    grant(client, a, "cloud_sync")
    grant(client, b, "cloud_sync")
    aid = new_id()
    push(client, a, [account(aid)])
    push(client, b, [account(new_id(), name="B keeps this")])
    hid = client.post("/v1/households", headers=auth(a), json={"name": "A home"}).json()["id"]
    assert client.delete("/v1/me", headers=auth(a)).status_code == 403  # needs reauth
    h = reauth_header(client, rsa_keys, a, "del-1")
    job = client.delete("/v1/me", headers=h)
    assert job.status_code == 202
    # sessions revoked immediately
    assert client.get("/v1/me", headers=auth(a)).status_code == 401
    assert client.post("/v1/auth/refresh", json={"refresh_token": a["refresh_token"]}).status_code == 401
    assert run_once() is True
    with get_sessionmaker()() as db:
        assert db.get(User, __import__("uuid").UUID(a["user"]["id"])) is None
        assert db.scalar(select(func.count()).select_from(SyncRecord).where(SyncRecord.id == __import__("uuid").UUID(aid))) == 0
        j = db.get(Job, __import__("uuid").UUID(job.json()["id"]))
        assert j.status == "succeeded"
    # other user's data untouched
    assert [r["payload"]["name"] for r in client.get("/v1/sync/pull", headers=auth(b)).json()["records"]] == ["B keeps this"]
    # signing in again with the same provider identity creates a fresh, empty account
    again = sign_in(client, rsa_keys, "del-1")
    assert again["is_new_user"] is True and again["user"]["id"] != a["user"]["id"]
    assert hid  # household dissolved with the owner


def test_document_csv_extraction_and_blob_cleanup(client, rsa_keys):
    a = sign_in(client, rsa_keys, "doc-1")
    content = "Date,Description,Debit,Credit\n22/11/2026,TALABAT KUWAIT,5.250,\n25/11/2026,SALARY,,1500.000\n".encode()
    r = client.post("/v1/ingest/document", headers=auth(a), files={"file": ("statement.csv", content, "text/csv")})
    assert r.status_code == 202, r.text
    job_id = r.json()["id"]
    assert run_once()
    j = client.get(f"/v1/jobs/{job_id}", headers=auth(a)).json()
    assert j["status"] == "succeeded"
    c = j["result"]["candidates"]
    assert c[0] == {"occurred_on": "2026-11-22", "description": "TALABAT KUWAIT", "amount_minor": 5250, "currency": "KWD",
                    "direction": "debit", "needs_review": False}
    assert c[1]["amount_minor"] == 1_500_000 and c[1]["direction"] == "credit"
    with get_sessionmaker()() as db:
        assert db.scalar(select(func.count()).select_from(TempBlob)) == 0  # upload deleted after processing


def test_image_without_ocr_provider_fails_cleanly(client, rsa_keys):
    a = sign_in(client, rsa_keys, "doc-2")
    grant(client, a, "cloud_ai")
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 100
    r = client.post("/v1/ingest/document", headers=auth(a), files={"file": ("s.png", png, "image/png")})
    assert r.status_code == 202
    run_once()
    j = client.get(f"/v1/jobs/{r.json()['id']}", headers=auth(a)).json()
    assert j["status"] == "failed" and j["error"] == "provider_not_configured"
    with get_sessionmaker()() as db:
        assert db.scalar(select(func.count()).select_from(TempBlob)) == 0


def test_job_retry_backoff_and_dead_letter():
    with get_sessionmaker()() as db:
        job = jobsvc.enqueue(db, "export", None, max_attempts=2)  # export with no user -> handler crashes
        db.commit()
        jid = job.id
    assert run_once()
    with get_sessionmaker()() as db:
        j = db.get(Job, jid)
        assert j.status == "queued" and j.attempts == 1 and j.run_after > j.created_at
        j.run_after = j.created_at  # make it runnable now
        db.commit()
    assert run_once()
    with get_sessionmaker()() as db:
        j = db.get(Job, jid)
        assert j.status == "failed" and j.attempts == 2  # dead-lettered, kept for inspection
    assert run_once() is False


def test_retention_cleanup_runs():
    with get_sessionmaker()() as db:
        res = run_retention(db)
        db.commit()
    assert set(res) >= {"blobs", "nonces", "idempotency", "refresh_tokens", "document_results"}
