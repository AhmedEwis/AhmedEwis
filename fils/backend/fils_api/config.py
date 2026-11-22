"""Runtime configuration. All values come from environment variables (prefix FILS_)."""
from __future__ import annotations

import base64
import hashlib
from functools import lru_cache
from typing import Literal

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="FILS_", env_file=".env", extra="ignore")

    env: Literal["development", "staging", "production", "test"] = "development"
    database_url: str = "postgresql+psycopg://fils:fils@localhost:5432/fils"
    log_level: str = "INFO"

    # Token signing (HS256). MUST be set (>= 32 bytes) outside development/test.
    jwt_secret: str = ""
    jwt_issuer: str = "fils-api"
    access_ttl_seconds: int = 900
    refresh_ttl_days: int = 60
    reauth_ttl_seconds: int = 300
    nonce_ttl_seconds: int = 600

    # Envelope key for temporary blobs (base64, 32 bytes). Required outside dev/test.
    data_key: str = ""

    # Identity providers
    apple_client_ids: list[str] = Field(default_factory=lambda: ["kw.fils.fils"])
    google_client_ids: list[str] = Field(default_factory=list)
    apple_jwks_url: str = "https://appleid.apple.com/auth/keys"
    google_jwks_url: str = "https://www.googleapis.com/oauth2/v3/certs"

    # CORS: empty = disabled (mobile clients don't need it)
    cors_origins: list[str] = Field(default_factory=list)

    # Limits
    max_body_bytes: int = 1_000_000
    max_upload_bytes: int = 10_000_000
    rate_limit_enabled: bool = True
    rate_limits_per_minute: dict[str, int] = Field(
        default_factory=lambda: {"auth": 20, "assistant": 30, "ingest": 60, "voice": 30, "default": 300}
    )

    # AI
    llm_provider: Literal["disabled", "azure_openai", "fake"] = "disabled"
    azure_openai_endpoint: str = ""
    azure_openai_api_key: str = ""
    azure_openai_deployment: str = ""
    azure_openai_api_version: str = "2024-10-21"
    assistant_monthly_token_budget: int = 200_000
    assistant_max_messages: int = 40
    assistant_max_chars: int = 24_000

    # Speech
    speech_provider: Literal["disabled", "azure"] = "disabled"
    azure_speech_key: str = ""
    azure_speech_region: str = ""
    speech_stt_locales: list[str] = Field(default_factory=lambda: ["ar-KW", "ar-SA", "ar-EG", "en-US", "en-GB"])
    speech_tts_voice_ar: str = "ar-KW-NouraNeural"
    speech_tts_voice_en: str = "en-US-AvaNeural"

    # Documents
    document_intelligence_endpoint: str = ""
    document_intelligence_key: str = ""
    temp_blob_ttl_hours: int = 24

    # Billing
    apple_bundle_id: str = "kw.fils.fils"
    apple_product_ids: list[str] = Field(default_factory=lambda: ["kw.fils.premium.monthly", "kw.fils.premium.yearly"])
    apple_root_ca_paths: list[str] = Field(default_factory=lambda: ["fils_api/certs/AppleRootCA-G3.cer"])
    apple_allow_sandbox: bool = True
    google_package_name: str = "kw.fils.fils"
    google_product_ids: list[str] = Field(default_factory=lambda: ["kw.fils.premium"])
    google_service_account_json: str = ""  # JSON content (from Key Vault), not a path
    google_pubsub_audience: str = ""
    google_pubsub_service_account: str = ""
    billing_grace_days: int = 16

    # Worker
    worker_poll_seconds: float = 2.0
    job_max_attempts: int = 5
    job_stale_minutes: int = 15

    @field_validator("env")
    @classmethod
    def _env(cls, v: str) -> str:
        return v

    @model_validator(mode="after")
    def _check_secrets(self) -> "Settings":
        if self.env in ("staging", "production"):
            if len(self.jwt_secret.encode()) < 32:
                raise ValueError("FILS_JWT_SECRET must be at least 32 bytes in staging/production")
            if not self.data_key:
                raise ValueError("FILS_DATA_KEY is required in staging/production")
        return self

    @property
    def is_production(self) -> bool:
        return self.env == "production"

    @property
    def features_unlocked(self) -> bool:
        """Dev/staging/test expose every feature (explicitly labelled dev_unlocked)."""
        return self.env != "production"

    def effective_jwt_secret(self) -> bytes:
        if self.jwt_secret:
            return self.jwt_secret.encode()
        # Deterministic dev-only secret; refused in staging/production by the validator above.
        return hashlib.sha256(b"fils-dev-only-secret").digest()

    def effective_data_key(self) -> bytes:
        if self.data_key:
            key = base64.b64decode(self.data_key)
            if len(key) != 32:
                raise ValueError("FILS_DATA_KEY must decode to 32 bytes")
            return key
        return hashlib.sha256(b"fils-dev-only-data-key").digest()


@lru_cache
def get_settings() -> Settings:
    return Settings()
