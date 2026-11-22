# Fils API (backend)

FastAPI, SQLAlchemy 2, Alembic and PostgreSQL, plus a separately deployable worker that uses a Postgres
job queue (`FOR UPDATE SKIP LOCKED`). The API contract is in `../docs/api-contract.md`; the generated
spec is `openapi.json`, also served at `/v1/openapi.json`.

## Layout

| Path | What it holds |
|---|---|
| `fils_api/main.py` | App factory: middleware, providers, routers |
| `fils_api/config.py` | All settings, read from `FILS_*` environment variables. Staging and production refuse to start without `FILS_JWT_SECRET` and `FILS_DATA_KEY`. |
| `fils_api/models.py` | Schema. `alembic/versions/0001_initial_schema.py` is the migration. |
| `fils_api/security.py` | Backend access tokens (about 15 min), reauth tokens (5 min), the session-checked current-user dependency |
| `fils_api/providers/identity.py` | Apple and Google ID-token verification against JWKS (iss, aud, exp, signature, nonce) |
| `fils_api/routers/auth.py` | Nonce, Apple and Google sign-in, rotating refresh tokens with reuse detection, logout, reauth, identity linking, demo session (outside production only) |
| `fils_api/routers/me.py` | Profile, sessions, append-only consents, export, account deletion, jobs |
| `fils_api/services/sync.py` + `sync_schemas.py` | Versioned push/pull, conflicts, tombstones, household scope, strict per-entity validation, reference ownership checks |
| `fils_api/routers/households.py` | Households, hashed single-use invitation codes, roles (owner, member, viewer), removal |
| `fils_api/routers/ingest.py` | Consent-gated AI extraction with evidence validation and an OTP guard, document upload, parser samples |
| `fils_api/routers/assistant.py` | LLM proxy. Tools run on the device; consent, rate and monthly token budget are enforced here. |
| `fils_api/routers/voice.py` | Short-lived Azure Speech token issuance |
| `fils_api/routers/billing.py` + `services/apple_jws.py` + `services/google_play.py` | StoreKit 2 JWS chain verification, App Store Server Notifications V2, Play subscriptionsv2, RTDN with OIDC verification, entitlements |
| `fils_api/worker.py` | Export (ZIP: JSON plus formula-safe CSV), account hard delete, statement extraction (CSV, PDF, image through the OCR provider), retention cleanup |
| `fils_api/middleware.py` | Request ids and redacted access log, security headers, body limits, token-bucket rate limits, idempotency keys |

## Run locally

```bash
python3.13 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
cp .env.example .env                         # dev defaults work without secrets
export FILS_DATABASE_URL=postgresql+psycopg://fils:fils@localhost:5432/fils
.venv/bin/alembic upgrade head
.venv/bin/uvicorn fils_api.main:app --reload     # API on :8000, docs at /docs (not in production)
.venv/bin/python -m fils_api.worker              # in a second shell
```

Or use Docker: `docker compose up --build`. This runs Postgres, then migrations, then the API and the
worker. Behind a TLS-intercepting proxy, pass the extra CA as a build secret:
`docker build --secret id=pip_ca,src=/path/ca.crt .`. The CA is never stored in the image.

## Tests

The tests need a Postgres database named `fils_test` that is owned by `fils`/`fils`:

```bash
createdb -O fils fils_test
.venv/bin/pytest
```

The suite migrates the database `base → head` at session start and truncates all tables between tests.

## Environments

- `development` / `staging` / `test`: every feature is unlocked (`entitlements.source = "dev_unlocked"`)
  and `POST /v1/demo/session` is available.
- `production`: entitlements come only from verified store purchases. The demo endpoint and `/docs` return 404.
  The `fake` LLM provider is refused.

## External setup still required

| Capability | Configure | Until it's configured |
|---|---|---|
| Sign in with Apple | `FILS_APPLE_CLIENT_IDS` (bundle id) | Works with any bundle id in the list |
| Google Sign-In | `FILS_GOOGLE_CLIENT_IDS` (iOS, Android and web client ids) | `503 provider_not_configured` |
| Azure OpenAI | `FILS_LLM_PROVIDER=azure_openai` + endpoint, key, deployment | Assistant/extract return `503` or `status: disabled` |
| Azure Speech | `FILS_SPEECH_PROVIDER=azure` + key, region | `/v1/voice/token` returns `503` (the app falls back to on-device speech) |
| Document Intelligence | endpoint + key | Image statement jobs fail with `provider_not_configured`. CSV and PDF work. |
| Apple billing | `fils_api/certs/AppleRootCA-G3.cer` (run `scripts/fetch_apple_root.sh`), product ids, and the App Store Server Notifications URL set to `https://<host>/v1/webhooks/apple` in App Store Connect | `503 billing_not_configured` |
| Google billing | `FILS_GOOGLE_SERVICE_ACCOUNT_JSON` (Play Console API access), RTDN Pub/Sub push subscription with OIDC to `/v1/webhooks/google`, `FILS_GOOGLE_PUBSUB_AUDIENCE` and `FILS_GOOGLE_PUBSUB_SERVICE_ACCOUNT` | `503 billing_not_configured` |

## Design notes and known limits

- **Sync ordering**: pushes take a global transaction-scoped advisory lock, so commit order matches
  `change_seq` order and pull cursors never skip a record. This serialises pushes; it's fine for the
  launch scale. Shard the lock per user and household if push throughput becomes a bottleneck.
- **Rate limiting** is in-process. With N replicas the effective limit is N times the configured value.
  Use Azure Front Door/APIM rate limiting, or a shared store, before scaling out.
- **No end-to-end encryption**: the server can read synced payloads. Postgres (Azure) encrypts them at
  rest, and temporary uploads and exports are additionally AES-GCM encrypted with `FILS_DATA_KEY` and
  purged after 24 hours.
- Uploaded statements are deleted as soon as extraction finishes. Candidate rows are dropped from job
  results after 24 hours.
