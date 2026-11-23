# Checkpoint (resume point)

- **Branch:** `claude/kuwait-banks-aggregation-app-egj8k8`
- **Final commit:** see the bottom of `docs/test-results.md` §4

## State

All code-side scope is implemented. What remains needs devices, credentials or real data, as listed below.

**Added in round 2:**
- iOS Share Extension (Xcode target added by `ios/scripts/add_share_extension.rb`, which is idempotent).
- Headless capture on iOS and Android (`lib/capture_main.dart`, `HeadlessCapture.swift`, `HeadlessCaptureRunner.kt`).
- Capture pipeline status UI.
- Local notifications.
- Azure neural TTS with fallback.
- Household sharing UI with a privacy model (schema v2).
- Release guards and static configuration tests.
- Bicep fixes and the `infra-validate` CI workflow.
- Bank-sample workflow.
- Screenshot-suite hang fix.

**CI:** GitHub Actions on this repo works and is the iOS compile path (`mobile-ci` → `build-ios` on macos-15).

**Round 3 (Codex ingestion review):**
- Atomic, race-safe ingestion and schema v3.
- Status-aware and account-safe deduplication.
- Transfer linking only on evidence.
- Shortcut retry is idempotent.
- TestFlight workflow and the device acceptance checklist (`docs/device-acceptance.md`).

**iOS install status:**
- Compiled (CI, unsigned): yes.
- Unsigned `xcodebuild archive` passes, with the extension embedded and versions matching.
- Signed: no. Uploaded: no. Installable: no.
- Blocked on an Apple Developer Program membership and an App Store Connect API key added as GitHub secrets (`docs/release-and-signing.md`).

**Feature freeze (device-test build 0.3.0):**
- Only fixes go in until local-core acceptance passes on real devices.
- The build, install and acceptance split are in `docs/device-test-build.md`: local core in `docs/device-acceptance.md`, cloud features in `docs/cloud-acceptance.md` (blocked).
- Schema is v4.

## Rebuilding the local environment

1. Install Flutter 3.50.1 to `/opt/flutter`.
2. Install the Android SDK to `/opt/android-sdk` with `platforms;android-36`, `platforms;android-37` and `build-tools;36.0.0`.
3. Network hosts needed: `dl.google.com`, Maven Central (it rate-limits; the build loop retries on 429), `storage.googleapis.com`, `github.com` (sqlite3mc binaries and the Bicep CLI).
4. Start the backend:
   ```
   pg_ctlcluster 16 main start
   cd fils/backend
   FILS_ENV=development FILS_DATABASE_URL=postgresql+psycopg://fils:fils@localhost:5432/fils .venv/bin/uvicorn fils_api.main:app --port 8099
   ```
5. Run the E2E tests: `FILS_E2E_API=http://127.0.0.1:8099 flutter test test/e2e`.
6. Run the screenshots: `FILS_SCREENSHOTS=1 FILS_EMOJI_FONT=<NotoColorEmoji.ttf> flutter test test/screenshots --update-goldens`. The font comes from `google/fonts` `ofl/notocoloremoji`.

## Next actions

### Needs devices (owner: user / QA)
1. **iPhone (iOS 17+), TestFlight or Xcode build with a team:**
   - Shortcuts Message automation with "Test Fils Capture".
   - A real bank SMS while unlocked, while locked, and before the first unlock after a reboot.
   - Share from Messages.
   - Wallet Transaction automation: record the actual field values.
   - Notification delivery.
2. **Android phone:**
   - Grant notification access and pick the bank apps.
   - Capture with the app closed (headless), after a reboot, and after revoking the permission.
   - Check notifications and battery optimization behavior.

### Needs data
3. Real sanitized samples per bank, following `docs/bank-samples.md`.

### Needs credentials
4. Apple team and capabilities, Google OAuth client IDs (`ios/Flutter/Fils.xcconfig` plus dart-defines), Azure OpenAI and Speech, store products, the Android upload key, and Azure subscription OIDC for `what-if` and deploy.

### Code follow-ups (not blocking)
- Household budgets currently compare the budget against shared transactions only (by design: personal data stays private). The UI could offer per-member contribution breakdowns.
- The Wallet intent's `amount` arrives as a string. If device testing shows Shortcuts passes a currency-typed value, adapt the parameter type.
