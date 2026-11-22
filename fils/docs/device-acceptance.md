# First iPhone acceptance run

This is the first scenario to run on a real iPhone. It needs only local capture: no Azure, AI, voice, subscription, cloud sync or backend. The test build uses `FILS_ENV=staging` with no API URL, so the app runs fully local.

Record each result in the table at the end. A step that wasn't run stays blank: don't infer it from CI.

## Phase A: synthetic setup

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
| A7 | **Retry the same event:** Shortcuts → run the automation's action again with the same text (or resend the identical SMS) | Banner: *"Already in Fils. This exact message was imported before…"* (headless) or *"Saved securely…"* (if Fils is still running). **Pass criterion:** still **one** 5.250 transaction, balance still **KWD 994.750** |
| A8 | Swipe Fils away (app closed), lock the phone, send a **new** synthetic text: the same message with amount `2.000` and available balance `992.750` | Lock-screen Shortcut banner is either *"Added to Fils: KWD 2.000 · Talabat"* (processed headless) or *"Saved securely in Fils. It will be added…"* (queued) |
| A9 | Repeat A7 for the 2.000 message while still locked | No second 2.000 transaction appears later |
| A10 | Unlock and open Fils → Home → **Auto-capture** card | While items wait, the card shows **“N queued”**. Review items appear under **Review**. After opening, queued items are processed and the pill disappears. Balance **KWD 992.750** with exactly two transactions |

Optional: also run A8 **after a reboot, before the first unlock**. The expected result is the *"Saved securely"* (queued) banner, because data-protected files are unavailable, and the item posts after you unlock and open Fils.

## Phase B: one real bank, sanitized

Run this only after Phase A passes. Pick **one** bank. Follow [bank-samples.md](bank-samples.md) to capture 5–10 real messages, and redact names, full card and account numbers, and references before sharing them. Then:

1. Add each sanitized sample as a fixture (provenance: `real-sanitized`).
2. Run `flutter test test/core/parser_fixtures_test.dart`.
3. Repeat A5–A10 with real incoming messages from that bank.

Until this phase passes, a bank remains "synthetic-tested only".

## Results

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
| A10 | | | |

## What only a device can show

These can't be proven in CI:
- whether iOS runs the Message automation while locked without a confirmation prompt (varies by iOS version and settings);
- whether the headless Flutter engine finishes within the Shortcut time limit;
- Keychain and App Group file access before the first unlock;
- the exact banner text shown by Shortcuts.
