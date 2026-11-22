# Checkpoint (resume point for the next session)

- **Date:** 2026-11-22
- **Branch:** `claude/kuwait-banks-aggregation-app-egj8k8`

## Done

- **Phases 1 to 4: complete.** Design system, all screens, native capture code, parser, ledger, ingestion, sync, auth, voice, AI, billing, household and settings are built. See [requirements-matrix.md](requirements-matrix.md).
- **Backend:** complete, 68 tests passing.
- **App↔backend E2E sync test:** passing against a local Postgres.
- **Infra and CI:** written. Bicep has not been compiled and nothing has been deployed.
- **Docs:** architecture, security, privacy, ops, store, regulatory, reference inventory.

## How to rebuild the environment

1. Install Flutter 3.50.1 to `/opt/flutter`.
2. Install the Android SDK (`cmdline-tools` plus `platforms;android-36` and `build-tools;36.0.0`) to `/opt/android-sdk`, then run `flutter config --android-sdk`.
3. Network hosts needed:
   - `dl.google.com` (Android SDK)
   - Maven Central (it rate-limits; retry the Gradle build if you get 429)
   - `storage.googleapis.com` (Flutter)
   - `github.com` (sqlite3mc binaries downloaded by the `sqlite3` build hook)
4. Backend: Postgres 16. Run `pg_ctlcluster 16 main start` (databases `fils` and `fils_test`, user `fils`/`fils`).

## Next steps, in priority order

1. **Real-device verification**
   - iPhone: build in Xcode with an Apple Developer team, set the App Group `group.kw.fils` on the Runner target, create the Shortcuts Message automation, run "Test Fils Capture", then send a real bank SMS.
   - Android: grant notification access, select the bank apps, and check capture with the screen locked, after a process restart, and after revoking the permission.
2. **Real sanitized samples per bank** (Warba, KFH, NBK, Boubyan, Gulf Bank, CBK).
   - Add them to `fixtures/messages/v1/real_<bank>.json` with their provenance.
   - Update `ValidationStatus` in `mobile/lib/core/parsing/bank_registry.dart`.
3. **Credentials and setup**
   - Apple: Services/App ID and capabilities (Sign in with Apple, App Groups).
   - Google OAuth client IDs.
   - Azure OpenAI deployment and Azure Speech key/region, stored in Key Vault.
   - App Store Connect and Play Console subscription products: `kw.fils.premium.monthly` / `kw.fils.premium.yearly` (Apple) and `kw.fils.premium` (Play).
   - Apple Root CA G3: run `backend/scripts/fetch_apple_root.sh`.
4. **Azure deployment**
   - Run `az bicep build`, then `what-if`, then `infra/azure/deploy.sh staging`.
   - Wire the GitHub OIDC environment secrets listed in `docs/deployment.md`.
5. **Not yet implemented**
   - iOS Share Extension target.
   - Local push notifications for budget thresholds and recurring reminders (currently shown in-app only).
   - Azure neural TTS playback (device TTS is used).
   - Mark-as-shared for household transactions and budgets in the mobile UI: the server supports `household_id` scoping, but the UI only manages membership.
