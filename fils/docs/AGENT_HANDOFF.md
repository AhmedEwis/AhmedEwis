# Reviewer handoff (for Codex)

## Your role: REVIEW ONLY

- Read the code, tests, configuration and docs. Identify defects, risks and gaps.
- Produce **implementation instructions**: what to change, where, why, and how to verify it.
- **Don't modify files, push commits or open PRs.** The Claude Code session that owns this branch makes all changes after the repository owner reviews your instructions.
- Treat every claim in these docs as something to check against the code and the CI logs.

## Snapshot

| Item | Value |
|---|---|
| Repository | https://github.com/AhmedEwis/AhmedEwis |
| Branch | `claude/kuwait-banks-aggregation-app-egj8k8` |
| **Code commit under review** | The commit stated in the handoff message that came with this ZIP (round 3: ingestion fixes). The previous review covered `2a0f1da` |
| What changed since your last review | See **Round 3** below and `fils/docs/test-results.md` §0 |
| Product | Fils (working name): local-first personal finance app for Kuwait. Flutter (iOS/Android) + FastAPI/PostgreSQL backend + Azure Bicep |
| Location | Everything lives under `fils/`. CI workflows are in the repo-root `.github/workflows/` |

## Round 3: response to your ingestion review

All four findings were reproduced with failing tests on the old code, then fixed. The results table is in `fils/docs/test-results.md` §0.

| Finding | Fix (in `fils/mobile/lib/data/ingestion.dart` unless noted) |
|---|---|
| 1. Non-atomic ingestion and races | `ingest()` runs one `db.transaction`: claim (`INSERT OR IGNORE`, the first write, which takes the SQLite write lock) → financial writes → source-event completion. Parsing and AI run outside the transaction. Schema v3 (`db/database.dart`) re-asserts the unique index `(source, platform_id)` on upgraded databases, renaming any existing duplicates. `CaptureService.drain` leaves a failed event un-acked and continues. Defined handling for missing or non-stable IDs: see `capture-runtime.md` |
| 2. Declined/pending/voided matching | Candidates are filtered by status: a decline matches only a decline, and a purchase never matches a declined or voided row. Pending settlement runs **before** cross-source matching |
| 3. Account routing and Wallet | `_accountsCompatible`: no merge across conflicting known accounts. Candidates already paired with the same source are skipped. More than one match goes to review. An Unassigned Wallet transaction moves to the bank account the later message identifies, in the same transaction. Unassigned is not created when the bank message came first |
| 4. Transfer false matches | Legs are linked only on evidence: the parser now extracts the counter account (`ParsedEvent.counterAccountLast4`, stored in `source_events.counter_last4`) and it must belong to the opposite leg's account. Without evidence, the leg is flagged for the user ("Link as transfer") |
| Found while preparing the device test | A Shortcut retry double-posted, because each run has a new ID. Now an identical Shortcut text within 24 hours is a recorded duplicate, and the banner says "Already in Fils" |
| Device path | `.github/workflows/ios-testflight.yml` (secret preflight, then archive, export, TestFlight upload), `ios/ExportOptions.plist`, `docs/device-acceptance.md` |

## Round 6: response to your fourth review (held-group identity, settlement predicate)

| Finding | Fix | Tests |
|---|---|---|
| 1. `_resolveHeldTwins` bulk update by hash, time and channel | Explicit `held_group` membership. Joining requires the same verified account (`_sameVerifiedAccount`); resolution touches only group members and re-verifies each | `held_identity_test.dart`: cross-bank × Same/Separate/Dismiss × both sides; conflicting accounts in one bank |
| 2. `_isSettlementOf` lacked incoming guards | Requires an incoming `purchase` with `posted` status inside the shared predicate | Shortcut repeat → Same → stays pending; settlement → one transaction at 11.000 |

## Round 5: response to your third review (settlement ambiguity, Dismiss)

| Finding | Fix | Tests |
|---|---|---|
| 1. Settlement picks the first authorization | All qualifying authorizations are collected. One is settled directly; more than one is held, and **Same transaction** settles exactly the chosen offered authorization, atomically. Cross-source re-deliveries are never applied as a second settlement: they join a held original, or merge into the applied one | `settlement_dismiss_test.dart` |
| 2. Unconditional Dismiss | `dismissHeld`: a conditional `status = held` update in a transaction; held re-deliveries follow it | both orders; 24 races on two connections |

## Round 4: response to your second ingestion review

| Finding | Fix |
|---|---|
| 1. Hard Shortcut-text duplicate | Removed. Same-sender, compatible-account repeats without a stable platform ID are **held**: a source event with status `held`, no transaction, input kept and candidate IDs stored. The Review inbox offers *Same transaction* or *Separate purchase* (`confirmSameTransaction` / `confirmSeparate`, atomic and idempotent) |
| 2. Text-equality early return | Removed. Text twins join the candidate pool and pass the same `_eligible` checks as semantic matches. The only exception is a reversal re-delivered through another channel, which may match the authorization it voided |
| 3. Ambiguous matches counted | Ambiguous matches are held with no transaction. `needsReview` transactions still count (category-only review). See `test-results.md` §0a |
| TestFlight prep | `archive-unsigned` job (a real `xcodebuild archive` with signing off; checks the extension, bundle IDs and versions) |

## Where to start (in order)

1. `fils/README.md`: layout and quick start.
2. `fils/docs/requirements-matrix.md`: requirement → implementation → evidence → status.
3. `fils/docs/test-results.md`: exactly what ran, with commands and results.
4. `fils/docs/capture-runtime.md`: capture pipeline, headless processing, Wallet input contract.
5. `fils/docs/security-threat-model.md` and `fils/docs/privacy.md`.
6. `fils/docs/api-contract.md` (the deviations are listed at the top) and `fils/backend/openapi.json`.
7. `fils/docs/release-and-signing.md`: identifiers, production isolation, signing steps.
8. `fils/docs/bank-samples.md`: bank coverage (synthetic only) and the real-sample workflow.
9. `fils/docs/CHECKPOINT.md`: resume notes and next actions.

## Implemented features

### Capture and parsing
- Deterministic Kuwait parser, Arabic and English, with exact 3-decimal KWD.
- OTP, promo and balance rejection, so none of these is ever taken as a transaction amount.
- Ingestion pipeline with deduplication:
  - SMS and notification of the same event merged.
  - Wallet and SMS for the same purchase merged.
  - Replays rejected.
  - Genuine repeated purchases kept and flagged.
  - A pending authorization and its settlement counted once.
  - Reversals and refunds linked to the original.
- Unknown or low-confidence messages go to the **Review inbox**.

### Ledger
- Integer minor units (no floats for money).
- Invariants I1–I9 (`mobile/lib/core/ledger/ledger.dart`): transfers, ATM, card purchase and repayment, refunds, declined, opening balances, multiple currencies, reconciliation.

### Native capture
- **iOS:**
  - App Intents: `ImportBankTransactionIntent`, `ImportWalletTransactionIntent`, `FilsTestCaptureIntent`.
  - App Group file inbox (`CaptureInbox.swift`, protection class `completeUntilFirstUserAuthentication`).
  - **Share Extension** target.
  - **Headless Flutter engine** (`HeadlessCapture.swift`) running the Dart entrypoint `lib/capture_main.dart`.
- **Android:**
  - `FilsNotificationListener` (user-selected apps only; messaging apps blocked).
  - `HeadlessCaptureRunner`.
  - `sms` flavor `SmsReceiver`. The `play` flavor has **no** SMS permission.
- The UI shows each pipeline stage separately: Securely queued, Posted, Awaiting review, Ignored.

### Data and sync
- Encrypted local database (SQLite3MultipleCiphers; key in Keychain/Keystore with first-unlock-this-device accessibility). WAL + busy timeout.
- Drift schema v2 (migration v1→v2 adds `shared_records`).
- Local-first sync: outbox, versions, conflicts, tombstones, owner binding, consent gating.

### Household sharing
- Explicit per-record share, implemented as a field-whitelisted copy with a household placeholder account.
- Consent sheet before sharing.
- Viewers are read-only.
- Revoke propagates; leaving or being removed purges local copies.
- Shared copies are stored outside the personal ledger, so they never affect personal balances.

### Other app features
- **Screens:** home, transactions (split, refund, link as transfer, bulk edit with undo), accounts and reconciliation, budgets, goals, recurring payments, insights, wealth (net worth), assistant (deterministic tools, optional cloud LLM through the backend), voice (device or Azure speech-to-text; Azure neural text-to-speech with fallback), settings and consents, paywall, onboarding, biometric lock.
- **Local notifications:** bill and recurring reminders at 09:00 Kuwait time; budget thresholds once per period; time-zone safe.

### Backend (FastAPI)
- Apple/Google token verification with JWKS and nonce.
- Rotating refresh tokens with reuse detection; re-authentication; sessions.
- Consents; export; account deletion job.
- Sync with household scoping.
- Households and invitations.
- StoreKit 2 JWS and App Store Server Notifications V2; Play verification and real-time developer notifications.
- LLM, document-extraction and speech-token gateways (each reports "not configured" without credentials).
- Postgres job queue and worker; rate limits; log redaction; Alembic migrations.

### Infrastructure and CI
- Bicep: Container Apps (API + worker), PostgreSQL Flexible Server, Key Vault, Storage, Container Registry, monitoring, managed identity, networking.
- Workflows: `mobile-ci` (Android + iOS on macOS), `backend-ci`, `infra-validate`, `security`, `deploy-backend` (manual).

## Tests actually run

| Suite | Result | Where |
|---|---|---|
| Mobile unit/widget + perf + **live-backend E2E** (`FILS_E2E_API=… flutter test test/core test/perf test/e2e`) | **127 passed, 0 failed** | Local, commit `67e8950`; fixes re-tested at `1973769` |
| `flutter analyze` | 0 errors, 0 warnings (about 39 style infos) | Local and CI |
| Backend `pytest` (real PostgreSQL 16) | **68 passed** | Local, `1973769` |
| Backend `ruff` | Clean | Local |
| Screenshots (`FILS_SCREENSHOTS=1 flutter test test/screenshots --update-goldens`) | **exit 0**, 40 PNGs, 0 exceptions, about 47 s | Local, `1973769` |
| Bicep build (main + 2 parameter files) | 0 warnings; parameter files fail without the PG password, as intended | Local Bicep 0.31.92 and CI |
| Perf (20,000 transactions) | Insert about 11–14 s, aggregate about 10–16 ms, first page about 10–14 ms, parse 1,000 messages about 320–340 ms | Local (debug VM) |
| Restore drill (`backend/scripts/restore_drill.sh`) | PASSED: row counts match on 20 tables | Local Postgres |

### CI runs (GitHub Actions)

| Workflow | Run | Commit | Result |
|---|---|---|---|
| mobile-ci (Android test + APKs + `aapt2` no-SMS check; **iOS device build, Share Extension check, iOS simulator build** on macos-15) | [45070252714](https://github.com/AhmedEwis/AhmedEwis/actions/runs/45070252714) | `2a0f1da` | success |
| mobile-ci (same jobs; log evidence quoted in test-results.md §4) | [45069143801](https://github.com/AhmedEwis/AhmedEwis/actions/runs/45069143801) | `1973769` | success |
| security (gitleaks, dependency review) | [45070252725](https://github.com/AhmedEwis/AhmedEwis/actions/runs/45070252725) | `2a0f1da` | success |
| infra-validate (Bicep) | [45068424926](https://github.com/AhmedEwis/AhmedEwis/actions/runs/45068424926) | `47c8a5e` (no infra changes since) | success |
| backend-ci | [45057153228](https://github.com/AhmedEwis/AhmedEwis/actions/runs/45057153228) | `dd24437` | success. `fils_api` hasn't changed since; later backend verification ran locally |

E2E tests don't run in CI (no backend service in the mobile workflow). They ran locally against `uvicorn` and Postgres.

## Awaiting external verification (nothing below is verified)

### Real device (none was available)
- iOS:
  - Shortcuts Message automation calling the App Intent.
  - Headless engine starting inside the intent, and the intent finishing within Shortcuts' time limits.
  - Behavior while locked, and before the first unlock after a reboot.
  - Share Extension from Messages.
- Wallet Transaction automation: its field contract comes from community and forum sources, not Apple documentation.
- Android:
  - Notification content availability and redaction.
  - Headless runner starting from the listener service.
  - Behavior after process death or reboot; battery optimization effects.
- Local notification delivery; Azure text-to-speech audio playback; biometric lock; Sign in with Apple/Google flows; StoreKit/Play purchases.

### Real bank messages
- All six adapters (Warba, KFH, NBK, Boubyan, Gulf Bank, CBK) are **synthetic-tested only**. Sender IDs are assumptions.
- Known channel risks:
  - NBK is moving alerts to in-app push notifications, which iOS can't read.
  - Boubyan uses Apple Messages for Business; whether the Shortcuts trigger sees those is unknown.

### Credentials
- Apple team and App IDs with capabilities; Google OAuth client IDs (placeholders in `ios/Flutter/Fils.xcconfig`).
- Azure OpenAI, Azure Speech and Document Intelligence.
- Store products; Android upload key; Apple Root CA file for the backend.
- Azure subscription with OIDC for `what-if` and deploy. Nothing is deployed.

### Legal
- Kuwaiti review of the items in `docs/kuwait-regulatory.md`.

## Known remaining gaps and design limits

- Household budgets compare limits against shared transactions only. There's no per-member breakdown.
- The Wallet intent takes `amount` as a string. If iOS passes a currency type, the parameter type may need adapting.
- Cloud AI fallback runs only in the UI app, never headlessly. Headless runs are deterministic only.
- Statement OCR for images depends on Document Intelligence (not configured).
- No crash-reporting SDK is integrated.
- `fils/mobile/android/build/reports/problems/problems-report.html` is a build artifact accidentally tracked in git. It's excluded from the review ZIP; removing it from the repo is a pending cleanup.

## Key architecture decisions

1. **Local-first.** The ledger lives on the device. Sign-in, backup, sync, cloud AI and cloud voice are separate consents. Sync never uploads history without explicit consent.
2. **Deterministic numbers.** The assistant's LLM only picks tools. The tools run on the device over local data, and every answer's numbers come from code (`core/assistant/tools.dart`).
3. **Shared Dart pipeline for all capture paths.** iOS and Android native code only filters and queues. Parsing and the ledger run in Dart, either in the UI engine or in a headless engine (`capture_main.dart`), against the same encrypted database.
4. **Household = explicit copies** in a separate table (`SharedRecords`). The personal ledger never contains other members' data.
5. **Android distribution split.** The `play` flavor has no SMS permission. The `sms` flavor exists only for builds that get approval under Google Play's SMS policy.
6. **Server-side verification** of identity tokens, StoreKit/Play purchases and webhooks. The app never self-grants entitlements outside development and staging.

## Files worth close review

| Area | Files |
|---|---|
| Parser | `mobile/lib/core/parsing/kuwait_parser.dart`, `bank_registry.dart`, `merchant_directory.dart`, `sanitizer.dart`; `fixtures/messages/v1/synthetic_kw.json` |
| Ledger/ingestion | `mobile/lib/core/ledger/ledger.dart`, `mobile/lib/data/ingestion.dart`, `mobile/lib/data/store.dart` |
| DB/encryption | `mobile/lib/data/db/database.dart`, `mobile/lib/data/db/open.dart`, `mobile/pubspec.yaml` (`hooks.user_defines`) |
| Sync/household | `mobile/lib/data/sync/sync_engine.dart`, `mobile/lib/data/household/household_sharing.dart`, `backend/fils_api/services/sync.py`, `sync_schemas.py` |
| Native iOS | `mobile/ios/Runner/AppDelegate.swift`, `CaptureInbox.swift`, `CaptureChannels.swift`, `HeadlessCapture.swift`, `mobile/ios/ShareExtension/*`, `mobile/ios/scripts/add_share_extension.rb`, `Runner.xcodeproj/project.pbxproj`, entitlements |
| Native Android | `mobile/android/app/src/main/kotlin/kw/fils/fils/*`, `src/sms/*`, `AndroidManifest.xml`, `app/build.gradle.kts` |
| Headless | `mobile/lib/capture_main.dart`, `mobile/lib/native/capture_bridge.dart` |
| Notifications/voice/AI | `mobile/lib/core/notifications/planner.dart`, `mobile/lib/data/notifications/notification_service.dart`, `mobile/lib/data/voice/*`, `mobile/lib/data/ai/cloud_ai.dart`, `mobile/lib/core/assistant/*` |
| Release guards | `mobile/lib/app/config.dart`, `release_guards.dart`, `mobile/lib/main.dart` |
| Backend auth/billing | `backend/fils_api/services/auth*`, `backend/fils_api/services/*apple*`, `*google*`, `backend/fils_api/config.py` |
| Infra/CI | `infra/azure/main.bicep`, `infra/azure/modules/*`, `.github/workflows/*.yml` |
| Tests | `mobile/test/core/*`, `mobile/test/e2e/*`, `mobile/test/perf/*`, `mobile/test/screenshots/*`, `backend/tests/*` |

## Suggested review focus

- **Security and privacy:** what leaves the device and when; consent enforcement on both sides; household data minimization; token storage; log redaction; Keychain/Keystore accessibility versus headless needs.
- **Financial correctness:** ledger invariants; deduplication false positives and negatives; FX handling; refunds and reversals; review routing for uncertain parses.
- **Native correctness without devices:** App Intent behavior and time limits; headless engine lifecycle and concurrency with the UI engine; Share Extension constraints; Android listener lifecycle.
- **Release isolation and store policy:** Google Play SMS/notification-access policy; Apple App Review risks (automations, intents, Sign in with Apple requirement).
- **Gaps between docs and code:** any status claim not backed by a test or a CI log.

## Output format we'd like from you

A numbered list of findings, ordered by severity. For each finding:
- **Severity:** critical, high, medium or low.
- **Location:** file and line.
- **Problem:** with evidence.
- **Fix:** concrete implementation instructions.
- **Verification:** how to verify the fix (a test to add or a command to run).
- **Device or credential needed?** Whether it requires a device or credentials.
