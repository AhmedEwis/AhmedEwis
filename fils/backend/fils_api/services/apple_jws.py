"""StoreKit 2 / App Store Server Notifications V2 JWS verification.

Verifies the x5c chain (leaf -> Apple WWDR intermediate -> trusted Apple root), Apple's
marker OIDs, certificate validity, and the ES256 signature with the leaf key.
"""
from __future__ import annotations

import base64
import json
from datetime import UTC, datetime
from pathlib import Path

import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.x509.oid import ObjectIdentifier

from ..errors import APIError

LEAF_OID = ObjectIdentifier("1.2.840.113635.100.6.11.1")
INTERMEDIATE_OID = ObjectIdentifier("1.2.840.113635.100.6.2.1")


class JWSVerificationError(Exception):
    pass


def load_roots(paths: list[str], base: Path | None = None) -> list[x509.Certificate]:
    roots = []
    for p in paths:
        path = Path(p)
        if not path.is_absolute() and base is not None:
            path = base / path
        if not path.exists():
            continue
        data = path.read_bytes()
        cert = x509.load_pem_x509_certificate(data) if b"-----BEGIN" in data else x509.load_der_x509_certificate(data)
        roots.append(cert)
    return roots


def _b64json(seg: str) -> dict:
    pad = "=" * (-len(seg) % 4)
    return json.loads(base64.urlsafe_b64decode(seg + pad))


def _has_ext(cert: x509.Certificate, oid: ObjectIdentifier) -> bool:
    try:
        cert.extensions.get_extension_for_oid(oid)
        return True
    except x509.ExtensionNotFound:
        return False


def _valid_at(cert: x509.Certificate, when: datetime) -> bool:
    return cert.not_valid_before_utc <= when <= cert.not_valid_after_utc


def verify_jws(token: str, trusted_roots: list[x509.Certificate], at: datetime | None = None) -> dict:
    if not trusted_roots:
        raise APIError(503, "billing_not_configured", "Apple root certificate is not installed on the server")
    parts = token.split(".")
    if len(parts) != 3:
        raise JWSVerificationError("malformed JWS")
    try:
        header = _b64json(parts[0])
    except Exception as e:  # noqa: BLE001
        raise JWSVerificationError("malformed header") from e
    if header.get("alg") != "ES256":
        raise JWSVerificationError("unexpected alg")
    x5c = header.get("x5c")
    if not isinstance(x5c, list) or len(x5c) != 3:
        raise JWSVerificationError("x5c chain must contain 3 certificates")
    try:
        leaf, inter, root = (x509.load_der_x509_certificate(base64.b64decode(c)) for c in x5c)
    except Exception as e:  # noqa: BLE001
        raise JWSVerificationError("invalid certificate in chain") from e

    root_fp = root.fingerprint(hashes.SHA256())
    trusted = next((r for r in trusted_roots if r.fingerprint(hashes.SHA256()) == root_fp), None)
    if trusted is None:
        raise JWSVerificationError("chain does not end in a trusted Apple root")
    when = at or datetime.now(UTC)
    for c in (leaf, inter, trusted):
        if not _valid_at(c, when):
            raise JWSVerificationError("certificate outside validity period")
    if not _has_ext(leaf, LEAF_OID) or not _has_ext(inter, INTERMEDIATE_OID):
        raise JWSVerificationError("missing Apple marker extensions")
    try:
        inter.verify_directly_issued_by(trusted)
        leaf.verify_directly_issued_by(inter)
    except Exception as e:  # noqa: BLE001
        raise JWSVerificationError("certificate chain signature invalid") from e
    try:
        return jwt.decode(token, leaf.public_key(), algorithms=["ES256"], options={"verify_aud": False, "verify_exp": False})
    except jwt.PyJWTError as e:
        raise JWSVerificationError("JWS signature invalid") from e


def ms_to_dt(ms: int | None) -> datetime | None:
    if ms is None:
        return None
    return datetime.fromtimestamp(int(ms) / 1000, UTC)
