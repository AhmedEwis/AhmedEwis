# Verification results

Only checks that were actually run are listed.

- **Local environment:** Linux container, Flutter 3.50.1 / Dart 3.14.0, Python 3.13, PostgreSQL 16.
- **CI:** GitHub Actions (ubuntu-24.04, macos-15).
- **Devices:** no physical iPhone or Android device, and no emulator (no KVM).

## 0a. Codex review, round 2: dedupe paths and unresolved duplicates

**Reproduction:** five tests written against the previous commit (`55a6ec4`) using only `ingest()`. **All 5 failed there**, and all pass now.

| Finding | Repro test | Before | After |
|---|---|---|---|
| 1. Shortcut text hard-classified as duplicate, ignoring identity | Identical Shortcut text from a different sender | 1 transaction (second purchase lost) | 2 |
| 1. | Same-sender Shortcut repeat | `duplicate` (dropped) | `possibleDuplicate`: held for review, no ledger effect |
| 2. Text-equality early return bypasses account and status checks | Identical text: NBK SMS vs KFH notification, both own a card •1234 | 1 (merged across banks) | 2 |
| 2. | Identical text via another source after the first record was deleted | `merged` into the deleted record | posted |
| 3. Ambiguous match counted | Two Wallet KWD 1.500, then an ambiguous bank message | spending **4.500** | **3.000** |

**New regression tests:**
- `test/core/dedupe_resolution_test.dart` (10 tests):
  - Ambiguous: held at 3.000.
  - **Same transaction:** stays 3.000. A crash mid-resolution leaves it held. Double tap, a contradictory late tap and a tap after restart are no-ops. Replay of the bank message is a duplicate. No new transaction in the sync outbox.
  - **Separate purchase:** **4.500 exactly once**, under the same crash, retry and restart checks. Exactly one new transaction in the outbox, and it counts normally (not flagged).
  - A purchase that only needs category review still counts.
  - Identical text from different banks and accounts (with and without card digits), different senders (paste, Shortcut), and deleted or voided records.
  - The same reversal arriving through a second channel produces no bogus refund.
- `test/e2e/dedupe_sync_e2e_test.dart` (live backend, two devices):
  - Held captures never reach the server.
  - Device B's spending is 6.000 while held, and 7.500 after one separate and one same resolution.
  - Retried resolutions change nothing on either device.
- Updated to the held behavior: `ingestion_test`, `ingestion_review_test`, `capture_recovery_test`, `device_scenario_test`.

**Also fixed:** under parallel load, the two-connection test once hit `SQLITE_BUSY` (`database is locked` on `BEGIN IMMEDIATE`) after the 5-second busy timeout. Ingestion and resolution now retry lock timeouts with backoff, up to 5 attempts. Across 4 consecutive full runs, there were no failures.

**Full run:** `FILS_E2E_API=http://127.0.0.1:8099 flutter test test/core test/perf test/e2e` → **159 passed, 0 failed**. `flutter analyze` → **0 errors, 0 warnings**.

**CI at `21f5638`:**
- `mobile-ci` run `45107105491`: success. Android tests passed. The iOS device build (no codesign) and the simulator build both succeeded.
- `security` run `45107105612`: success.
- `ios-testflight` run `45107105550`:
  - `archive-unsigned`: success. The log reads *"Archive OK: app 0.2.0 (3000), extension embedded, versions match. UNSIGNED: not installable."*
  - preflight: *"Missing secrets: APPLE_TEAM_ID APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY. No signed build attempted."*

The dry-run had first **failed** at `c929c31` (run `45105809463`): the Share Extension's `Info.plist` had no `CFBundleVersion`, which App Store Connect would reject. This was fixed in `21f5638` by adding `ShareExtension.xcconfig`, which includes only `Flutter/Generated.xcconfig`.

**Screenshots:** `FILS_SCREENSHOTS=1 … flutter test test/screenshots --update-goldens` → 4 variants passed. The Review screen now shows the held card (*Same transaction / Separate purchase / Dismiss*) in EN, AR (RTL), light and dark.

## 0. Codex ingestion review: reproduce, fix, regression-test

Every test below was first run against the unfixed code (`0be447d`), with only a no-op test hook added so it compiles. **11 of the 16 new tests failed there**, which reproduces every reported issue. The other 5 are guards against overcorrection (same-source decline, repeated purchases, linking with evidence, the existing unique index, paste without an ID). With the fixes, all of them pass.

| Issue | Regression test (file → test) | Before fix | After fix |
|---|---|---|---|
| 1. Crash after the financial write, before the source event completes | `ingestion_review_test` → *failure after the financial insert…* | **FAIL**: transaction left behind with no source event | pass: nothing persisted; replay posts once, then `duplicate` |
| 1. Replay after restart | same test, plus `capture_recovery_test` → *process killed… replay* and *an event whose ingestion fails is not acked or lost* | n/a (new) | pass |
| 1. Concurrent ingestion over two connections (same file, WAL) | `ingestion_review_test` → *concurrent ingestion…* (1 shared event plus 20 distinct events × 2 connections) | **FAIL**: `SqliteException(2067) UNIQUE constraint failed` after the 2nd connection had already inserted its transaction | pass: exactly one transaction per event, none lost |
| 1. Unique index on upgraded databases; missing IDs | `household_migration_test` → *v2 → v3…*; `ingestion_review_test` → *events without a platform id…* | n/a (new) | pass: duplicates renamed `#dup-<id>`, not deleted; index enforced; paste without an ID is processed and flagged |
| 2. Declined → successful purchase | *declined then successful purchase (cross-source)* | **FAIL**: merged into the declined row (purchase lost) | pass |
| 2. Pending → settlement through another source | *pending (SMS) then settlement…* | **FAIL**: `merged` instead of `settledPending` (pending row never settled) | pass |
| 2. Reversed/voided → new purchase | *reversed/voided authorization then a new purchase* | **FAIL**: merged into the voided row | pass |
| 3. Same amount and merchant on different known accounts | *identical amount/merchant on two different known accounts* | **FAIL**: merged into 1 | pass: 2 |
| 3. Wallet first (Unassigned), bank second | *Wallet first…* | **FAIL**: 2 transactions | pass: 1, moved to the bank account; Unassigned balance 0 |
| 3. Bank first, Wallet second | *bank message first, Wallet second* | **FAIL**: Unassigned account created | pass |
| 3. Two genuine repeated purchases | *two genuine repeated purchases* | pass | pass |
| 3. Ambiguous match | *ambiguous match (two candidates) goes to review* | **FAIL**: silently merged | pass: review |
| 4. Unrelated KWD 20 in and KWD 20 out | *unrelated incoming KWD 20 and outgoing KWD 20…* | **FAIL**: linked as an internal transfer | pass: separate |
| 4. Same amount, no evidence | *same amount without evidence is flagged…* | **FAIL**: auto-linked | pass: separate, one flagged for the user to confirm |
| 4. Evidence (message names the owned counter account) | *outgoing that references the receiving owned account* | pass | pass |
| Device scenario: Shortcut retry of the same SMS | `capture_recovery_test` → *the same SMS imported twice through Shortcuts…*; `device_scenario_test` | Found during this review: each Shortcut run has a new ID, so a retry double-posted | pass: counted once; retries recorded as `duplicate` |

**Full run after the fixes:** `FILS_E2E_API=http://127.0.0.1:8099 flutter test test/core test/perf test/e2e` → **148 passed, 0 failed**. `flutter analyze` → **0 errors, 0 warnings**. The backend is unchanged in this round.

**CI at `15700e1`:**
- `mobile-ci` run `45079936104`: success. Android tests passed. The iOS device build (release, no codesign) and the simulator build both succeeded.
- `security` run `45079936108`: success.
- `ios-testflight` run `45079936350`: the preflight reports *"Missing secrets: APPLE_TEAM_ID APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY. No signed build attempted."*

So the iOS app is compiled, but not signed, not uploaded and not installable.

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
