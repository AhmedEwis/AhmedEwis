# Fils Synthetic Notifier (test tool)

**Not part of the Fils app. Not distributed.** It's a small Android app that posts three fixed, `[SYNTHETIC]`-labeled bank-style notifications (titled `NBK`), so Fils' notification capture can be tested reproducibly on a device without a bank, and without messaging apps, which Fils' listener deliberately blocks.

- Package: `kw.fils.testtools.synthetic_notifier` (a launchable app, so it appears in Fils → Capture → Choose apps).
- Texts: `assets/messages.json`. Fils' `test/core/synthetic_notifier_catalog_test.dart` reads the same file and checks the expected amounts, categories and balances.
- Each message can be posted now, or after 20 seconds (to close or lock Fils first).
- Build: `flutter build apk --release --target-platform android-arm64` (debug-signed).
- Used by `fils/docs/device-acceptance.md`, Part 2a.
