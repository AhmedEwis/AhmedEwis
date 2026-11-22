"""Structured JSON logging with redaction. Message text, tokens and emails never reach logs."""
from __future__ import annotations

import json
import logging
import re
import sys
from datetime import UTC, datetime

_REDACTIONS = [
    (re.compile(r"(?i)bearer\s+[a-z0-9._\-]+"), "Bearer [REDACTED]"),
    (re.compile(r"eyJ[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+"), "[JWT]"),
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "[EMAIL]"),
    (re.compile(r"(?<!\d)\d{8,19}(?!\d)"), "[NUMBER]"),
    (re.compile(r"(?i)(api[-_]?key|password|secret|token|refresh_token|identity_token|id_token)([\"'=:\s]+)[^\s\"',}]+"), r"\1\2[REDACTED]"),
]

SENSITIVE_KEYS = {"text", "message_text", "sanitized_text", "payload", "authorization", "token", "refresh_token", "body"}


def redact(value: str) -> str:
    for pat, rep in _REDACTIONS:
        value = pat.sub(rep, value)
    return value


class JSONFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        out = {
            "ts": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": redact(record.getMessage()),
        }
        for k, v in record.__dict__.items():
            if k in ("method", "path", "status", "duration_ms", "user", "request_id", "error_type", "job_id", "job_kind"):
                out[k] = v
            elif k in SENSITIVE_KEYS:
                out[k] = "[REDACTED]"
        if record.exc_info:
            out["exc"] = redact(self.formatException(record.exc_info))[-4000:]
        return json.dumps(out, ensure_ascii=False)


def setup_logging(level: str = "INFO") -> None:
    root = logging.getLogger()
    root.handlers.clear()
    h = logging.StreamHandler(sys.stdout)
    h.setFormatter(JSONFormatter())
    root.addHandler(h)
    root.setLevel(level)
    logging.getLogger("uvicorn.access").disabled = True  # replaced by our redacted access log
    # httpx logs full URLs (Play purchase tokens are path segments); alembic is chatty on /readyz.
    for noisy in ("httpx", "httpcore", "alembic"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
