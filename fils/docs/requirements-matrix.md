# Requirements matrix

| Status | Meaning |
|---|---|
| **Implemented** | Code exists and compiles (`flutter analyze`: 0 errors / 0 warnings; backend imports and runs) |
| **Automated-tested** | Covered by tests that were actually run and pass (counts in [test-results.md](test-results.md)) |
| **Device-verified** | Verified on a real phone. **Nothing is device-verified yet:** no iPhone or Android device was available in the build environment |
| **Externally-blocked** | Needs credentials, accounts or hardware we don't have |

Paths: `M/` is `fils/mobile/`, `B/` is `fils/backend/`.

## Product and design

| Requirement | Implementation | Evidence | Status | Remaining blocker |
|---|---|---|---|---|
| Reference inventory (observed vs assumed) | `docs/reference-inventory.md` | Website and App Store screenshots inspected | Done | Authenticated SAY screens weren't available |
| Reusable design system | `M/lib/ui/theme/*`, `M/lib/ui/widgets/*` | Screenshots in `docs/screenshots/` | Implemented | — |
| SAY-like home, nav, rows, charts, wealth, chat, installments, goals | `M/lib/features/*` | Screenshots (EN/AR, light/dark) | Implemented, render-tested | Pixel comparison on a device |
| Arabic/English, RTL, mixed text | `M/lib/l10n/strings.dart`, `Directionality` on amounts | AR screenshots | Implemented | Native-speaker copy review |
| KWD with 3 decimals, Arabic digits | `M/lib/core/money/money.dart`, `M/lib/ui/format.dart` | `parser_fixtures_test`, `ledger_test` | Automated-tested | — |
| Asia/Kuwait reporting, salary cycle | `M/lib/core/time/kuwait_time.dart` | `assistant_test` (cycle day 25), ledger tests | Automated-tested | — |
| Multi-currency, never summed together | `totalsFor` (per currency), FX fields | `ledger_test` I8, ingestion FX test | Automated-tested | Live FX rates are not fetched (by design; bank-billed values are preferred) |
| Local merchant recognition | `M/lib/core/parsing/merchant_directory.dart` | Fixtures (Talabat, co-op, KNPC, Zain, MyFatoorah, Tabby…) | Automated-tested | Larger merchant list from real data |
| Accessibility (labels, touch targets, text scale) | Semantics throughout; text scale clamped at 1.6× | Code review | Implemented | Screen-reader pass on a device |

## Architecture, authentication and privacy

| Requirement | Implementation | Evidence | Status | Blocker |
|---|---|---|---|---|
| Flutter + native Swift/Kotlin | `M/ios/Runner/AppDelegate.swift`, `M/android/app/src/main/kotlin/...` | Android APK build (see test-results) | Implemented | iOS build needs macOS/Xcode |
| Encrypted local DB | sqlite3mc via `hooks.user_defines`, key in Keychain/Keystore (`M/lib/data/db/open.dart`) | `test/core/encryption_test.dart` | Automated-tested (Linux host build) | On-device check |
| Offline-first core | All features work on the local DB; cloud is optional | Every unit test runs without a network | Automated-tested | — |
| FastAPI + Postgres + durable worker | `B/fils_api/*`, `B/alembic`, `python -m fils_api.worker` | 68 backend tests on real Postgres | Automated-tested | — |
| Sign in with Apple / Google, server verification, nonce | `M/lib/data/auth/auth_service.dart`, `B/fils_api/services/auth_*` | Backend tests (RSA keys, patched JWKS); E2E demo session | Automated-tested (server) | Apple/Google client IDs and developer accounts |
| Token rotation, revocation, sessions, reauth | Backend, plus `M/lib/data/api/api_client.dart` | Backend tests (reuse detection) | Automated-tested | — |
| Biometric lock (separate from encryption) | `M/lib/app/app.dart` lock overlay, `local_auth` | Code | Implemented | Device |
| Account deletion, export | Backend jobs; mobile Settings | Backend tests; CSV formula escaping | Automated-tested (server) | — |
| Consent separation (login ≠ backup ≠ sync ≠ AI ≠ voice) | `LocalConsents` + `/v1/me/consents`; the server refuses sync without consent | E2E test asserts `consent_required` | Automated-tested | — |
| Demo mode, no release bypass | `DemoSeeder`; `/v1/demo/session` returns 404 in production | Backend test; demo goes through the real pipeline | Automated-tested | — |

## Transaction capture

| Requirement | Implementation | Evidence | Status | Blocker |
|---|---|---|---|---|
| iOS App Intent (message text and sender) | `ImportBankTransactionIntent` in `AppDelegate.swift`. Writes to an App Group inbox with `completeUntilFirstUserAuthentication` | Code only | Implemented | **Real iPhone + Shortcuts personal automation test** |
| iOS onboarding guide + test action | `M/lib/features/capture/capture_screen.dart`, `FilsTestCaptureIntent` | Screenshot | Implemented | Device |
| iOS Wallet transaction adapter | `ImportWalletTransactionIntent` (merchant/amount/card strings), dedupe against SMS | `ingestion_test` "Wallet + bank SMS merge" | Automated-tested (Dart side) | Which fields the trigger actually provides must be verified on iOS 17+ |
| Share extension (iOS) | Not built. iOS sharing uses paste instead | — | **Not implemented** | Needs an Xcode extension target |
| Android NotificationListenerService + allowlist | `FilsNotificationListener.kt`. Filters before reading; messaging apps blocked | APK compiles | Implemented | Device test: redaction, lock screen, restart |
| Android SMS (policy-compliant) | `sms` flavor only (`src/sms/`); the `play` flavor has no SMS permission | Manifest review | Implemented | Google Play Permissions Declaration approval |
| Paste / Android share / CSV import | Capture screen, `MainActivity` share intent, `csv_import.dart` | `csv_import_test`, ingestion | Automated-tested | — |
| PDF/image statements | Backend job `/v1/ingest/document` (CSV and PDF text; image OCR provider) | Backend tests | Implemented (server) | **Mobile upload UI isn't wired**; Document Intelligence credentials |
| Bank adapter registry + coverage matrix | `bank_registry.dart`; in-app coverage card | Fixtures labeled SYNTHETIC | Synthetic-tested only | **Real sanitized samples per bank** |
| Sanitized sample submission (opt-in, preview) | `sanitizer.dart`, review screen, `/v1/samples` | `sanitizer_test` | Automated-tested | — |

## Parsing, ledger and financial correctness

| Requirement | Evidence | Status |
|---|---|---|
| Common pipeline, deterministic first | `M/lib/data/ingestion.dart`; 38 synthetic fixtures | Automated-tested |
| OTP / balance / credit limit never taken as the amount | Fixtures `otp-*`, `credit-limit-not-amount`, `balance-only` | Automated-tested |
| AI fallback: consented, evidenced, sent to review | `M/lib/data/ai/cloud_ai.dart`; server evidence validation | Server tests; client re-validates. Azure OpenAI not configured |
| Dedupe (SMS+notification, Wallet+SMS, replay, pending→settled, genuine repeats) | `ingestion_test` (17 cases) | Automated-tested |
| Integer minor units; ledger invariants I1–I9 | `M/lib/core/ledger/ledger.dart`, `ledger_test` | Automated-tested |
| Transfers, ATM, card repayment, refunds, declined, opening balance, reconciliation | `ledger_test`, `ingestion_test` | Automated-tested |
| Calculated vs bank-reported balance labeled | Account detail, home note | Implemented |

## Features

| Feature | Location | Status |
|---|---|---|
| Onboarding (language, login, privacy, accounts, salary, capture) | `features/onboarding` | Implemented, render-tested |
| Home (spent, income, balances, recent, budget, payday estimate, capture status) | `features/home` | Implemented, render-tested |
| Transactions (search, filter, detail, edit, split, refund, transfer link, provenance, review, bulk + undo) | `features/transactions`, `features/review` | Implemented; logic tested |
| Accounts (multi, cash, masked, routing, reconcile, archive) | `features/accounts` | Implemented; reconcile tested |
| Budgets (cycle/monthly/weekly, rollover, thresholds) | `features/plans` | Implemented; usage tested |
| Goals (projection with stated assumptions) | `features/plans`, `recurrence.dart` | Implemented; projection tested via assistant |
| Recurring (confirm-only detection, never auto-posted) | `recurrence.dart` | Implemented |
| Analytics (category, merchant, daily, cash flow, previous-period comparison) | `features/insights` | Implemented, render-tested |
| Wealth / net worth (manual values, no double counting) | `features/wealth` | Implemented; double counting tested |
| Household (invites, roles, revoke) | Backend + `features/household` | Server-tested; mobile UI implemented |
| Settings (language, theme, privacy, sync, export, biometrics, subscription, deletion) | `features/settings` | Implemented |
| Local push notifications (budget/recurring reminders) | — | **Not implemented** (alerts are shown in-app only) |

## Voice and AI

| Requirement | Status | Blocker |
|---|---|---|
| Provider abstraction (device / Azure STT), text fallback, push-to-talk, visible recording, cancel, editable confirmation | Implemented (`speech_service.dart`, `voice_screen.dart`) | Azure Speech key/region; device test |
| "دفعت خمسة دنانير وربع على طلبات" → KWD 5.250 | Automated-tested (17 voice cases) | — |
| Azure neural TTS | **Not implemented**: device TTS is used | — |
| Assistant on typed deterministic tools; per-user; no SQL; injection-safe | Automated-tested (6 cases + server tests) | Azure OpenAI for the free-form cloud path |

## Backend, sync, billing and operations

| Requirement | Status | Blocker |
|---|---|---|
| Versioned API, OpenAPI, migrations, idempotency, ownership checks | Automated-tested (backend) | — |
| Local-first sync (outbox, conflicts, tombstones, owner isolation) | Automated-tested: unit (fake server) **and E2E against the real backend** | — |
| StoreKit 2 / Play Billing, server verification, webhooks, restore, dev unlock | Server tested with a self-made CA chain; client implemented | App Store Connect / Play Console products, Apple root CA file, Play service account |
| Azure IaC, CI/CD | Written; YAML parses | `bicep build` not run (CLI download blocked); never deployed (no Azure credentials) |
| Backup/restore drill | Ran locally on Postgres 16: PASSED | Azure PITR restore not exercised |
| Threat model, privacy notice, Kuwait regulatory notes | `docs/*.md` | Kuwaiti legal review |
