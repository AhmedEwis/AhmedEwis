"""Google Play Developer API (subscriptionsv2) client and Pub/Sub push OIDC verification."""
from __future__ import annotations

import json
import time
from datetime import datetime
from typing import Protocol

import httpx
import jwt

from ..errors import APIError
from ..providers.identity import JWKSCache

ANDROIDPUBLISHER = "https://androidpublisher.googleapis.com/androidpublisher/v3"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"


class PlayClient(Protocol):
    def get_subscription(self, package: str, token: str) -> dict: ...
    def acknowledge(self, package: str, product_id: str, token: str) -> None: ...


class NotConfiguredPlayClient:
    def get_subscription(self, package: str, token: str) -> dict:
        raise APIError(503, "billing_not_configured", "Google Play billing is not configured on the server")

    def acknowledge(self, package: str, product_id: str, token: str) -> None:
        raise APIError(503, "billing_not_configured", "Google Play billing is not configured on the server")


class ServiceAccountPlayClient:
    def __init__(self, service_account_json: str, client: httpx.Client | None = None):
        info = json.loads(service_account_json)
        self.email = info["client_email"]
        self.private_key = info["private_key"]
        self.token_uri = info.get("token_uri", "https://oauth2.googleapis.com/token")
        self.client = client or httpx.Client(timeout=15.0)
        self._token: tuple[str, float] | None = None

    def _access_token(self) -> str:
        if self._token and self._token[1] - time.time() > 60:
            return self._token[0]
        iat = int(time.time())
        assertion = jwt.encode(
            {"iss": self.email, "scope": SCOPE, "aud": self.token_uri, "iat": iat, "exp": iat + 3600},
            self.private_key,
            algorithm="RS256",
        )
        r = self.client.post(
            self.token_uri,
            data={"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion},
        )
        if r.status_code != 200:
            raise APIError(502, "billing_provider_error", "Could not authenticate with Google Play")
        body = r.json()
        self._token = (body["access_token"], time.time() + int(body.get("expires_in", 3600)))
        return self._token[0]

    def get_subscription(self, package: str, token: str) -> dict:
        r = self.client.get(
            f"{ANDROIDPUBLISHER}/applications/{package}/purchases/subscriptionsv2/tokens/{token}",
            headers={"Authorization": f"Bearer {self._access_token()}"},
        )
        if r.status_code in (400, 404, 410):
            raise APIError(422, "invalid_purchase", "Google Play does not recognise this purchase")
        if r.status_code != 200:
            raise APIError(502, "billing_provider_error", f"Google Play returned {r.status_code}")
        return r.json()

    def acknowledge(self, package: str, product_id: str, token: str) -> None:
        r = self.client.post(
            f"{ANDROIDPUBLISHER}/applications/{package}/purchases/subscriptions/{product_id}/tokens/{token}:acknowledge",
            headers={"Authorization": f"Bearer {self._access_token()}"},
            json={},
        )
        if r.status_code not in (200, 204):
            raise APIError(502, "billing_provider_error", "Could not acknowledge purchase")


def parse_rfc3339(s: str | None) -> datetime | None:
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


ACTIVE_STATES = {"SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"}


def verify_pubsub_oidc(token: str, cache: JWKSCache, audience: str, service_account: str) -> dict:
    if not audience or not service_account:
        raise APIError(503, "billing_not_configured", "Pub/Sub push verification is not configured")
    try:
        header = jwt.get_unverified_header(token)
        key = cache.get_key(header.get("kid", ""))
        claims = jwt.decode(token, key=key, algorithms=["RS256"], audience=audience, options={"require": ["exp", "iat", "iss", "aud"]})
    except APIError:
        raise APIError(401, "invalid_push_token", "Push token rejected")
    except jwt.PyJWTError as e:
        raise APIError(401, "invalid_push_token", "Push token rejected") from e
    if claims.get("iss") not in ("https://accounts.google.com", "accounts.google.com"):
        raise APIError(401, "invalid_push_token", "Wrong issuer")
    if claims.get("email") != service_account or claims.get("email_verified") not in (True, "true"):
        raise APIError(401, "invalid_push_token", "Unexpected push service account")
    return claims
