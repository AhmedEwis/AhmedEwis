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

Install `fils-<version>-device-test-arm64.apk` (see [device-test-build.md](device-test-build.md)). Use the same `[SYNTHETIC]` message as Part 1 for paste.

| # | Step | Expected |
|---|---|---|
| N1 | Install the APK (allow "install unknown apps" for your file manager) and open Fils | Onboarding appears |
| N2 | **Continue without an account**, then add the account as in A3 | **KWD 1,000.000** |
| N3 | Capture → **Paste**, paste the synthetic message, then save | Same values as A6: **5.250**, **Food & Dining**, **Test NBK card**, balance **994.750** |
| N4 | Paste the identical text again within 3 minutes | Held under **Review → Possible duplicates**. The balance is still **994.750**. **Same transaction** keeps it there |

### Part 2a: synthetic notification capture (reproducible; no bank involved)

Fils captures notifications only from apps you pick. **Messaging apps are deliberately blocked**: Google Messages, Samsung Messages, AOSP Messaging/MMS, WhatsApp and Telegram never appear in the picker, and the listener ignores them even if set. So SMS notifications can't be used for this test.

Instead, use the test tool **Fils Synthetic Notifier** (`fils-synthetic-notifier-<commit>.apk`, source in `fils/tools/synthetic_notifier`). It's an ordinary app (`kw.fils.testtools.synthetic_notifier`) that posts three fixed, `[SYNTHETIC]`-labeled bank-style notifications, titled `NBK`:

| ID | Notification text (after the title `NBK`) |
|---|---|
| S1 | `[SYNTHETIC] Purchase of KWD 5.250 at TALABAT card ending 1234. Available balance KWD 994.750` |
| S2 | `[SYNTHETIC] Purchase of KWD 2.000 at TALABAT card ending 1234. Available balance KWD 992.750` |
| S3 | `[SYNTHETIC] Purchase of KWD 3.000 at TALABAT card ending 1234. Available balance KWD 989.750` |

The texts come from `tools/synthetic_notifier/assets/messages.json`. The expected values below are checked on the host by `test/core/synthetic_notifier_catalog_test.dart`, which feeds those exact payloads through the listener's input path.

| # | Step | Expected |
|---|---|---|
| N5 | Install the notifier APK, open it once and allow notifications. In Fils: Capture → Notification access → allow Fils. Then **Choose apps** → select **Fils Synthetic Notifier** | Capture shows access granted and 1 app monitored. Google Messages, Samsung Messages, WhatsApp and Telegram are **not** in the list |
| N6 | Swipe Fils away (closed). In the notifier, tap **S2 → Post in 20 s**, then lock the phone | The notifier's notification appears. Open Fils: exactly **one 2.000** transaction (Food & Dining, Test NBK card) and balance **992.750**. If the system delayed processing, Home → Auto-capture shows it queued until then |
| N6b | Within 10 minutes, tap **S2 → Post now** again (same text, new notification) | Never a second counted 2.000. Either the listener drops the re-post (the Fils process kept running), or, if Android restarted Fils in between, it's **held** under Review → Possible duplicates with the balance still **992.750**. Choose **Same transaction** |
| N7 | Reboot. **Don't open Fils.** Open the notifier and tap **S3 → Post now**. Then open Fils | Captured after the reboot (the listener rebinds): exactly **one 3.000**, balance **989.750** |
| N8 | Android Settings → revoke Fils' notification access. Tap **S1 → Post now** in the notifier. Open Fils → Capture | Capture shows access **missing**; nothing new is recorded. Re-grant access afterwards |

A Part 2a pass proves the Android capture **mechanism**: listener, app filter, background processing, reboot and revocation. It says **nothing** about any bank's real notification format.

### Part 2b: real bank-app notifications (separate; per bank)

Run this only after Part 2a passes, one bank at a time. Real messages are personal data: **sanitize before sharing anything** ([bank-samples.md](bank-samples.md)).

| # | Step | Expected |
|---|---|---|
| R1 | Install the bank's official app and enable its transaction notifications. In Fils → Choose apps, select **that bank app** | Listed and selected |
| R2 | Make a small real card purchase | One transaction with the **amount, merchant, account and balance as shown in the bank app**. If it lands in **Review → Messages we couldn't read**, record it: the bank's format isn't supported yet |
| R3 | If the bank also sends an SMS for the same purchase, compare | Still one transaction (an SMS isn't captured on the `play` build; it's only visible to you) |
| R4 | Check the lock-screen setting "hide sensitive content" | If the bank app's notifications are hidden or redacted, Fils receives no text and records nothing; note it |

A bank moves from "synthetic-tested only" to "device-verified" only after R1–R4 pass and its sanitized samples are added as fixtures (`provenance: real-sanitized`).

## Part 3: My Smart Plan (local core; iPhone or Android)

No server or AI is needed. The device-test builds label the planner **"Basic local planner"**; live AI is cloud acceptance C8. Use **Explore with demo data** (synthetic, labelled) or your own captured history.

| # | Step | Expected |
|---|---|---|
| SP1 | Home → **خطتي الذكية / My Smart Plan** | The plan screen opens. Demo mode shows three chips labelled "Demo scenarios (synthetic data)" |
| SP2 | Type or say (mic): *"عايز أوفر 150 دينار الشهر ده، بس ما تقللش الجيم ولا مصاريف البيت."* → **Make my plan** | "What I understood": **KWD 150.000**, **this cycle**, and protected **Fitness & Gym, Rent & Housing, Bills, Groceries**, with an *Assumption* note for "مصاريف البيت". The pill says **Basic local planner** with a reason, never "Live AI" |
| SP3 | Read the summary | Bars for *Savings if nothing changes* vs *Savings with the plan* vs the goal, each with a source pill (**Observed / You said / Assumption**). No protected category appears as an action. At most 3 actions |
| SP4 | Tap **Why this suggestion?** on an action, then step its limit up and down | Supporting facts with their sources. Totals recalculate at once. The limit can't go below what's already spent. The card shows "Your edit" |
| SP5 | **Preview changes** | A list of budget changes (before → after) and the optional goal. Nothing is written yet: Plans → Budgets is unchanged |
| SP6 | **Confirm and apply**, then tap Confirm again quickly or go back and repeat | One applied plan. Plans → Budgets shows exactly the selected limits. Transactions and balances are unchanged |
| SP7 | Force-close the app, reopen → Smart Plan | The progress card shows spent vs each limit and the % of the cycle. **Undo plan** restores the previous budgets once; repeating does nothing |
| SP8 | Try *"ابي اوفر 900 دينار هالشهر"* | Clearly marked as more than this cycle allows, with computed alternatives (smaller goal, more months, relax a protection). No invented savings |
| SP9 | Bookmark icon → memory | Lists only protections you asked it to remember, with remove and **Reset everything**. It states that preferences stay on the phone and aren't used to train AI |

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

### Android: paste and synthetic notifications (Parts 2 and 2a)

| Step | Pass/Fail | Android version / phone | Notes |
|---|---|---|---|
| N1 | | | |
| N2 | | | |
| N3 | | | |
| N4 | | | |
| N5 | | | |
| N6 | | | |
| N6b | | | |
| N7 | | | |
| N8 | | | |

### Android: real bank apps (Part 2b, one table per bank)

| Bank | Step | Pass/Fail | Notes (sanitized) |
|---|---|---|---|
| | R1 | | |
| | R2 | | |
| | R3 | | |
| | R4 | | |

### My Smart Plan (Part 3)

| Step | Pass/Fail | Device / OS | Notes |
|---|---|---|---|
| SP1 | | | |
| SP2 | | | |
| SP3 | | | |
| SP4 | | | |
| SP5 | | | |
| SP6 | | | |
| SP7 | | | |
| SP8 | | | |
| SP9 | | | |

## What only a device can show

These can't be proven in CI:
- whether iOS runs the Message automation while locked without a confirmation prompt (varies by iOS version and settings);
- whether the headless Flutter engine finishes within the Shortcut time limit;
- Keychain and App Group file access before the first unlock;
- the exact banner text shown by Shortcuts;
- on Android: notification-listener behavior with the app closed, after a reboot, and under the phone maker's battery optimization.
