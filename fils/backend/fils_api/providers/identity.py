"""Verification of Apple / Google ID tokens against their published JWKS."""
from __future__ import annotations

import json
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

import httpx
import jwt
from jwt.algorithms import RSAAlgorithm

from ..errors import APIError

JWKSFetcher = Callable[[str], dict]


def http_fetch_jwks(url: str) -> dict:
    r = httpx.get(url, timeout=5.0)
    r.raise_for_status()
    return r.json()


class JWKSCache:
    def __init__(self, url: str, fetcher: JWKSFetcher = http_fetch_jwks, ttl: int = 3600, min_refetch: int = 30):
        self.url = url
        self.fetcher = fetcher
        self.ttl = ttl
        self.min_refetch = min_refetch
        self._keys: dict[str, object] = {}
        self._fetched_at = 0.0
        self._lock = threading.Lock()

    def _refresh(self) -> None:
        data = self.fetcher(self.url)
        keys = {}
        for k in data.get("keys", []):
            if k.get("kty") == "RSA" and "kid" in k:
                keys[k["kid"]] = RSAAlgorithm.from_jwk(json.dumps(k))
        self._keys = keys
        self._fetched_at = time.time()

    def get_key(self, kid: str):
        with self._lock:
            stale = time.time() - self._fetched_at > self.ttl
            if stale or (kid not in self._keys and time.time() - self._fetched_at > self.min_refetch):
                try:
                    self._refresh()
                except httpx.HTTPError as e:
                    if not self._keys:
                        raise APIError(503, "identity_provider_unavailable", "Could not fetch provider keys") from e
            key = self._keys.get(kid)
        if key is None:
            raise APIError(401, "invalid_provider_token", "Unknown signing key")
        return key


@dataclass
class VerifiedIdentity:
    provider: str
    subject: str
    email: str | None
    email_verified: bool
    nonce: str | None
    claims: dict


class IdentityVerifier:
    def __init__(self, provider: str, cache: JWKSCache, issuers: list[str], audiences_getter: Callable[[], list[str]]):
        self.provider = provider
        self.cache = cache
        self.issuers = issuers
        self.audiences_getter = audiences_getter

    def verify(self, token: str) -> VerifiedIdentity:
        audiences = self.audiences_getter()
        if not audiences:
            raise APIError(503, "provider_not_configured", f"{self.provider} sign-in is not configured")
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError as e:
            raise APIError(401, "invalid_provider_token", "Malformed token") from e
        if header.get("alg") != "RS256" or "kid" not in header:
            raise APIError(401, "invalid_provider_token", "Unexpected token algorithm")
        key = self.cache.get_key(header["kid"])
        try:
            claims = jwt.decode(
                token,
                key=key,
                algorithms=["RS256"],
                audience=audiences,
                options={"require": ["exp", "iat", "iss", "aud", "sub"]},
                leeway=30,
            )
        except jwt.ExpiredSignatureError as e:
            raise APIError(401, "provider_token_expired", "Provider token expired") from e
        except jwt.PyJWTError as e:
            raise APIError(401, "invalid_provider_token", "Provider token rejected") from e
        if claims.get("iss") not in self.issuers:
            raise APIError(401, "invalid_provider_token", "Wrong issuer")
        ev = claims.get("email_verified")
        email_verified = ev is True or (isinstance(ev, str) and ev.lower() == "true")
        return VerifiedIdentity(
            provider=self.provider,
            subject=str(claims["sub"]),
            email=claims.get("email"),
            email_verified=email_verified,
            nonce=claims.get("nonce"),
            claims=claims,
        )


def build_verifiers(settings, fetcher: JWKSFetcher = http_fetch_jwks) -> dict[str, IdentityVerifier]:
    return {
        "apple": IdentityVerifier(
            "apple",
            JWKSCache(settings.apple_jwks_url, fetcher),
            ["https://appleid.apple.com"],
            lambda: settings.apple_client_ids,
        ),
        "google": IdentityVerifier(
            "google",
            JWKSCache(settings.google_jwks_url, fetcher),
            ["https://accounts.google.com", "accounts.google.com"],
            lambda: settings.google_client_ids,
        ),
    }
