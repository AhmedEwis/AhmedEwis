from __future__ import annotations

import base64
import time
import uuid
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from conftest import auth, b64, sign_in
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID, ObjectIdentifier

from fils_api.db import get_sessionmaker
from fils_api.models import Entitlement

LEAF_OID = ObjectIdentifier("1.2.840.113635.100.6.11.1")
INTER_OID = ObjectIdentifier("1.2.840.113635.100.6.2.1")


def _cert(subject, issuer_name, pub, signer, ca: bool, ext_oid=None):
    now = datetime.now(UTC)
    b = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject)]))
        .issuer_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, issuer_name)]))
        .public_key(pub)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
    )
    if ext_oid is not None:
        b = b.add_extension(x509.UnrecognizedExtension(ext_oid, b"\x05\x00"), critical=False)
    return b.sign(signer, hashes.SHA256())


class FakeApple:
    def __init__(self, leaf_oid=LEAF_OID):
        self.root_key = ec.generate_private_key(ec.SECP256R1())
        self.inter_key = ec.generate_private_key(ec.SECP256R1())
        self.leaf_key = ec.generate_private_key(ec.SECP256R1())
        self.root = _cert("Test Apple Root", "Test Apple Root", self.root_key.public_key(), self.root_key, True)
        self.inter = _cert("Test WWDR", "Test Apple Root", self.inter_key.public_key(), self.root_key, True, INTER_OID)
        self.leaf = _cert("Test StoreKit", "Test WWDR", self.leaf_key.public_key(), self.inter_key, False, leaf_oid)

    def sign(self, payload: dict) -> str:
        x5c = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in (self.leaf, self.inter, self.root)]
        return jwt.encode(payload, self.leaf_key, algorithm="ES256", headers={"x5c": x5c})


@pytest.fixture
def apple(app):
    fa = FakeApple()
    app.state.apple_roots = [fa.root]
    return fa


def txn(user_id=None, otid="2000000123", expires_in_days=30, **over):
    p = {
        "transactionId": otid + "1",
        "originalTransactionId": otid,
        "bundleId": "kw.fils.fils",
        "productId": "kw.fils.premium.monthly",
        "purchaseDate": int(time.time() * 1000),
        "expiresDate": int((time.time() + expires_in_days * 86400) * 1000),
        "environment": "Sandbox",
        "type": "Auto-Renewable Subscription",
    }
    if user_id:
        p["appAccountToken"] = user_id
    p.update(over)
    return p


def ent(user_id: str) -> Entitlement | None:
    with get_sessionmaker()() as db:
        return db.get(Entitlement, uuid.UUID(user_id))


def test_apple_verify_valid_transaction(client, rsa_keys, apple):
    a = sign_in(client, rsa_keys, "buy-1")
    r = client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": apple.sign(txn(a["user"]["id"]))})
    assert r.status_code == 200, r.text
    e = ent(a["user"]["id"])
    assert e.plan == "premium" and e.source == "apple" and e.expires_at > datetime.now(UTC)


def test_apple_rejects_untrusted_chain_tampering_and_missing_oid(client, rsa_keys, apple):
    a = sign_in(client, rsa_keys, "buy-2")
    other = FakeApple()  # valid-looking chain from an untrusted root
    r = client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": other.sign(txn())})
    assert r.status_code == 401
    token = apple.sign(txn())
    h, p, s = token.split(".")
    forged_payload = base64.urlsafe_b64encode(b'{"productId":"kw.fils.premium.yearly"}').rstrip(b"=").decode()
    r = client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": f"{h}.{forged_payload}.{s}"})
    assert r.status_code == 401
    no_oid = FakeApple(leaf_oid=None)
    client.app.state.apple_roots = [no_oid.root]
    r = client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": no_oid.sign(txn())})
    assert r.status_code == 401
    assert ent(a["user"]["id"]) is None


def test_apple_wrong_bundle_or_product(client, rsa_keys, apple):
    a = sign_in(client, rsa_keys, "buy-3")
    r = client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": apple.sign(txn(bundleId="com.other"))})
    assert r.status_code == 422
    r = client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": apple.sign(txn(productId="free.gems"))})
    assert r.status_code == 422


def test_purchase_cannot_be_shared_across_accounts(client, rsa_keys, apple):
    a = sign_in(client, rsa_keys, "share-a")
    b = sign_in(client, rsa_keys, "share-b")
    assert client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": apple.sign(txn())}).status_code == 200
    r = client.post("/v1/billing/apple/verify", headers=auth(b), json={"signed_transaction": apple.sign(txn())})
    assert r.status_code == 409
    r = client.post("/v1/billing/apple/verify", headers=auth(b), json={"signed_transaction": apple.sign(txn(a["user"]["id"], otid="999"))})
    assert r.status_code == 409  # appAccountToken belongs to A
    assert ent(b["user"]["id"]) is None


def test_no_apple_root_installed_is_explicit(client, rsa_keys, app):
    app.state.apple_roots = []
    a = sign_in(client, rsa_keys, "buy-4")
    r = client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": FakeApple().sign(txn())})
    assert r.status_code == 503 and r.json()["error"]["code"] == "billing_not_configured"


def notification(apple, ntype, tx, subtype=None, nid=None):
    return {
        "signedPayload": apple.sign(
            {
                "notificationType": ntype,
                "subtype": subtype,
                "notificationUUID": nid or str(uuid.uuid4()),
                "version": "2.0",
                "signedDate": int(time.time() * 1000),
                "data": {"bundleId": "kw.fils.fils", "environment": "Sandbox", "signedTransactionInfo": apple.sign(tx)},
            }
        )
    }


def test_apple_webhook_renewal_grace_refund_and_replay(client, rsa_keys, apple):
    a = sign_in(client, rsa_keys, "wh-1")
    uid = a["user"]["id"]
    client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": apple.sign(txn(uid, expires_in_days=1))})
    nid = str(uuid.uuid4())
    body = notification(apple, "DID_RENEW", txn(uid, expires_in_days=31), nid=nid)
    assert client.post("/v1/webhooks/apple", json=body).json()["status"] == "ok"
    exp1 = ent(uid).expires_at
    assert exp1 > datetime.now(UTC) + timedelta(days=30)
    # replay of the same notification is ignored
    replay = notification(apple, "EXPIRED", txn(uid, expires_in_days=-1), nid=nid)
    assert client.post("/v1/webhooks/apple", json=replay).json()["status"] == "duplicate"
    assert ent(uid).plan == "premium"
    # grace period
    client.post("/v1/webhooks/apple", json=notification(apple, "DID_FAIL_TO_RENEW", txn(uid, expires_in_days=-1), subtype="GRACE_PERIOD"))
    assert ent(uid).in_grace_period is True
    # refund revokes
    client.post("/v1/webhooks/apple", json=notification(apple, "REFUND", txn(uid, revocationDate=int(time.time() * 1000))))
    e = ent(uid)
    assert e.plan == "free" and e.revoked_at is not None


def test_apple_webhook_forgery_rejected(client, apple):
    forger = FakeApple()
    r = client.post("/v1/webhooks/apple", json=notification(forger, "DID_RENEW", txn()))
    assert r.status_code == 401
    assert client.post("/v1/webhooks/apple", json={"signedPayload": "a.b.c"}).status_code == 401
    assert client.post("/v1/webhooks/apple", json={}).status_code == 400


def test_entitlement_logic_in_production_mode(monkeypatch, rsa_keys):
    """Production computes entitlements from verified purchases (dev/staging are dev_unlocked)."""
    from fils_api.config import get_settings
    from fils_api.services.entitlements import entitlements_for, upsert_entitlement

    with get_sessionmaker()() as db:
        from fils_api.models import User

        u = User(display_name="p")
        db.add(u)
        db.flush()
        monkeypatch.setenv("FILS_ENV", "production")
        monkeypatch.setenv("FILS_JWT_SECRET", "y" * 40)
        monkeypatch.setenv("FILS_DATA_KEY", base64.b64encode(b"k" * 32).decode())
        get_settings.cache_clear()
        try:
            assert entitlements_for(db, u.id)["plan"] == "free"
            upsert_entitlement(db, u.id, plan="premium", source="apple", product_id="p", expires_at=datetime.now(UTC) + timedelta(days=3))
            assert entitlements_for(db, u.id)["plan"] == "premium"
            upsert_entitlement(db, u.id, plan="premium", source="apple", product_id="p",
                               expires_at=datetime.now(UTC) - timedelta(days=1), in_grace_period=True)
            e = entitlements_for(db, u.id)
            assert e["plan"] == "premium" and e["in_grace_period"] is True
            upsert_entitlement(db, u.id, plan="premium", source="apple", product_id="p", expires_at=datetime.now(UTC) - timedelta(days=1))
            assert entitlements_for(db, u.id)["plan"] == "free"
        finally:
            monkeypatch.undo()
            get_settings.cache_clear()
        db.rollback()


# ---------------------------------------------------------------- Google

class StubPlay:
    def __init__(self):
        self.state = "SUBSCRIPTION_STATE_ACTIVE"
        self.obf = None
        self.acked = []

    def get_subscription(self, package, token):
        d = {
            "subscriptionState": self.state,
            "acknowledgementState": "ACKNOWLEDGEMENT_STATE_PENDING",
            "lineItems": [{"productId": "kw.fils.premium", "expiryTime": (datetime.now(UTC) + timedelta(days=30)).isoformat().replace("+00:00", "Z")}],
        }
        if self.obf:
            d["externalAccountIdentifiers"] = {"obfuscatedExternalAccountId": self.obf}
        return d

    def acknowledge(self, package, product_id, token):
        self.acked.append(token)


def push_token(rsa_keys, **over):
    t = int(time.time())
    claims = {"iss": "https://accounts.google.com", "aud": "https://api.fils.test/v1/webhooks/google", "iat": t, "exp": t + 600,
              "email": "rtdn@fils-test.iam.gserviceaccount.com", "email_verified": True, "sub": "1"}
    claims.update(over)
    return rsa_keys.sign(claims)


def rtdn(token="ptoken-1", ntype=2, mid="m-1"):
    data = {"version": "1.0", "packageName": "kw.fils.fils", "eventTimeMillis": "1",
            "subscriptionNotification": {"version": "1.0", "notificationType": ntype, "purchaseToken": token, "subscriptionId": "kw.fils.premium"}}
    return {"message": {"data": b64(data), "messageId": mid}, "subscription": "projects/x/subscriptions/y"}


def test_google_not_configured(client, rsa_keys):
    a = sign_in(client, rsa_keys, "g-0")
    r = client.post("/v1/billing/google/verify", headers=auth(a), json={"product_id": "kw.fils.premium", "purchase_token": "t"})
    assert r.status_code == 503


def test_google_verify_ack_and_rtdn(client, app, rsa_keys):
    play = StubPlay()
    app.state.play_client = play
    a = sign_in(client, rsa_keys, "g-1")
    r = client.post("/v1/billing/google/verify", headers=auth(a), json={"product_id": "kw.fils.premium", "purchase_token": "ptoken-1"})
    assert r.status_code == 200 and play.acked == ["ptoken-1"]
    assert ent(a["user"]["id"]).plan == "premium"
    # forged / misdirected pushes
    assert client.post("/v1/webhooks/google", json=rtdn()).status_code == 401
    assert client.post("/v1/webhooks/google", json=rtdn(), headers={"Authorization": f"Bearer {push_token(rsa_keys, aud='https://evil')}"}).status_code == 401
    assert client.post("/v1/webhooks/google", json=rtdn(), headers={"Authorization": f"Bearer {push_token(rsa_keys, email='x@evil.com')}"}).status_code == 401
    # revoked notification
    h = {"Authorization": f"Bearer {push_token(rsa_keys)}"}
    assert client.post("/v1/webhooks/google", json=rtdn(ntype=12, mid="m-2"), headers=h).json()["status"] == "ok"
    e = ent(a["user"]["id"])
    assert e.plan == "free" and e.revoked_at is not None
    assert client.post("/v1/webhooks/google", json=rtdn(ntype=12, mid="m-2"), headers=h).json()["status"] == "duplicate"


def test_google_purchase_for_other_account_rejected(client, app, rsa_keys):
    play = StubPlay()
    app.state.play_client = play
    a = sign_in(client, rsa_keys, "g-2")
    play.obf = "0" * 64
    r = client.post("/v1/billing/google/verify", headers=auth(a), json={"product_id": "kw.fils.premium", "purchase_token": "tok-x"})
    assert r.status_code == 409


def test_restore(client, app, rsa_keys, apple):
    a = sign_in(client, rsa_keys, "rs-1")
    r = client.post("/v1/billing/restore", headers=auth(a), json={"platform": "ios", "signed_transactions": [apple.sign(txn()), "garbage"]})
    assert r.status_code == 200 and r.json()["restore_errors"] == ["invalid_signed_payload"]
    assert ent(a["user"]["id"]).plan == "premium"


def test_apple_rejects_attacker_leaf_under_real_intermediate(client, rsa_keys, apple):
    """A self-made leaf claiming to be issued by the trusted intermediate must fail chain verification."""
    a = sign_in(client, rsa_keys, "buy-5")
    attacker = ec.generate_private_key(ec.SECP256R1())
    fake_leaf = _cert("Test StoreKit", "Test WWDR", attacker.public_key(), attacker, False, LEAF_OID)
    x5c = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in (fake_leaf, apple.inter, apple.root)]
    token = jwt.encode(txn(), attacker, algorithm="ES256", headers={"x5c": x5c})
    r = client.post("/v1/billing/apple/verify", headers=auth(a), json={"signed_transaction": token})
    assert r.status_code == 401
    assert ent(a["user"]["id"]) is None
