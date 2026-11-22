"""Speech provider abstraction: issues short-lived tokens; long-lived keys never leave the server."""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Protocol

import httpx

from ..config import Settings
from ..errors import APIError


@dataclass
class SpeechToken:
    provider: str
    region: str
    token: str
    expires_at: float


class SpeechProvider(Protocol):
    name: str
    enabled: bool

    def issue_token(self) -> SpeechToken: ...


class DisabledSpeech:
    name = "disabled"
    enabled = False

    def issue_token(self) -> SpeechToken:
        raise APIError(503, "provider_not_configured", "Cloud speech is not configured on this server")


class AzureSpeech:
    name = "azure"
    enabled = True
    TOKEN_LIFETIME = 600  # Azure STS tokens are valid for 10 minutes
    REUSE_FOR = 480

    def __init__(self, key: str, region: str, client: httpx.Client | None = None):
        if not (key and region):
            raise ValueError("Azure Speech key and region are required")
        self.key = key
        self.region = region
        self.client = client or httpx.Client(timeout=10.0)
        self._cached: SpeechToken | None = None
        self._lock = threading.Lock()

    def issue_token(self) -> SpeechToken:
        with self._lock:
            if self._cached and self._cached.expires_at - time.time() > self.TOKEN_LIFETIME - self.REUSE_FOR:
                return self._cached
            url = f"https://{self.region}.api.cognitive.microsoft.com/sts/v1.0/issueToken"
            try:
                r = self.client.post(url, headers={"Ocp-Apim-Subscription-Key": self.key, "Content-Length": "0"})
            except httpx.HTTPError as e:
                raise APIError(503, "provider_unavailable", "Speech provider unavailable") from e
            if r.status_code != 200:
                raise APIError(502, "provider_error", f"Speech provider returned {r.status_code}")
            tok = SpeechToken("azure", self.region, r.text.strip(), time.time() + self.TOKEN_LIFETIME)
            self._cached = tok
            return tok


def build_speech(settings: Settings) -> SpeechProvider:
    if settings.speech_provider == "azure" and settings.azure_speech_key and settings.azure_speech_region:
        return AzureSpeech(settings.azure_speech_key, settings.azure_speech_region)
    return DisabledSpeech()
