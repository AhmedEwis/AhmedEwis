from __future__ import annotations

import base64
import hashlib
import json
import os
import time
import uuid

os.environ.setdefault("FILS_ENV", "test")
os.environ.setdefault("FILS_DATABASE_URL", "postgresql+psycopg://fils:fils@localhost:5432/fils_test")
os.environ["FILS_LLM_PROVIDER"] = "fake"
os.environ["FILS_GOOGLE_CLIENT_IDS"] = '["google-client-id"]'
os.environ["FILS_APPLE_CLIENT_IDS"] = '["kw.fils.fils"]'
os.environ["FILS_RATE_LIMIT_ENABLED"] = "false"
os.environ["FILS_GOOGLE_PUBSUB_AUDIENCE"] = "https://api.fils.test/v1/webhooks/google"
os.environ["FILS_GOOGLE_PUBSUB_SERVICE_ACCOUNT"] = "rtdn@fils-test.iam.gserviceaccount.com"

import jwt  # noqa: E402
import pytest  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from jwt.algorithms import RSAAlgorithm  # noqa: E402
from sqlalchemy import text  # noqa: E402

from fils_api.config import get_settings  # noqa: E402
from fils_api.db import get_engine  # noqa: E402
from fils_api.main import create_app  # noqa: E402
from fils_api.providers.identity import JWKSCache, build_verifiers  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def _migrate():
    from alembic import command
    from alembic.config import Config

    cfg = Config(os.path.join(os.path.dirname(__file__), "..", "alembic.ini"))
    cfg.set_main_option("script_location", os.path.join(os.path.dirname(__file__), "..", "alembic"))
    cfg.set_main_option("sqlalchemy.url", os.environ["FILS_DATABASE_URL"])
    cfg.attributes["skip_logging"] = True
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    yield


TABLES = [
    "sync_records", "idempotency_keys", "jobs", "temp_blobs", "household_invitations", "household_members", "households",
    "entitlements", "purchase_links", "billing_events", "ai_usage", "parser_samples", "audit_events", "refresh_tokens",
    "sessions", "consent_records", "auth_nonces", "auth_identities", "users",
]


@pytest.fixture(autouse=True)
def _clean_db():
    with get_engine().begin() as conn:
        conn.execute(text("TRUNCATE " + ", ".join(TABLES) + " RESTART IDENTITY CASCADE"))
    yield


class RSAKeys:
    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.kid = "test-kid-1"
        jwk = json.loads(RSAAlgorithm.to_jwk(self.key.public_key()))
        jwk.update({"kid": self.kid, "alg": "RS256", "use": "sig"})
        self.jwks = {"keys": [jwk]}

    def sign(self, claims: dict, kid: str | None = None) -> str:
        return jwt.encode(claims, self.key, algorithm="RS256", headers={"kid": kid or self.kid})


@pytest.fixture(scope="session")
def rsa_keys() -> RSAKeys:
    return RSAKeys()


@pytest.fixture
def app(rsa_keys):
    get_settings.cache_clear()
    a = create_app()
    fetch = lambda url: rsa_keys.jwks  # noqa: E731
    a.state.identity_verifiers = build_verifiers(get_settings(), fetch)
    a.state.google_oidc_cache = JWKSCache("test", fetch)
    return a


@pytest.fixture
def client(app) -> TestClient:
    return TestClient(app)


def provider_token(rsa_keys: RSAKeys, provider: str, sub: str, nonce_raw: str | None, **over) -> str:
    t = int(time.time())
    claims = {
        "iss": "https://appleid.apple.com" if provider == "apple" else "https://accounts.google.com",
        "aud": "kw.fils.fils" if provider == "apple" else "google-client-id",
        "sub": sub,
        "iat": t,
        "exp": t + 600,
        "email": f"{sub}@example.com",
        "email_verified": True,
    }
    if nonce_raw is not None:
        claims["nonce"] = hashlib.sha256(nonce_raw.encode()).hexdigest()
    claims.update(over)
    return rsa_keys.sign(claims)


DEVICE = {"device_id": "device-0001-abcd", "platform": "android", "app_version": "1.0.0"}


def get_nonce(client) -> str:
    return client.post("/v1/auth/nonce").json()["nonce"]


def sign_in(client, rsa_keys, sub: str = "user-a", provider: str = "google") -> dict:
    n = get_nonce(client)
    tok = provider_token(rsa_keys, provider, sub, n)
    body = {"id_token": tok, "nonce": n, "device": DEVICE} if provider == "google" else {"identity_token": tok, "nonce": n, "device": DEVICE}
    r = client.post(f"/v1/auth/{provider}", json=body)
    assert r.status_code == 200, r.text
    return r.json()


def auth(res: dict) -> dict:
    return {"Authorization": f"Bearer {res['access_token']}"}


def reauth_header(client, rsa_keys, res: dict, sub: str, provider: str = "google") -> dict:
    n = get_nonce(client)
    tok = provider_token(rsa_keys, provider, sub, n)
    r = client.post("/v1/auth/reauth", headers=auth(res), json={"provider": provider, "token": tok, "nonce": n})
    assert r.status_code == 200, r.text
    return {**auth(res), "X-Reauth": r.json()["reauth_token"]}


def grant(client, res: dict, *kinds: str) -> None:
    for k in kinds:
        r = client.post("/v1/me/consents", headers=auth(res), json={"kind": k, "granted": True, "policy_version": "2026-11"})
        assert r.status_code == 200, r.text


def new_id() -> str:
    return str(uuid.uuid4())


def b64(d: dict) -> str:
    return base64.b64encode(json.dumps(d).encode()).decode()
