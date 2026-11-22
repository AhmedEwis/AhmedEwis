from __future__ import annotations

from conftest import auth, grant, new_id, sign_in
from test_sync import account, push, tx


def setup_household(client, rsa_keys):
    owner = sign_in(client, rsa_keys, "hh-owner")
    member = sign_in(client, rsa_keys, "hh-member")
    viewer = sign_in(client, rsa_keys, "hh-viewer")
    outsider = sign_in(client, rsa_keys, "hh-outsider")
    for u in (owner, member, viewer, outsider):
        grant(client, u, "cloud_sync")
    h = client.post("/v1/households", headers=auth(owner), json={"name": "Home"}).json()
    hid = h["id"]
    for u, role in ((member, "member"), (viewer, "viewer")):
        inv = client.post(f"/v1/households/{hid}/invitations", headers=auth(owner), json={"role": role}).json()
        r = client.post("/v1/households/join", headers=auth(u), json={"code": inv["code"]})
        assert r.status_code == 200 and r.json()["role"] == role
    return owner, member, viewer, outsider, hid


def test_household_sharing_roles_and_isolation(client, rsa_keys):
    owner, member, viewer, outsider, hid = setup_household(client, rsa_keys)
    # personal data is never shared automatically
    personal = new_id()
    push(client, owner, [account(personal, name="Owner private")])
    shared_acct = new_id()
    res = push(client, member, [{**account(shared_acct, name="Family cash"), "household_id": hid}])
    assert res[0]["status"] == "applied"
    names_viewer = [r["payload"].get("name") for r in client.get("/v1/sync/pull", headers=auth(viewer)).json()["records"]]
    assert names_viewer == ["Family cash"]
    names_owner = {r["payload"].get("name") for r in client.get("/v1/sync/pull", headers=auth(owner)).json()["records"]}
    assert names_owner == {"Owner private", "Family cash"}
    assert client.get("/v1/sync/pull", headers=auth(outsider)).json()["records"] == []
    # viewer cannot push to the household
    res = push(client, viewer, [{**tx(new_id(), shared_acct), "household_id": hid}])
    assert res[0]["status"] == "rejected" and res[0]["error"]["code"] == "forbidden"
    # outsider cannot push into the household or touch shared records
    res = push(client, outsider, [{**account(new_id()), "household_id": hid}])
    assert res[0]["status"] == "rejected"
    res = push(client, outsider, [account(shared_acct, base=1, name="pwned")])
    assert res[0]["status"] == "rejected"
    # a household record cannot reference someone's personal account
    res = push(client, member, [{**tx(new_id(), personal), "household_id": hid}])
    assert res[0]["status"] == "rejected" and res[0]["error"]["code"] == "invalid_reference"
    # records cannot silently move between scopes
    res = push(client, owner, [account(shared_acct, base=1, name="moved")])
    assert res[0]["status"] == "rejected" and res[0]["error"]["code"] == "scope_change_not_allowed"


def test_only_owner_invites_and_removal_revokes_access(client, rsa_keys):
    owner, member, viewer, outsider, hid = setup_household(client, rsa_keys)
    assert client.post(f"/v1/households/{hid}/invitations", headers=auth(member), json={"role": "member"}).status_code == 403
    assert client.post(f"/v1/households/{hid}/invitations", headers=auth(outsider), json={"role": "member"}).status_code == 404
    shared = new_id()
    push(client, owner, [{**account(shared, name="Shared"), "household_id": hid}])
    assert len(client.get("/v1/sync/pull", headers=auth(member)).json()["records"]) == 1
    # non-owner cannot remove others
    viewer_id = viewer["user"]["id"]
    assert client.delete(f"/v1/households/{hid}/members/{viewer_id}", headers=auth(member)).status_code == 403
    member_id = member["user"]["id"]
    assert client.delete(f"/v1/households/{hid}/members/{member_id}", headers=auth(owner)).status_code == 204
    assert client.get("/v1/sync/pull", headers=auth(member)).json()["records"] == []
    assert client.get("/v1/households", headers=auth(member)).json() == []


def test_invitation_single_use_expiry_and_revocation(client, rsa_keys):
    owner = sign_in(client, rsa_keys, "inv-owner")
    a = sign_in(client, rsa_keys, "inv-a")
    b = sign_in(client, rsa_keys, "inv-b")
    hid = client.post("/v1/households", headers=auth(owner), json={"name": "H"}).json()["id"]
    inv = client.post(f"/v1/households/{hid}/invitations", headers=auth(owner), json={"role": "member"}).json()
    assert client.post("/v1/households/join", headers=auth(a), json={"code": inv["code"].lower()}).status_code == 200
    r = client.post("/v1/households/join", headers=auth(b), json={"code": inv["code"]})
    assert r.status_code == 404  # already used
    inv2 = client.post(f"/v1/households/{hid}/invitations", headers=auth(owner), json={"role": "viewer"}).json()
    assert client.delete(f"/v1/households/{hid}/invitations/{inv2['invitation_id']}", headers=auth(owner)).status_code == 204
    assert client.post("/v1/households/join", headers=auth(b), json={"code": inv2["code"]}).status_code == 404
    # expired invitation
    from datetime import UTC, datetime, timedelta

    from sqlalchemy import update

    from fils_api.db import get_sessionmaker
    from fils_api.models import HouseholdInvitation

    inv3 = client.post(f"/v1/households/{hid}/invitations", headers=auth(owner), json={"role": "member"}).json()
    with get_sessionmaker()() as db:
        db.execute(update(HouseholdInvitation).values(expires_at=datetime.now(UTC) - timedelta(minutes=1)))
        db.commit()
    assert client.post("/v1/households/join", headers=auth(b), json={"code": inv3["code"]}).status_code == 404
    # codes are stored hashed only
    with get_sessionmaker()() as db:
        assert all(inv3["code"].replace("-", "") not in r.code_hash for r in db.query(HouseholdInvitation).all())


def test_owner_leaving_dissolves_shared_data_only(client, rsa_keys):
    owner, member, viewer, outsider, hid = setup_household(client, rsa_keys)
    push(client, member, [account(new_id(), name="Member private")])
    push(client, member, [{**account(new_id(), name="Shared"), "household_id": hid}])
    assert client.delete(f"/v1/households/{hid}/members/{owner['user']['id']}", headers=auth(owner)).status_code == 204
    names = [r["payload"]["name"] for r in client.get("/v1/sync/pull", headers=auth(member)).json()["records"]]
    assert names == ["Member private"]
