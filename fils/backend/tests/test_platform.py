"""Cross-cutting controls: rate limits, body limits, headers, logging redaction, health."""
from __future__ import annotations

import logging

from conftest import DEVICE, auth, sign_in

from fils_api.config import get_settings
from fils_api.logging_setup import JSONFormatter, redact


def test_health_and_ready(client):
    assert client.get("/healthz").json() == {"status": "ok"}
    r = client.get("/readyz").json()
    assert r["status"] == "ready" and r["migration"] == "0001"


def test_security_headers(client):
    r = client.get("/healthz")
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["Cache-Control"] == "no-store"
    assert "frame-ancestors 'none'" in r.headers["Content-Security-Policy"]
    assert "access-control-allow-origin" not in {k.lower() for k in r.headers}


def test_rate_limit(client, app, monkeypatch):
    monkeypatch.setenv("FILS_RATE_LIMIT_ENABLED", "true")
    monkeypatch.setenv("FILS_RATE_LIMITS_PER_MINUTE", '{"auth": 3, "default": 300}')
    get_settings.cache_clear()
    try:
        codes = [client.post("/v1/auth/nonce").status_code for _ in range(5)]
        assert codes[:3] == [200, 200, 200] and codes[3] == 429
        r = client.post("/v1/auth/nonce")
        assert r.json()["error"]["code"] == "rate_limited" and int(r.headers["Retry-After"]) >= 1
    finally:
        monkeypatch.undo()
        get_settings.cache_clear()


def test_body_limit(client, rsa_keys):
    a = sign_in(client, rsa_keys, "big-1")
    big = {"device_id": "d", "ops": [{"entity": "account", "id": "x", "base_version": 0, "payload": {"n": "x" * 2_000_000}}]}
    r = client.post("/v1/sync/push", headers=auth(a), json=big)
    assert r.status_code == 413


def test_validation_errors_do_not_echo_input(client):
    r = client.post("/v1/auth/google", json={"id_token": "secret-token-value", "nonce": "short", "device": DEVICE})
    assert r.status_code == 422 and "secret-token-value" not in r.text


def test_log_redaction():
    s = redact("Authorization: Bearer abc.def.ghi user a@b.com card 4111111111111111 refresh_token=xyz123")
    assert "abc.def" not in s and "a@b.com" not in s and "4111111111111111" not in s and "xyz123" not in s
    rec = logging.LogRecord("x", logging.INFO, "f", 1, "msg eyJhbGciOi.eyJzdWIi.c2ln", None, None)
    rec.text = "Purchase KWD 5.250 at Talabat"
    out = JSONFormatter().format(rec)
    assert "Talabat" not in out and "eyJ" not in out


def test_openapi_published(client):
    spec = client.get("/v1/openapi.json").json()
    assert "/v1/sync/push" in spec["paths"] and "/v1/assistant/turn" in spec["paths"]
