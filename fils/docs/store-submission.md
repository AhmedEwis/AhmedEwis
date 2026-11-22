# Store submission guide

Status: **not submitted.** This requires an Apple Developer Program account, a Google Play Console
account, signing keys, and a deployed backend with a public privacy policy URL. None of these exist
in this repo.

Bundle id / package: `kw.fils.fils` (change in `ios/Runner.xcodeproj` and `android/app/build.gradle.kts`
if the final name differs). Product ids are configurable (`FILS_IAP_MONTHLY`, `FILS_IAP_YEARLY`;
backend `FILS_APPLE_PRODUCT_IDS` / `FILS_GOOGLE_PRODUCT_IDS`).

## Apple App Store

### TestFlight

1. In App Store Connect, create the app record. Enable the capabilities **Sign in with Apple**, **App
   Groups** (shared inbox for the App Intent) and **In-App Purchase**.
2. Create subscription products (monthly/yearly) in one subscription group. Configure the App Store
   Server Notifications V2 URL `https://<api>/v1/webhooks/apple` for sandbox and production.
3. On a Mac with Xcode, build and archive:
   `flutter build ipa --dart-define=FILS_ENV=staging --dart-define=FILS_API_BASE_URL=<staging-url>`.
   Upload with Transporter, or automate with an App Store Connect API key in CI.
4. Add internal testers, then external testers. External testing needs beta review.

### App Privacy (nutrition labels): mapping to actual behavior

| Data type | Collected? | Linked to user | Tracking | Notes |
|---|---|---|---|---|
| Financial info: other financial info (transactions, balances) | Yes, **only if the user enables backup/sync** | Yes | No | On-device by default |
| Contact info: email, name | Yes, if the user signs in and Apple/Google shares them | Yes | No | Apple "Hide My Email" supported |
| Identifiers: user ID | Yes (account) | Yes | No | |
| Audio data | Yes, only when cloud speech is enabled; not retained | No | No | |
| User content: other (questions to the assistant, sanitized samples) | Yes, if cloud AI or sample submission is enabled | Yes | No | |
| Diagnostics | No crash SDK integrated yet | — | — | Update if one is added |
| Purchases | Yes (subscription status) | Yes | No | |

### Review notes (template)

> Fils is a personal finance tracker. It does not access the user's SMS inbox; on iPhone, users
> optionally create a personal Shortcuts automation that sends incoming bank messages to Fils
> through our App Intent ("Import bank transaction").
>
> To review without bank messages: on the first screen tap **"Explore with demo data"**. The app then
> uses clearly labeled synthetic data, with all features unlocked. Test capture: Settings → Capture
> & data → "Send a test message".
>
> Account deletion: Settings → Delete account (deletes the cloud account and local data).
> Sign in with Apple is offered wherever Google sign-in is offered.
> Subscriptions use StoreKit; "Restore purchases" is in Settings → Fils Pro.

### Permission strings (`Info.plist`)

| Key | Text (EN) | Rationale |
|---|---|---|
| `NSMicrophoneUsageDescription` | "Fils uses the microphone only while you hold the voice button, to turn what you say into an expense." | Push-to-talk voice entry |
| `NSSpeechRecognitionUsageDescription` | "Fils uses speech recognition to understand spoken expenses and questions." | On-device speech recognizer |
| `NSFaceIDUsageDescription` | "Unlock Fils with Face ID." | Optional app lock |

### Required compliance points

- **Sign in with Apple** is required because Google sign-in is offered (App Review Guideline 4.8).
- **In-app account deletion** is required (Guideline 5.1.1(v)). It's in Settings.
- **Digital subscriptions must use In-App Purchase** (Guideline 3.1.1). Apple Pay must not be used
  for them.
- Do not claim that Fils reads all SMS or all Apple Pay transactions. The Wallet automation covers
  only supported cards and taps.

## Google Play

### Internal testing

1. In Play Console, create the app, accept Play App Signing and upload the upload-key keystore
   (keep it out of the repo).
2. Build: `flutter build appbundle --flavor play --release --dart-define=FILS_ENV=staging`.
   Upload to the Internal testing track and add testers by email.
3. Create subscription products. Link a Google Cloud project with a service account that has Play
   Console "View financial data / Manage orders" access, and give the backend its JSON (Key Vault
   `fils-google-service-account-json`).
4. Set up the RTDN Pub/Sub topic with a push subscription to `https://<api>/v1/webhooks/google`,
   using OIDC authentication with the service account and audience set to
   `FILS_GOOGLE_PUBSUB_AUDIENCE`.

### SMS permission policy

- `READ_SMS` and `RECEIVE_SMS` are **restricted permissions**. Apps may request them only when they
  fall under an allowed use case, and only after a **Permissions Declaration Form** is approved by
  Google.
- **The `play` flavor declares no SMS permissions.** It uses the notification listener (bank apps
  only), plus paste, share and import.
- The **`sms` flavor** adds `RECEIVE_SMS`. It must not be uploaded to Play unless the Permissions
  Declaration is approved. Otherwise distribute it only through channels where that is permitted.
  Approval has **not** been requested or granted.
- Notification access must not be used to capture SMS-app notifications as a workaround. The
  allowlist is limited to user-selected bank and wallet apps.

### Notification listener: prominent disclosure (shown before the system settings screen)

> **Allow Fils to read bank notifications?**
> Fils reads notifications only from the bank and wallet apps you select, to record transactions
> automatically. Notifications from all other apps are ignored and never stored. The text of bank
> notifications is processed on your phone; nothing is uploaded unless you turn on cloud backup.
> You can turn this off anytime in Settings.
> [Choose bank apps] [Not now]

### Data safety form (answers)

| Question | Answer |
|---|---|
| Does the app collect or share user data? | Collects (optional features); does not share with third parties for their own purposes |
| Is data encrypted in transit? | Yes |
| Can users request deletion? | Yes, in-app (Settings → Delete account) and via the web support URL |
| Financial info: purchase history / other financial info | Collected only if backup or sync is enabled; purpose: app functionality; optional |
| Personal info: name, email, user IDs | Collected on sign-in; app functionality, account management |
| Audio | Collected only for cloud speech; not stored; app functionality; optional |
| Messages | Notification text from user-selected bank apps is **processed on device**; not collected by the developer unless the user submits a sanitized sample (optional) |
| App activity / diagnostics | Not collected |

## Support and deletion URLs

Host before submission:
- `https://<domain>/privacy`: the `privacy.md` content in EN and AR
- `https://<domain>/support`
- `https://<domain>/delete-account`: instructions, plus a web form for users who uninstalled the app

These URLs are configurable in the app (`FILS_PRIVACY_URL`, `FILS_SUPPORT_URL`).
