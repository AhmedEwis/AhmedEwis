# Device-test build

**Feature freeze:** from this build on, only fixes found by review or device testing go in. No new features until local-core acceptance passes on a real iPhone and a real Android phone.

## Build definition

| | iPhone | Android |
|---|---|---|
| Version | `0.3.0` (build number set by CI: 3000 + run number) | `0.3.0`, versionCode `2003` (arm64 split) |
| Environment | `FILS_ENV=staging`, **no API URL** (fully local) | same |
| How it's built | `.github/workflows/ios-testflight.yml`: signed archive, upload to TestFlight | `flutter build apk --profile --flavor play --split-per-abi --target-platform android-arm64 --dart-define=FILS_ENV=staging` |
| Signing | App Store Connect API key, automatic signing (**secrets not configured yet**) | Android SDK **debug keystore**: test only; can't be updated by a store build |
| Capture paths | Shortcuts Message automation, Share Extension, Wallet automation, paste | Notification listener (`play` flavor; no SMS permission), paste |
| Cloud features | Present in the binary but inert: show "not configured" | same |
| Schema | v4 (upgrades v1, v2 and both shipped v3 variants) | same |

## Installation status

| | Status |
|---|---|
| iOS: compiled and archived | yes (CI, unsigned; archive checks pass) |
| iOS: signed / uploaded / installable | **no**: blocked on the 4 signing secrets ([release-and-signing.md](release-and-signing.md)) |
| Android: installable | **yes**: sideload the APK; `apksigner` verifies it |

## Test tool: Fils Synthetic Notifier (Android)

This is a separate app, not part of Fils, and it isn't distributed. It posts fixed `[SYNTHETIC]` bank-style notifications, so notification capture can be tested reproducibly without a bank and without messaging apps (which the listener blocks).
- Source: `fils/tools/synthetic_notifier`. The texts are in `assets/messages.json`.
- Package: `kw.fils.testtools.synthetic_notifier`. Debug-signed.
- Build: `cd fils/tools/synthetic_notifier && flutter build apk --release --target-platform android-arm64`.

## Install

- **Android:** copy the APK to the phone, open it, allow installing from that app, then install. A future store build can't update it in place (different key): uninstall it first. For Part 2a, install the Synthetic Notifier APK the same way.
- **iPhone:** once the secrets exist, go to Actions → `ios-testflight` → Run workflow (upload on). After Apple's processing, add yourself as an internal tester in TestFlight and install. On the first build, App Store Connect asks you an export-compliance question.

## Acceptance

1. **Local core:** [device-acceptance.md](device-acceptance.md). Part 1 is the iPhone, Part 2 is Android. This is the gate for this build.
2. **Cloud features:** [cloud-acceptance.md](cloud-acceptance.md). Separate, and blocked on deployment and credentials. Not part of this build's gate.
