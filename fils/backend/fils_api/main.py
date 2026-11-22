from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .errors import install_error_handlers
from .logging_setup import setup_logging
from .middleware import (
    AccessLogMiddleware,
    BodyLimitMiddleware,
    IdempotencyMiddleware,
    RateLimitMiddleware,
    SecurityHeadersMiddleware,
    TokenBucketLimiter,
)
from .providers.identity import JWKSCache, build_verifiers
from .providers.llm import build_llm
from .providers.speech import build_speech
from .routers import assistant, auth, billing, health, households, ingest, me, sync, voice
from .services.apple_jws import load_roots
from .services.google_play import NotConfiguredPlayClient, ServiceAccountPlayClient

BASE_DIR = Path(__file__).resolve().parents[1]


def create_app() -> FastAPI:
    s = get_settings()
    setup_logging(s.log_level)
    app = FastAPI(
        title="Fils API",
        version="1.0.0",
        description="Backend for the Fils personal-finance app (Kuwait). Money is integer minor units.",
        openapi_url="/v1/openapi.json",
        docs_url=None if s.is_production else "/docs",
        redoc_url=None,
    )
    app.state.identity_verifiers = build_verifiers(s)
    app.state.llm = build_llm(s)
    app.state.speech = build_speech(s)
    app.state.apple_roots = load_roots(s.apple_root_ca_paths, BASE_DIR)
    app.state.play_client = ServiceAccountPlayClient(s.google_service_account_json) if s.google_service_account_json else NotConfiguredPlayClient()
    app.state.google_oidc_cache = JWKSCache(s.google_jwks_url)
    app.state.rate_limiter = TokenBucketLimiter()

    install_error_handlers(app)
    # Order: last added runs first.
    app.add_middleware(IdempotencyMiddleware)
    app.add_middleware(RateLimitMiddleware, limiter=app.state.rate_limiter)
    app.add_middleware(BodyLimitMiddleware)
    app.add_middleware(SecurityHeadersMiddleware)
    app.add_middleware(AccessLogMiddleware)
    if s.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=s.cors_origins, allow_methods=["GET", "POST", "DELETE"], allow_headers=["*"])

    for r in (health, auth, me, sync, ingest, assistant, voice, households, billing):
        app.include_router(r.router)
    return app


app = create_app()
