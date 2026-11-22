# Release configuration and signed builds

No signing credentials exist in this repository or in CI, and none should be committed.

## Identifiers (single source of truth)

These are checked against each other by `mobile/test/core/release_config_test.dart`.

| Item | Value | Where configured |
|---|---|---|
| iOS app bundle ID | `kw.fils.fils` | `ios/Runner.xcodeproj` (Runner target) |
| iOS Share Extension | `kw.fils.fils.ShareExtension` | Xcode target `ShareExtension` (added by `ios/scripts/add_share_extension.rb`) |
| App Group | `group.kw.fils` | `ios/Runner/Runner.entitlements`, `ios/ShareExtension/ShareExtension.entitlements`, `CaptureInbox.swift` |
| Sign in with Apple | capability on the Runner App ID | `Runner.entitlements`; backend `FILS_APPLE_CLIENT_IDS` |
| Google Sign-In (iOS) | `FILS_GOOGLE_IOS_CLIENT_ID`, `FILS_GOOGLE_REVERSED_CLIENT_ID` (URL scheme) | `ios/Flutter/Fils.xcconfig` (placeholders: `REPLACE_ME`) → `Info.plist` |
| Google server client ID | `--dart-define=FILS_GOOGLE_SERVER_CLIENT_ID` | build flag; backend `FILS_GOOGLE_CLIENT_IDS` |
| Android application ID | `kw.fils.fils` (`play`), `kw.fils.fils.sms` (`sms`) | `android/app/build.gradle.kts` |
| Apple subscriptions | `kw.fils.premium.monthly`, `kw.fils.premium.yearly` | `AppConfig`; backend `FILS_APPLE_PRODUCT_IDS` |
| Google subscription | `kw.fils.premium` (monthly and yearly base plans) | `AppConfig.googleSubscriptionId`; backend `FILS_GOOGLE_PRODUCT_IDS` |
| API base URL | `--dart-define=FILS_API_BASE_URL=https://…` | build flag (production requires HTTPS) |

## Production isolation (enforced)

- **Demo sign-in:** the button is hidden (`ReleaseGuards.demoSessionAllowed`), and the server returns 404 (`test_demo_session_404_in_production`).
- **Development unlock of all features:** only in development and staging builds (`ReleaseGuards.devUnlock`, backend `test_entitlement_logic_in_production_mode`).
- **Local synthetic demo data:** off in production unless explicitly built with `--dart-define=FILS_ALLOW_DEMO=true` (store-review build). It is always labeled "Demo data".
- **Missing configuration:**
  - A production app build refuses to start without `FILS_API_BASE_URL` (HTTPS) and `FILS_GOOGLE_SERVER_CLIENT_ID` (`ReleaseGuards.productionConfigProblems`, checked in `main.dart`).
  - The production backend refuses to start without `FILS_JWT_SECRET` and `FILS_DATA_KEY` (`test_production_requires_secrets`).
  - Bicep parameter files fail to compile without `FILS_PG_ADMIN_PASSWORD` (CI `infra-validate`).
- **Logging:**
  - The app logs only outcomes and exception types; a static test forbids `print` and sensitive `debugPrint` calls.
  - The backend redacts tokens and message text (`test_log_redaction`).
  - No crash-reporting SDK is integrated. If one is added, it must not collect message text, tokens or audio.
- **Android `play` flavor:** no SMS or call-log permissions. This is checked both statically and in CI with `aapt2` on the built APK.
- **Android `sms` flavor:** declares only `RECEIVE_SMS` plus `SmsReceiver`, which is the feature actually implemented.

## Signed Android builds

1. Create an upload key **once**, locally, and keep it out of git:
   `keytool -genkeypair -v -keystore upload-keystore.jks -keyalg RSA -keysize 4096 -validity 10000 -alias upload`
2. Add the GitHub secrets `ANDROID_KEYSTORE_BASE64` (`base64 -w0 upload-keystore.jks`), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`. `mobile-ci.yml` writes `android/key.properties` at build time and deletes it afterwards.
3. Build locally:
   `flutter build appbundle --release --flavor play --dart-define=FILS_ENV=production --dart-define=FILS_API_BASE_URL=https://api.example --dart-define=FILS_GOOGLE_SERVER_CLIENT_ID=…`
4. Enroll in Play App Signing, upload the AAB to the internal testing track, and complete the Data safety form ([store-submission.md](store-submission.md)).

Without `key.properties`, release builds are produced **unsigned**. The build never falls back to debug keys for release.

## Signed iOS builds and TestFlight

**Status:** no Apple Developer team, certificate, provisioning profile or App Store Connect key exists in this repository or its CI. The Xcode project has no `DEVELOPMENT_TEAM`. The iOS app is **compiled** in CI (unsigned), but it is **not signed, not uploaded and not installable** on an iPhone yet.

The pipeline is ready: [`.github/workflows/ios-testflight.yml`](../../.github/workflows/ios-testflight.yml) archives with automatic signing through an App Store Connect API key, exports `ios/ExportOptions.plist` (`app-store-connect`), checks the Share Extension is embedded and signed, uploads to TestFlight with `altool`, and deletes the key from the runner. The test build uses `FILS_ENV=staging` with no API URL, so it's fully local, with no backend, AI, voice or subscriptions. On every push to the branch, its preflight job lists which prerequisites are missing without attempting a build.

### Prerequisites (one time, done by the account holder; never pasted into chat)

1. **Apple Developer Program membership** (paid, individual or organization) for the Apple ID that will own the app.
2. In **App Store Connect → Apps → +**, create an app record with bundle ID `kw.fils.fils` (register the identifier first under Certificates, Identifiers & Profiles if it isn't offered). Automatic signing in CI registers the App Group `group.kw.fils`, Sign in with Apple and the `kw.fils.fils.ShareExtension` identifier, provided the key below has the **Admin** role. With **App Manager**, create those identifiers by hand first.
3. In **App Store Connect → Users and Access → Integrations → App Store Connect API**, create a team key and download `AuthKey_<KEYID>.p8` (it can be downloaded only once).
4. In **GitHub → this repository → Settings → Secrets and variables → Actions**, add `APPLE_TEAM_ID`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` and `APP_STORE_CONNECT_PRIVATE_KEY` (the full `.p8` text).
5. **Actions → ios-testflight → Run workflow.** After Apple's processing (usually 5–30 minutes), add yourself as an internal tester in TestFlight and install the build. Internal testing needs no App Review.

Then run [device-acceptance.md](device-acceptance.md).

**Alternative without CI:** on a Mac with Xcode 16+, open `ios/Runner.xcworkspace`, select your Team for the Runner and ShareExtension targets, connect the iPhone and Run. A free Apple ID can install a 7-day development build, but free provisioning doesn't support App Groups, so Shortcut-to-app capture won't work. A paid membership is needed for the real acceptance test.

## Test APK provided with this handoff

| Field | Value |
|---|---|
| File | `fils-0.2.0-test-arm64-profile.apk` |
| Build | `flutter build apk --profile --flavor play --split-per-abi --target-platform android-arm64 --dart-define=FILS_ENV=development` |
| Signing | **Android SDK debug keystore** (Flutter's default for profile builds). For testing only; it can't be published or updated from a store build |
| Configuration | development environment, no backend URL (fully offline; cloud features show "not configured"), demo data available from the first screen, all features unlocked |
| Permissions | INTERNET, RECORD_AUDIO, USE_BIOMETRIC, POST_NOTIFICATIONS, RECEIVE_BOOT_COMPLETED, BILLING. No SMS |
