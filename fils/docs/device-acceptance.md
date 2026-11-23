# Local-core acceptance (device test build)

This acceptance covers only the **local core**: on-device capture, parsing, the ledger, balances, deduplication and the review inbox. It needs no Azure, AI, voice, subscription, sign-in, sync or backend. The device-test builds ([device-test-build.md](device-test-build.md)) use `FILS_ENV=staging` with **no API URL**, so the app has nothing to talk to.

Cloud features have their own acceptance, [cloud-acceptance.md](cloud-acceptance.md), which is blocked on deployment and credentials. A local-core pass doesn't depend on it, and doesn't imply it.

**Local-core gate (both must hold on a real device):**
- every capture shows the correct amount, category, account and balance;
- a retried or re-delivered event never counts twice and is never silently lost.

Record each result in the table at the end. A step that wasn't run stays blank: don't infer it from CI.

## Part 1: iPhone (TestFlight build)

### Phase A: synthetic setup

Use only the synthetic message below. It's labeled `[SYNTHETIC]` and isn't a real bank message.

```
[SYNTHETIC] Purchase of KWD 5.250 at TALABAT card ending 1234. Available balance KWD 994.750
```

| # | Step | Expected |
|---|---|---|
| A1 | Install the TestFlight build and open Fils | Onboarding appears |
| A2 | Tap **Continue without an account** | Home screen. No sign-in, no network needed |
| A3 | Accounts → Add account: name `Test NBK card`, bank NBK, last 4 `1234`, opening balance `1,000.000` | Account shows **KWD 1,000.000** |
| A4 | Shortcuts → Automation → **Message** → Message contains `[SYNTHETIC]` → **Run Immediately** → action **Import Bank Message** (Message Text = *Shortcut Input → Content*, Sender = *Sender*) | Automation saved |
| A5 | From another phone (or by forwarding to yourself), send the synthetic text to this iPhone, with Fils open in the foreground | The banner reads *"Saved securely in Fils…"*, because the open app processes it rather than the headless engine, and the transaction appears in Fils within a second or two |
| A6 | Check the transaction in Fils | Amount **KWD 5.250**, category **Food & Dining**, account **Test NBK card**, balance **KWD 994.750**, status posted (not pending, not review) |
| A7 | **Retry the same event:** Shortcuts → run the automation's action again with the same text (or resend the identical SMS) | Banner: *"Saved to Fils. It needs your review before it counts."* (headless) or *"Saved securely…"* (if Fils is still running). **Pass criterion:** still **one** 5.250 transaction and balance still **KWD 994.750**. **Review** lists it under *Possible duplicates*. Tap **Same transaction**: the balance is unchanged and the item leaves Review |
| A8 | Swipe Fils away (app closed), lock the phone, send a **new** synthetic text: the same message with amount `2.000` and available balance `992.750` | Lock-screen Shortcut banner is either *"Added to Fils: KWD 2.000 · Talabat"* (processed headless) or *"Saved securely in Fils. It will be added…"* (queued) |
| A9 | Repeat A7 for the 2.000 message while still locked. Later, in Review, tap **Same transaction** | Until you decide, no second 2.000 transaction exists. After **Same transaction**, the balance stays **992.750**, and tapping again changes nothing |
| A9b | *(optional)* Send the 2.000 text once more, then choose **Separate purchase** in Review | Exactly one more 2.000 transaction appears (balance −2.000). Tapping again, or tapping Dismiss afterwards, changes nothing. *If you run this, A10's expected balance is 990.750 with three transactions* |
| A10 | Unlock and open Fils → Home → **Auto-capture** card | While items wait, the card shows **“N queued”**. Review items appear under **Review**. After opening, queued items are processed and the pill disappears. Balance **KWD 992.750** with exactly two transactions |

Optional: also run A8 **after a reboot, before the first unlock**. The expected result is the *"Saved securely"* (queued) banner, because data-protected files are unavailable, and the item posts after you unlock and open Fils.

### Phase B: one real bank, sanitized

Run this only after Phase A passes. Pick **one** bank. Follow [bank-samples.md](bank-samples.md) to capture 5–10 real messages, and redact names, full card and account numbers, and references before sharing them. Then:

1. Add each sanitized sample as a fixture (provenance: `real-sanitized`).
2. Run `flutter test test/core/parser_fixtures_test.dart`.
3. Repeat A5–A10 with real incoming messages from that bank.

Until this phase passes, a bank remains "synthetic-tested only".

## Part 2: Android (test APK, available now)

Install `fils-<version>-device-test-arm64.apk` (see [device-test-build.md](device-test-build.md)). Use the same `[SYNTHETIC]` message as Part 1.

| # | Step | Expected |
|---|---|---|
| N1 | Install the APK (allow "install unknown apps" for your file manager) and open Fils | Onboarding appears |
| N2 | **Continue without an account**, then add the account as in A3 | **KWD 1,000.000** |
| N3 | Capture → **Paste**, paste the synthetic message, then save | Same values as A6: **5.250**, **Food & Dining**, **Test NBK card**, balance **994.750** |
| N4 | Paste the identical text again within 3 minutes | Held under **Review → Possible duplicates**. The balance is still **994.750**. **Same transaction** keeps it there |
| N5 | Capture → Notification access → allow Fils, then **Choose apps** → select the SMS app on this phone (synthetic stand-in for a bank app) | Capture shows access granted and 1 app monitored |
| N6 | Fils closed (swiped away): send the 2.000 synthetic text to this phone | After opening Fils, one 2.000 transaction appears. If the system delayed it, Home → Auto-capture shows it queued until then |
| N7 | Reboot, don't open Fils, then send a third synthetic text (amount `3.000`) | It's captured after reboot (listener rebinds) and appears when you open Fils; never twice |
| N8 | In Android Settings, revoke Fils' notification access, then open Fils → Capture | Capture shows access **missing**; nothing is captured until it's re-granted |

## Results

### iPhone

| Step | Pass/Fail | iOS version | Notes (banner text, screenshot name) |
|---|---|---|---|
| A1 | | | |
| A2 | | | |
| A3 | | | |
| A4 | | | |
| A5 | | | |
| A6 | | | |
| A7 | | | |
| A8 | | | |
| A9 | | | |
| A9b | | | |
| A10 | | | |

### Android

| Step | Pass/Fail | Android version / phone | Notes |
|---|---|---|---|
| N1 | | | |
| N2 | | | |
| N3 | | | |
| N4 | | | |
| N5 | | | |
| N6 | | | |
| N7 | | | |
| N8 | | | |

## What only a device can show

These can't be proven in CI:
- whether iOS runs the Message automation while locked without a confirmation prompt (varies by iOS version and settings);
- whether the headless Flutter engine finishes within the Shortcut time limit;
- Keychain and App Group file access before the first unlock;
- the exact banner text shown by Shortcuts;
- on Android: notification-listener behavior with the app closed, after a reboot, and under the phone maker's battery optimization.
