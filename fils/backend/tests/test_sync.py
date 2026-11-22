from __future__ import annotations

from conftest import auth, grant, new_id, sign_in


def account(aid: str, base: int = 0, name: str = "NBK Current", **extra) -> dict:
    payload = {
        "name": name, "kind": "bank", "currency": "KWD", "opening_balance_minor": 1_250_500,
        "opening_balance_date": "2026-11-01", "mask_last4": "1234", **extra,
    }
    return {"entity": "account", "id": aid, "base_version": base, "payload": payload, "updated_at": "2026-11-22T10:00:00Z"}


def tx(tid: str, aid: str, base: int = 0, **over) -> dict:
    p = {
        "account_id": aid, "kind": "expense", "status": "posted", "amount_minor": 5250, "currency": "KWD",
        "merchant": "Talabat", "occurred_at": "2026-11-22T09:00:00Z", "source": "sms", "category_id": "food",
    }
    p.update(over)
    return {"entity": "transaction", "id": tid, "base_version": base, "payload": p}


def push(client, res, ops, device="dev-1"):
    r = client.post("/v1/sync/push", headers=auth(res), json={"device_id": device, "ops": ops})
    assert r.status_code == 200, r.text
    return r.json()["results"]


def test_sync_requires_consent_and_signin_uploads_nothing(client, rsa_keys):
    a = sign_in(client, rsa_keys, "c-1")
    r = client.post("/v1/sync/push", headers=auth(a), json={"device_id": "d", "ops": []})
    assert r.status_code == 403 and r.json()["error"]["code"] == "consent_required"
    assert client.get("/v1/sync/pull", headers=auth(a)).status_code == 403
    # revoking consent blocks again
    grant(client, a, "cloud_sync")
    assert client.get("/v1/sync/pull", headers=auth(a)).status_code == 200
    client.post("/v1/me/consents", headers=auth(a), json={"kind": "cloud_sync", "granted": False, "policy_version": "2026-11"})
    assert client.get("/v1/sync/pull", headers=auth(a)).status_code == 403
    hist = client.get("/v1/me/consents", headers=auth(a)).json()["history"]
    assert [h["granted"] for h in hist] == [False, True]  # append-only history, newest first


def test_push_pull_versions_and_references(client, rsa_keys):
    a = sign_in(client, rsa_keys, "s-1")
    grant(client, a, "cloud_sync")
    aid, tid = new_id(), new_id()
    # transaction listed first: server orders by dependency so the account is applied first
    res = push(client, a, [tx(tid, aid), account(aid)])
    assert [r["status"] for r in res] == ["applied", "applied"]
    pulled = client.get("/v1/sync/pull", headers=auth(a)).json()
    assert {r["entity"] for r in pulled["records"]} == {"account", "transaction"}
    t = next(r for r in pulled["records"] if r["entity"] == "transaction")
    assert t["payload"]["amount_minor"] == 5250 and t["version"] == 1
    # incremental pull from cursor returns nothing new
    again = client.get("/v1/sync/pull", headers=auth(a), params={"cursor": pulled["cursor"]}).json()
    assert again["records"] == []
    # update with correct base version
    res = push(client, a, [tx(tid, aid, base=1, amount_minor=6000)])
    assert res[0]["status"] == "applied" and res[0]["server_version"] == 2
    upd = client.get("/v1/sync/pull", headers=auth(a), params={"cursor": pulled["cursor"]}).json()["records"]
    assert len(upd) == 1 and upd[0]["payload"]["amount_minor"] == 6000


def test_conflict_is_reported_not_overwritten(client, rsa_keys):
    a = sign_in(client, rsa_keys, "s-2")
    grant(client, a, "cloud_sync")
    aid = new_id()
    push(client, a, [account(aid)])
    push(client, a, [account(aid, base=1, name="Edited on phone")], device="phone")
    res = push(client, a, [account(aid, base=1, name="Edited on tablet")], device="tablet")
    assert res[0]["status"] == "conflict"
    assert res[0]["server_record"]["payload"]["name"] == "Edited on phone"
    rec = client.get("/v1/sync/pull", headers=auth(a)).json()["records"][0]
    assert rec["payload"]["name"] == "Edited on phone" and rec["version"] == 2


def test_tombstones_never_resurrect(client, rsa_keys):
    a = sign_in(client, rsa_keys, "s-3")
    grant(client, a, "cloud_backup")
    aid = new_id()
    push(client, a, [account(aid)])
    res = push(client, a, [{"entity": "account", "id": aid, "base_version": 1, "deleted": True}])
    assert res[0]["status"] == "applied"
    res = push(client, a, [account(aid, base=2)])
    assert res[0]["status"] == "rejected" and res[0]["error"]["code"] == "tombstoned"
    res = push(client, a, [account(aid, base=0)])
    assert res[0]["status"] == "rejected"
    rec = client.get("/v1/sync/pull", headers=auth(a)).json()["records"][0]
    assert rec["deleted"] is True and rec["payload"] == {}


def test_cross_user_isolation(client, rsa_keys):
    a = sign_in(client, rsa_keys, "iso-a")
    b = sign_in(client, rsa_keys, "iso-b")
    grant(client, a, "cloud_sync")
    grant(client, b, "cloud_sync")
    aid = new_id()
    push(client, a, [account(aid)])
    # B cannot see A's data
    assert client.get("/v1/sync/pull", headers=auth(b)).json()["records"] == []
    # B cannot overwrite or delete A's record by guessing its id
    res = push(client, b, [account(aid, base=1, name="pwned")])
    assert res[0]["status"] == "rejected" and res[0]["error"]["code"] == "invalid_id"
    assert "server_record" not in res[0]
    res = push(client, b, [{"entity": "account", "id": aid, "base_version": 1, "deleted": True}])
    assert res[0]["status"] == "rejected"
    # B cannot reference A's account from its own transaction
    res = push(client, b, [tx(new_id(), aid)])
    assert res[0]["status"] == "rejected" and res[0]["error"]["code"] == "invalid_reference"
    assert client.get("/v1/sync/pull", headers=auth(a)).json()["records"][0]["payload"]["name"] == "NBK Current"


def test_payload_validation(client, rsa_keys):
    a = sign_in(client, rsa_keys, "v-1")
    grant(client, a, "cloud_sync")
    aid = new_id()
    push(client, a, [account(aid)])
    bad = [
        tx(new_id(), aid, amount_minor=5.25),  # float money
        tx(new_id(), aid, currency="kd"),
        tx(new_id(), aid, kind="adjustment"),  # old enum
        tx(new_id(), aid, kind="transfer"),  # transfer without counter account
        tx(new_id(), aid, unexpected_field=1),
        tx(new_id(), aid, splits=[{"category_id": "food", "amount_minor": 1000}]),  # splits must sum
        {"entity": "nonsense", "id": new_id(), "base_version": 0, "payload": {}},
        {"entity": "setting", "id": new_id(), "base_version": 0, "payload": {"key": "jwt_secret", "value": 1}},
    ]
    res = push(client, a, bad)
    assert all(r["status"] == "rejected" for r in res), res
    ok = push(client, a, [tx(new_id(), aid, kind="adjust_down", category_id=None), tx(new_id(), aid, category_id="transfers")])
    assert [r["status"] for r in ok] == ["applied", "applied"]


def test_new_record_with_nonzero_base_is_rejected(client, rsa_keys):
    a = sign_in(client, rsa_keys, "v-2")
    grant(client, a, "cloud_sync")
    res = push(client, a, [account(new_id(), base=3)])
    assert res[0]["status"] == "rejected" and res[0]["error"]["code"] == "not_found"


def test_idempotency_replay_and_mismatch(client, rsa_keys):
    a = sign_in(client, rsa_keys, "idem-1")
    grant(client, a, "cloud_sync")
    aid = new_id()
    body = {"device_id": "d", "ops": [account(aid)]}
    h = {**auth(a), "Idempotency-Key": "push-0001"}
    r1 = client.post("/v1/sync/push", headers=h, json=body)
    r2 = client.post("/v1/sync/push", headers=h, json=body)
    assert r1.status_code == r2.status_code == 200
    assert r2.headers.get("Idempotent-Replayed") == "true"
    assert r1.json() == r2.json()  # replay, not a second (conflicting) application
    body2 = {"device_id": "d", "ops": [account(new_id())]}
    r3 = client.post("/v1/sync/push", headers=h, json=body2)
    assert r3.status_code == 409 and r3.json()["error"]["code"] == "idempotency_mismatch"
    # keys are scoped per user
    b = sign_in(client, rsa_keys, "idem-2")
    grant(client, b, "cloud_sync")
    r4 = client.post("/v1/sync/push", headers={**auth(b), "Idempotency-Key": "push-0001"}, json=body2)
    assert r4.status_code == 200 and "Idempotent-Replayed" not in r4.headers


def test_pull_pagination(client, rsa_keys):
    a = sign_in(client, rsa_keys, "page-1")
    grant(client, a, "cloud_sync")
    push(client, a, [account(new_id(), name=f"A{i}") for i in range(5)])
    p1 = client.get("/v1/sync/pull", headers=auth(a), params={"limit": 2}).json()
    assert len(p1["records"]) == 2 and p1["has_more"] is True
    p2 = client.get("/v1/sync/pull", headers=auth(a), params={"limit": 2, "cursor": p1["cursor"]}).json()
    p3 = client.get("/v1/sync/pull", headers=auth(a), params={"limit": 2, "cursor": p2["cursor"]}).json()
    names = [r["payload"]["name"] for r in p1["records"] + p2["records"] + p3["records"]]
    assert sorted(names) == ["A0", "A1", "A2", "A3", "A4"] and p3["has_more"] is False
    assert client.get("/v1/sync/pull", headers=auth(a), params={"cursor": "garbage!"}).status_code == 400
