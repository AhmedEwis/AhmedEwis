# Fils (فلس): personal finance for Kuwait

Fils is the working name; it's configurable through `FILS_APP_NAME_EN` / `FILS_APP_NAME_AR`. It is a local-first expense tracker:

- It captures bank messages through iPhone Shortcuts, Android bank-app notifications, Apple Pay Wallet automations, paste, share and CSV.
- It parses Kuwaiti bank messages in Arabic and English with a deterministic engine.
- It keeps an exact ledger in integer fils.
- It offers voice entry and an assistant that only quotes numbers computed on the device.

**Not an official app of any bank. It never asks for bank passwords and never initiates payments.**

## Repository layout

| Path | What |
|---|---|
| `mobile/` | Flutter app (iOS + Android): `lib/core` (pure logic), `lib/data` (DB, sync, API), `lib/features` (screens), native code in `ios/Runner/AppDelegate.swift` and `android/app/src/{main,sms}/kotlin` |
| `backend/` | FastAPI + PostgreSQL + worker ([backend/README.md](backend/README.md)) |
| `fixtures/messages/v1/` | Versioned **synthetic** parser fixtures (provenance stated in the file) |
| `infra/azure/` | Bicep IaC (Container Apps, PostgreSQL Flexible Server, Key Vault, Storage, monitoring) |
| `docs/` | Architecture, API contract, security, privacy, ops, store, regulatory, requirements matrix, test results, screenshots |
| `../.github/workflows/` | CI (backend, mobile, security) and manual deploy |

## Quick start

```bash
# Backend (needs Postgres; or use docker compose in backend/)
cd backend && python -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
export FILS_ENV=development FILS_DATABASE_URL=postgresql+psycopg://fils:fils@localhost:5432/fils
.venv/bin/alembic upgrade head && .venv/bin/uvicorn fils_api.main:app --port 8000
.venv/bin/pytest                      # 68 tests

# Mobile (Flutter 3.50.1)
cd mobile && flutter pub get && dart run build_runner build --delete-conflicting-outputs
flutter test                          # unit / widget tests (E2E skipped unless FILS_E2E_API is set)
FILS_E2E_API=http://127.0.0.1:8000 flutter test test/e2e     # app ↔ live backend
flutter run --flavor play --dart-define=FILS_ENV=development \
  --dart-define=FILS_API_BASE_URL=http://10.0.2.2:8000          # Android emulator → local API
```

Without `FILS_API_BASE_URL`, the app runs fully offline. On the first screen, **Explore with demo data** loads clearly labeled synthetic data through the real ingestion pipeline.

Android flavors:
- `play` is the default build, with notification capture and no SMS permission.
- `sms` is only for distribution after Google Play approves the SMS permission declaration.

## Status

See [docs/requirements-matrix.md](docs/requirements-matrix.md) and [docs/test-results.md](docs/test-results.md).

**Nothing has been verified on a physical device yet. No bank format has been verified with real messages yet.**
