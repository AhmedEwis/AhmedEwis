from __future__ import annotations

import time

from conftest import DEVICE, auth, get_nonce, provider_token, reauth_header, sign_in

from fils_api.config import get_settings


def test_google_sign_in_creates_user_and_session(client, rsa_keys):
    res = sign_in(client, rsa_keys, "g-1")
    assert res["is_new_user"] is True
    me = client.get("/v1/me", headers=auth(res)).json()
    assert me["identities"][0]["provider"] == "google"
    assert me["entitlements"]["source"] == "dev_unlocked"
    again = sign_in(client, rsa_keys, "g-1")
    assert again["is_new_user"] is False and again["user"]["id"] == res["user"]["id"]


def test_apple_sign_in(client, rsa_keys):
    res = sign_in(client, rsa_keys, "apple-sub-1", provider="apple")
    assert res["user"]["identities"][0]["provider"] == "apple"


def _post_google(client, token, nonce):
    return client.post("/v1/auth/google", json={"id_token": token, "nonce": nonce, "device": DEVICE})


def test_rejects_wrong_audience_issuer_expiry_and_signature(client, rsa_keys):
    n = get_nonce(client)
    assert _post_google(client, provider_token(rsa_keys, "google", "x", n, aud="other-app"), n).status_code == 401
    n = get_nonce(client)
    assert _post_google(client, provider_token(rsa_keys, "google", "x", n, iss="https://evil.example"), n).status_code == 401
    n = get_nonce(client)
    old = int(time.time()) - 4000
    r = _post_google(client, provider_token(rsa_keys, "google", "x", n, iat=old, exp=old + 600), n)
    assert r.status_code == 401 and r.json()["error"]["code"] == "provider_token_expired"
    # Signed by an unknown key id
    n = get_nonce(client)
    from conftest import RSAKeys

    other = RSAKeys()
    tok = other.sign({"iss": "https://accounts.google.com", "aud": "google-client-id", "sub": "x", "iat": int(time.time()),
                      "exp": int(time.time()) + 600, "nonce": "z"}, kid="unknown-kid")
    assert _post_google(client, tok, n).status_code == 401
    # Right kid, wrong key (forged signature)
    tok = other.sign({"iss": "https://accounts.google.com", "aud": "google-client-id", "sub": "x", "iat": int(time.time()),
                      "exp": int(time.time()) + 600}, kid=rsa_keys.kid)
    assert _post_google(client, tok, n).status_code == 401


def test_nonce_must_match_and_is_single_use(client, rsa_keys):
    n = get_nonce(client)
    tok = provider_token(rsa_keys, "google", "nonce-user", "different-nonce-value")
    assert _post_google(client, tok, n).json()["error"]["code"] == "nonce_mismatch"
    tok = provider_token(rsa_keys, "google", "nonce-user", n)
    assert _post_google(client, tok, n).status_code == 200
    # replay of the same token + nonce
    r = _post_google(client, tok, n)
    assert r.status_code == 401 and r.json()["error"]["code"] == "nonce_invalid"
    # a nonce the server never issued
    fake = "never-issued-nonce-value-123"
    assert _post_google(client, provider_token(rsa_keys, "google", "n2", fake), fake).json()["error"]["code"] == "nonce_invalid"


def test_matching_email_does_not_link_accounts(client, rsa_keys):
    a = sign_in(client, rsa_keys, "same-person", provider="google")
    n = get_nonce(client)
    tok = provider_token(rsa_keys, "apple", "apple-other", n, email="same-person@example.com")
    b = client.post("/v1/auth/apple", json={"identity_token": tok, "nonce": n, "device": DEVICE}).json()
    assert b["user"]["id"] != a["user"]["id"]


def test_refresh_rotation_and_reuse_detection(client, rsa_keys):
    res = sign_in(client, rsa_keys, "r-1")
    r1 = client.post("/v1/auth/refresh", json={"refresh_token": res["refresh_token"]})
    assert r1.status_code == 200
    new = r1.json()
    assert new["refresh_token"] != res["refresh_token"]
    # reuse the old token -> whole session revoked
    r2 = client.post("/v1/auth/refresh", json={"refresh_token": res["refresh_token"]})
    assert r2.status_code == 401 and r2.json()["error"]["code"] == "refresh_token_reused"
    assert client.post("/v1/auth/refresh", json={"refresh_token": new["refresh_token"]}).status_code == 401
    assert client.get("/v1/me", headers=auth(new)).status_code == 401


def test_logout_and_session_revocation(client, rsa_keys):
    a = sign_in(client, rsa_keys, "s-1")
    b = sign_in(client, rsa_keys, "s-1")
    sessions = client.get("/v1/me/sessions", headers=auth(a)).json()
    assert len(sessions) == 2
    other = next(s for s in sessions if not s["current"])
    assert client.delete(f"/v1/me/sessions/{other['id']}", headers=auth(a)).status_code == 204
    assert client.get("/v1/me", headers=auth(b)).status_code == 401
    assert client.post("/v1/auth/logout", json={"refresh_token": a["refresh_token"]}).status_code == 204
    assert client.get("/v1/me", headers=auth(a)).status_code == 401


def test_cannot_revoke_other_users_session(client, rsa_keys):
    a = sign_in(client, rsa_keys, "u-a")
    b = sign_in(client, rsa_keys, "u-b")
    b_sess = client.get("/v1/me/sessions", headers=auth(b)).json()[0]["id"]
    assert client.delete(f"/v1/me/sessions/{b_sess}", headers=auth(a)).status_code == 404
    assert client.get("/v1/me", headers=auth(b)).status_code == 200


def test_access_token_expiry_and_tampering(client, rsa_keys, monkeypatch):
    res = sign_in(client, rsa_keys, "t-1")
    tok = res["access_token"]
    head, body, sig = tok.split(".")
    tampered = f"{head}.{body}.{sig[:-2]}AA"
    assert client.get("/v1/me", headers={"Authorization": f"Bearer {tampered}"}).status_code == 401
    import jwt as pyjwt

    s = get_settings()
    expired = pyjwt.encode(
        {"sub": res["user"]["id"], "sid": "x", "typ": "access", "iat": 1, "exp": 2, "iss": s.jwt_issuer, "aud": "fils-app"},
        s.effective_jwt_secret(), algorithm="HS256",
    )
    r = client.get("/v1/me", headers={"Authorization": f"Bearer {expired}"})
    assert r.status_code == 401 and r.json()["error"]["code"] == "token_expired"
    # a refresh token / reauth token is not an access token
    assert client.get("/v1/me", headers={"Authorization": f"Bearer {res['refresh_token']}"}).status_code == 401


def test_reauth_requires_same_identity(client, rsa_keys):
    a = sign_in(client, rsa_keys, "owner-1")
    n = get_nonce(client)
    tok = provider_token(rsa_keys, "google", "someone-else", n)
    r = client.post("/v1/auth/reauth", headers=auth(a), json={"provider": "google", "token": tok, "nonce": n})
    assert r.status_code == 403
    h = reauth_header(client, rsa_keys, a, "owner-1")
    assert "X-Reauth" in h


def test_identity_linking_requires_reauth_and_unused_identity(client, rsa_keys):
    a = sign_in(client, rsa_keys, "link-a")
    sign_in(client, rsa_keys, "apple-taken", provider="apple")
    n = get_nonce(client)
    tok = provider_token(rsa_keys, "apple", "apple-new", n)
    assert client.post("/v1/me/identities/apple", headers=auth(a), json={"token": tok, "nonce": n}).status_code == 403
    h = reauth_header(client, rsa_keys, a, "link-a")
    n = get_nonce(client)
    tok = provider_token(rsa_keys, "apple", "apple-taken", n)
    r = client.post("/v1/me/identities/apple", headers=h, json={"token": tok, "nonce": n})
    assert r.status_code == 409 and r.json()["error"]["code"] == "identity_in_use"
    n = get_nonce(client)
    tok = provider_token(rsa_keys, "apple", "apple-new", n)
    r = client.post("/v1/me/identities/apple", headers=h, json={"token": tok, "nonce": n})
    assert r.status_code == 200 and {i["provider"] for i in r.json()["identities"]} == {"google", "apple"}


def test_demo_session_available_outside_production(client):
    r = client.post("/v1/demo/session", json=DEVICE)
    assert r.status_code == 200 and r.json()["user"]["is_demo"] is True


def test_demo_session_404_in_production(rsa_keys, monkeypatch):
    import base64
    import os

    monkeypatch.setenv("FILS_ENV", "production")
    monkeypatch.setenv("FILS_JWT_SECRET", "x" * 40)
    monkeypatch.setenv("FILS_LLM_PROVIDER", "disabled")
    monkeypatch.setenv("FILS_DATA_KEY", base64.b64encode(os.urandom(32)).decode())
    get_settings.cache_clear()
    try:
        from fastapi.testclient import TestClient

        from fils_api.main import create_app

        prod = create_app()
        c = TestClient(prod)
        r = c.post("/v1/demo/session", json=DEVICE)
        assert r.status_code == 404
        assert c.get("/docs").status_code == 404  # no interactive docs in production
    finally:
        monkeypatch.undo()
        get_settings.cache_clear()


def test_production_requires_secrets(monkeypatch):
    import pytest

    from fils_api.config import Settings

    monkeypatch.setenv("FILS_ENV", "production")
    monkeypatch.delenv("FILS_JWT_SECRET", raising=False)
    with pytest.raises(ValueError):
        Settings()
