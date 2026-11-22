"""ASGI middleware: request ids + access log, security headers, body limits, rate limits, idempotency."""
from __future__ import annotations

import hashlib
import logging
import threading
import time
import uuid

from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from .config import get_settings
from .db import get_sessionmaker
from .errors import error_body
from .models import IdempotencyKey
from .security import decode_access_subject, sha256_hex

log = logging.getLogger("fils.access")


def _client_scope(request: Request) -> str:
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        sub = decode_access_subject(auth[7:].strip())
        if sub:
            return f"user:{sub}"
    ip = request.headers.get("x-forwarded-for", "").split(",")[0].strip() or (request.client.host if request.client else "unknown")
    return f"ip:{ip}"


class AccessLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        rid = request.headers.get("x-request-id") or uuid.uuid4().hex
        start = time.perf_counter()
        response = await call_next(request)
        response.headers["X-Request-Id"] = rid[:64]
        uid = getattr(request.state, "user_id", None)
        log.info(
            "request",
            extra={
                "method": request.method,
                "path": request.url.path,
                "status": response.status_code,
                "duration_ms": round((time.perf_counter() - start) * 1000, 1),
                "user": hashlib.sha256(uid.encode()).hexdigest()[:12] if uid else None,
                "request_id": rid[:64],
            },
        )
        return response


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("Cache-Control", "no-store")
        response.headers.setdefault("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
        response.headers.setdefault("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
        return response


class BodyLimitMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        s = get_settings()
        limit = s.max_upload_bytes + 64_000 if request.url.path.startswith("/v1/ingest/document") else s.max_body_bytes
        cl = request.headers.get("content-length")
        if cl is not None:
            try:
                if int(cl) > limit:
                    return JSONResponse(error_body("payload_too_large", "Request body too large"), status_code=413)
            except ValueError:
                return JSONResponse(error_body("bad_request", "Invalid Content-Length"), status_code=400)
        elif request.method in ("POST", "PUT", "PATCH"):
            body = await request.body()  # chunked: enforce after buffering (bounded by server limits)
            if len(body) > limit:
                return JSONResponse(error_body("payload_too_large", "Request body too large"), status_code=413)
        return await call_next(request)


class TokenBucketLimiter:
    """In-process token bucket. With several replicas each enforces its own share; documented."""

    def __init__(self):
        self._buckets: dict[tuple[str, str], tuple[float, float]] = {}
        self._lock = threading.Lock()

    def allow(self, key: tuple[str, str], per_minute: int) -> tuple[bool, float]:
        rate = per_minute / 60.0
        t = time.monotonic()
        with self._lock:
            tokens, last = self._buckets.get(key, (float(per_minute), t))
            tokens = min(float(per_minute), tokens + (t - last) * rate)
            if tokens >= 1:
                self._buckets[key] = (tokens - 1, t)
                return True, 0.0
            self._buckets[key] = (tokens, t)
            return False, (1 - tokens) / rate if rate else 60.0

    def reset(self):
        with self._lock:
            self._buckets.clear()


def route_group(path: str) -> str:
    if path.startswith("/v1/auth") or path.startswith("/v1/demo") or path.startswith("/v1/households/join"):
        return "auth"
    if path.startswith("/v1/assistant"):
        return "assistant"
    if path.startswith("/v1/ingest") or path.startswith("/v1/samples"):
        return "ingest"
    if path.startswith("/v1/voice"):
        return "voice"
    return "default"


class RateLimitMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, limiter: TokenBucketLimiter):
        super().__init__(app)
        self.limiter = limiter

    async def dispatch(self, request: Request, call_next):
        s = get_settings()
        if not s.rate_limit_enabled or request.url.path in ("/healthz", "/readyz") or request.url.path.startswith("/v1/webhooks"):
            return await call_next(request)
        group = route_group(request.url.path)
        per_min = s.rate_limits_per_minute.get(group, s.rate_limits_per_minute.get("default", 300))
        ok, retry = self.limiter.allow((_client_scope(request), group), per_min)
        if not ok:
            return JSONResponse(
                error_body("rate_limited", "Too many requests"),
                status_code=429,
                headers={"Retry-After": str(max(1, int(retry) + 1))},
            )
        return await call_next(request)


class IdempotencyMiddleware(BaseHTTPMiddleware):
    """Replays the stored response for a repeated Idempotency-Key with the same request body."""

    async def dispatch(self, request: Request, call_next):
        key = request.headers.get("idempotency-key")
        if not key or request.method not in ("POST", "PUT", "PATCH", "DELETE") or request.url.path.startswith("/v1/webhooks"):
            return await call_next(request)
        if len(key) > 128:
            return JSONResponse(error_body("invalid_idempotency_key", "Idempotency-Key too long"), status_code=400)
        body = await request.body()
        scope = _client_scope(request)
        req_hash = sha256_hex(request.method.encode() + b" " + request.url.path.encode() + b"\n" + body)
        Session = get_sessionmaker()
        with Session() as db:
            existing = db.get(IdempotencyKey, (scope, key))
            if existing is not None:
                if existing.request_hash != req_hash:
                    return JSONResponse(error_body("idempotency_mismatch", "Idempotency-Key reused with a different request"), status_code=409)
                if existing.status != "done":
                    return JSONResponse(error_body("idempotency_in_progress", "A request with this key is in progress"), status_code=409)
                return Response(
                    content=existing.response_body or b"",
                    status_code=existing.response_status or 200,
                    media_type=existing.response_content_type,
                    headers={"Idempotent-Replayed": "true"},
                )
            try:
                db.add(IdempotencyKey(scope=scope, key=key, request_hash=req_hash, status="pending"))
                db.commit()
            except IntegrityError:
                db.rollback()
                return JSONResponse(error_body("idempotency_in_progress", "A request with this key is in progress"), status_code=409)

        response = await call_next(request)
        chunks = [c async for c in response.body_iterator]
        content = b"".join(chunks)
        with Session() as db:
            if response.status_code >= 500 or response.status_code in (401, 429):
                # Not a definitive outcome: allow the client to retry with the same key.
                db.execute(delete(IdempotencyKey).where(IdempotencyKey.scope == scope, IdempotencyKey.key == key))
            else:
                row = db.scalar(select(IdempotencyKey).where(IdempotencyKey.scope == scope, IdempotencyKey.key == key))
                if row is not None:
                    row.status = "done"
                    row.response_status = response.status_code
                    row.response_body = content
                    row.response_content_type = response.media_type or response.headers.get("content-type")
            db.commit()
        headers = {k: v for k, v in response.headers.items() if k.lower() != "content-length"}
        return Response(content=content, status_code=response.status_code, headers=headers, media_type=response.media_type)
