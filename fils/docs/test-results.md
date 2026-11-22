# Test results (actually run, 2026-11-22)

Environment: Linux container, 4 vCPU, Flutter 3.50.1 / Dart 3.14.0, Python 3.13, PostgreSQL 16. **No physical iPhone or Android device and no emulator** (no KVM).

## Mobile (`fils/mobile`)

| Suite | Command | Result |
|---|---|---|
| Static analysis | `flutter analyze` | 0 errors, 0 warnings (about 30 style infos) |
| Unit, widget, perf and live E2E | `FILS_E2E_API=http://127.0.0.1:8099 flutter test test/core test/perf test/e2e` | **102 passed, 0 failed** |
| Parser fixtures (synthetic) | `test/core/parser_fixtures_test.dart` | 38/38: purchases EN/AR, Arabic digits, balance before amount, salary, transfers, ATM, declined, FX, refund, reversal, card payment, pending, installment, fee, processor, OTP rejection ×2, balance-only, promo, unknown → review, precision reject, injection text |
| Ledger invariants I1–I9 | `ledger_test.dart` | 10/10 |
| Ingestion and dedupe | `ingestion_test.dart` | 17/17: SMS+notification, replay, genuine repeats kept, Wallet+SMS, pending→settled, reversal voids, refund link, declined, ATM, transfer-leg merge, FX, review and retention purge |
| Voice parser | `voice_parser_test.dart` | 17/17, including «دفعت خمسة دنانير وربع على طلبات» → KWD 5.250 · Talabat |
| Assistant tools | `assistant_test.dart` | 6/6: Arabic merchant query, payday with cycle day 25, goal months, injection-safe, unknown → no invented numbers |
| Sync (fake server) | `sync_test.dart` | 4/4 |
| **App ↔ real backend E2E** | `test/e2e/backend_sync_e2e_test.dart` | 1/1, covering demo sign-in, `consent_required` before consent, a push of 13 entity types with no server rejections, pull on a second device, matching balances, conflict then resolve, tombstone, voice/AI consent then 503/disabled |
| Encryption at rest | `encryption_test.dart` | 1/1: no plaintext in the file, no key fails, wrong key fails, right key reads |
| CSV, sanitizer, recurrence | `csv_sanitizer_recurrence_test.dart` | 7/7 |

### Performance

From `test/perf/large_history_test.dart`, run on the host in a debug VM. Device numbers will differ.

| Measure | Target | Result |
|---|---|---|
| Insert 20,000 transactions | < 20 s | **12.6 s** |
| Full-history aggregation | < 300 ms | **10 ms** |
| First 60-row page query | < 100 ms | **10 ms** |
| Parse 1,000 messages | < 1 s | **319 ms** |

### Screenshots

- **Command:** `FILS_SCREENSHOTS=1 flutter test test/screenshots --update-goldens`
- **Output:** 40 renders, 10 screens × EN/AR × light/dark, published to `docs/screenshots/` (overview sheets: `overview_*.jpg`).
- **Issues found during visual review and fixed:**
  - Missing glyphs.
  - Inflated net-worth baseline.
  - Store plugin connecting in dev builds.
  - Ink hidden in cards: `FCard` reworked to paint with Material.
- **Run status:** earlier runs ended with "[E]" from the default 10-minute test timeout *after* all goldens were written. The timeout is now 40 minutes.

## Android builds

| Build | Result |
|---|---|
| `flutter build apk --debug --flavor play` | OK. Permissions: INTERNET, RECORD_AUDIO, USE_BIOMETRIC, POST_NOTIFICATIONS, BILLING. **No SMS permission.** `FilsNotificationListener` declared with BIND_NOTIFICATION_LISTENER_SERVICE. `libsqlite3mc.so` bundled for arm64-v8a, armeabi-v7a and x86_64 |
| `flutter build apk --debug --flavor sms` | OK. Package `kw.fils.fils.sms`, adds `RECEIVE_SMS` only |
| `flutter build apk --release --flavor play` | OK. 73 MB, R8 minified. **Unsigned** (no upload key configured) |

The builds needed retries because of Maven Central HTTP 429 rate-limiting through the proxy.

**iOS:** not built. That needs macOS and Xcode, and is configured in `.github/workflows/mobile-ci.yml` on `macos-15`. The Swift code has **not been compiled**.

## Backend (`fils/backend`)

| Suite | Result |
|---|---|
| `pytest` (real PostgreSQL) | **68 passed** |
| `ruff check .` | All checks passed |
| bandit (high) / pip-audit | No findings, as reported by the infra agent run |
| Alembic upgrade, downgrade and re-upgrade | Verified |
| Restore drill (`scripts/restore_drill.sh`) | PASSED: row counts match on 20 tables |
| Docker image | Built; `/healthz` and `/readyz` OK, running as uid 10001 |

## Not tested (and why)

- **Real-device behavior** (Shortcuts automation, lock-state behavior, notification redaction, process restarts, permission revocation): no hardware.
- **iOS compile:** no macOS.
- **Real bank message formats:** no consented samples.
- **Apple/Google sign-in with real tokens, StoreKit/Play purchases, Azure OpenAI/Speech:** no credentials.
- **Bicep compile and Azure deploy:** Bicep CLI download blocked; no Azure subscription access.
- **GitHub Actions workflows:** never executed; YAML parses.
