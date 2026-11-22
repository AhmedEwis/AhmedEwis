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

## Signed iOS builds

1. In the Apple Developer portal, create:
   - App ID `kw.fils.fils` with Sign in with Apple and App Groups (`group.kw.fils`).
   - App ID `kw.fils.fils.ShareExtension` with App Groups.
2. In Xcode, select your Team for both the Runner and ShareExtension targets (automatic signing), or provide profiles in CI.
3. In CI, add an App Store Connect API key (`APP_STORE_CONNECT_KEY_ID`, `_ISSUER_ID`, `_PRIVATE_KEY`) and run:
   `flutter build ipa --release --dart-define=FILS_ENV=production --dart-define=FILS_API_BASE_URL=… --export-options-plist=ios/ExportOptions.plist`
4. Upload to TestFlight. Test on a device:
   - the Shortcuts automation, the "Test Fils Capture" action, and the Share Extension from Messages;
   - Wallet automation and notification permission.

## Test APK provided with this handoff

| Field | Value |
|---|---|
| File | `fils-0.2.0-test-arm64-profile.apk` |
| Build | `flutter build apk --profile --flavor play --split-per-abi --target-platform android-arm64 --dart-define=FILS_ENV=development` |
| Signing | **Android SDK debug keystore** (Flutter's default for profile builds). For testing only; it can't be published or updated from a store build |
| Configuration | development environment, no backend URL (fully offline; cloud features show "not configured"), demo data available from the first screen, all features unlocked |
| Permissions | INTERNET, RECORD_AUDIO, USE_BIOMETRIC, POST_NOTIFICATIONS, RECEIVE_BOOT_COMPLETED, BILLING. No SMS |
