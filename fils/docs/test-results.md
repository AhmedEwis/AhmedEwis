# Verification results

Only checks that were actually run are listed.

- **Local environment:** Linux container, Flutter 3.50.1 / Dart 3.14.0, Python 3.13, PostgreSQL 16.
- **CI:** GitHub Actions (ubuntu-24.04, macos-15).
- **Devices:** no physical iPhone or Android device, and no emulator (no KVM).

## 1. Automated tests

| Suite | Command | Result | Commit |
|---|---|---|---|
| Mobile unit/widget + perf + live-backend E2E | `FILS_E2E_API=http://127.0.0.1:8099 flutter test test/core test/perf test/e2e` | **127 passed, 0 failed** (exit 0) | `67e8950` + wipe/dispose fixes in `1973769` (lifecycle test re-run: pass) |
| Mobile analyzer | `flutter analyze` | **0 errors, 0 warnings** | `1973769` |
| Backend | `cd fils/backend && .venv/bin/pytest` | **68 passed** | `1973769` |
| Backend lint | `ruff check .` | All checks passed | — |
| Mobile CI tests on GitHub | `flutter test` (E2E skipped without a backend) | see §4 | — |

New regression suites added this round, all passing:

| Area | Test file | What it proves |
|---|---|---|
| Household privacy and revocation | `test/e2e/household_e2e_test.dart` (two real users, live backend), `test/core/household_migration_test.dart` | Only the selected record is shared, as a field-whitelisted copy. No account, card digits, note, raw text or IDs leak. Shared copies never enter either ledger; personal totals are unchanged. Viewers can't share. Revoke propagates. Removal purges local copies. v1→v2 migration preserves data |
| Notifications | `test/core/notifications_test.dart` | 09:00 Kuwait D-1 reminders; past reminders skipped; idempotent reschedule; delete, pause and date change cancel the old ID; budget alert once per threshold per period, surviving a restart; time-zone independent; no permission means nothing scheduled |
| Voice TTS | `test/core/azure_tts_test.dart` | SSML injection escaped; bearer token; temp file deleted; HTTP, network or token failure falls back to device TTS; cancel during synthesis plays nothing |
| Offline capture and restart recovery | `test/core/capture_recovery_test.dart` | Headless pipeline summary; crash before ack replays without double-posting; Wallet zero/blank values go to review; unknown or ambiguous messages never post |
| Release isolation | `test/core/release_config_test.dart` | Production guards; production config problems detected; Play manifest has no SMS permissions; `sms` flavor matches its implementation; identifiers consistent across iOS, Android, Dart and backend; no sensitive logging |
| Deletion/export | `test/core/lifecycle_test.dart` | Export contains the data. Wipe clears all tables (shared copies, outbox, consents) and reseeds categories |

**Bugs found by these runs and fixed:**
1. `wipeAll()` violated foreign keys whenever transactions existed, which broke "Erase data" and the local wipe in account deletion. Found by `lifecycle_test`.
2. `ref` was used in `dispose()` in the Assistant and Voice screens, and teardown speech calls could throw unhandled errors. Found by the screenshot suite.
3. The screenshot suite hung for 10 minutes per variant: the database was closed while widgets with live stream queries were mounted, and fake-async timers weren't flushed.

## 2. Screenshots

| Field | Value |
|---|---|
| Command | `FILS_SCREENSHOTS=1 FILS_EMOJI_FONT=<NotoColorEmoji.ttf> flutter test test/screenshots --update-goldens` |
| Result | **exit 0, 4 tests (EN/AR × light/dark) passed, 40 PNGs, 0 framework exceptions**, about 47 s total |
| Root cause of earlier timeouts | Teardown order (see bug 3). Rendering all 10 screens takes about 12 s per variant. Timeout set to 3 minutes |
| Commit | `1973769` (the code state of this run) |
| Output | `docs/screenshots/*.jpg` and `overview_{en,ar}_{light,dark}.jpg` |
| Visual review | RTL mirroring correct (nav order, alignment, Arabic dates, د.ك amounts); dark-mode contrast readable; no clipping or overflow; new capture-pipeline card renders. Not covered by the demo data: the household feed (no household in demo) and permission-denied states (no platform plugins in the test host) |

## 3. Builds

| Build | Where | Result |
|---|---|---|
| Android `play` debug APK | local | OK. No SMS permissions (`aapt2`) |
| Android `sms` debug APK | local | OK. Adds only `RECEIVE_SMS` |
| Android `play` release APK | local | OK. R8 minified, **unsigned** (no upload key) |
| **Android test APK** `fils-0.2.0-test-arm64-profile.apk` | local | OK. Profile build, **signed with the Android SDK debug keystore** (`CN=Android Debug`, SHA-256 `2538ae05…73db`), FILS_ENV=development, offline, compileSdk 37 / targetSdk 36 |
| iOS device build (no codesign) | GitHub Actions macos-15 | see §4 |
| iOS simulator build | GitHub Actions macos-15 | see §4 |
| Bicep `main.bicep` + 2 param files | local Bicep 0.31.92 + CI `infra-validate` | **Compile OK, 0 warnings**. Param files correctly fail without `FILS_PG_ADMIN_PASSWORD`. CI run `45068424926`: success |

## 4. CI results (GitHub Actions)

**Run [`45069143801`](https://github.com/AhmedEwis/AhmedEwis/actions/runs/45069143801), commit `1973769`: all jobs succeeded.**

| Job / step | Result | Evidence from the log |
|---|---|---|
| test-android: `flutter analyze` | success | — |
| test-android: `flutter test` | success | E2E skipped (no backend in CI) |
| test-android: debug APK `play` | success | — |
| test-android: release-config check (`aapt2`: no SMS permissions) | success | — |
| test-android: release APK (unsigned) | success | APKs uploaded as the `android-apks` artifact |
| **build-ios: device build** (`flutter build ios --release --no-codesign`) | **success** | `✓ Built build/ios/iphoneos/Runner.app (29.3MB)` on macOS 15.8.2 (macos-15-arm64) |
| **build-ios: Share Extension embedded + entitlements** | **success** | `Share extension OK` (`PlugIns/ShareExtension.appex` present, `com.apple.share-services`, `group.kw.fils` in both entitlements files) |
| **build-ios: simulator build** (`flutter build ios --simulator --debug`) | **success** | `✓ Built build/ios/iphonesimulator/Runner.app` |
| infra-validate (run `45068424926`) | success | Bicep compile with no warnings, param files, missing-secret failure check |
| security (gitleaks, dependency review) | success | — |

Earlier, the iOS build of the round-1 code (run `45063252369`, commit `fe81cdd`) also succeeded: `✓ Built build/ios/iphoneos/Runner.app (28.4MB)`.

**What the CI iOS results do NOT prove:**
- **Runtime behavior.** Not exercised: App Intent execution in Shortcuts, headless engine start inside an intent, Share Extension UI, Keychain access while locked, notification delivery.
- **Signed builds.** No signing identity was used.
- **App Store compliance review.**

These remain device or credential items.

The final handoff commit (version bump and docs) re-runs the same workflow. Its run ID is reported in the handoff message.
