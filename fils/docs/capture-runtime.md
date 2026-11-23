# Capture while the app is closed: design, limits and verification state

## Pipeline states (shown in the app)

`Message received → Securely queued → Parsed → Posted to ledger | Awaiting review | Ignored`

- **Securely queued:** the text is in the native inbox (iOS App Group files with `completeUntilFirstUserAuthentication`, or Android app-private files). It **does not affect balances**. The capture screen and the home card show this count separately (`CapturePipelineStatus`, `queuedCountProvider`).
- **Posted:** a ledger transaction exists, and balances include it.
- **Awaiting review:** parsed with low confidence or missing fields. It doesn't count as confirmed until the user acts on it.
- **Ignored:** OTPs, promotions and duplicates.

## How processing happens without the UI

| Platform | Trigger | What runs | Notes |
|---|---|---|---|
| iOS | App Intent `ImportBankTransactionIntent` (Shortcuts Message automation) | Queues the message, then starts a **headless Flutter engine** (`HeadlessCapture.swift`) running the Dart entrypoint `captureMain` (`lib/capture_main.dart`). It waits up to 4 s for a result. | The dialog reports "Added to Fils: KWD 5.250 · Talabat", "needs review", "not a transaction", or "saved securely, will be added shortly". `UIApplication.beginBackgroundTask` requests time to finish after the intent returns. |
| iOS | App Intent `ImportWalletTransactionIntent` (Wallet Transaction automation) | Queues and returns immediately, then processes in the background (same engine) | Returns immediately because Apple developer forums report these automations timing out when intents run long |
| iOS | Share Extension | Queues only. The extension process can't host the Flutter engine | Processed the next time the app or a headless run drains the inbox |
| Android | `FilsNotificationListener` / `SmsReceiver` (`sms` flavor) | Queues, then `HeadlessCaptureRunner` starts a headless `FlutterEngine` on `captureMain` when no UI engine is attached | One engine at a time, with a 30 s hard stop. The last summary is stored for the status screen |
| Both | App opened or resumed | The UI engine drains the inbox | This is always the fallback path |

**Same code, same data:**
- `captureMain` opens the same SQLite3MultipleCiphers database with the same schema and migrations, and runs the same deterministic `IngestionService`.
- Cloud AI fallback is **not** used headlessly.
- Items are acknowledged only after durable processing. A crash before acknowledgement replays safely, because platform IDs make ingestion idempotent (`test/core/capture_recovery_test.dart`).
- **Ingestion is one database transaction** (`IngestionService.ingest`):
  1. It claims the source event first, with `INSERT OR IGNORE` against the unique index `(source, platform_id)` (schema v3; the migration renames any pre-existing duplicates rather than deleting them).
  2. It then makes the financial writes.
  3. It completes the source event.

  A crash at any point rolls back everything. Because the claim is the first write, a second connection (UI engine vs headless engine) waits on SQLite's write lock, then sees the claim and returns `duplicate`. A failed event isn't acknowledged and stays in the inbox; the rest of the inbox continues.
- **Possible duplicates are held, never counted twice and never dropped.** A capture is **held** when:
  - the same message text arrives again from the same sender, on a compatible account, without a stable platform ID (paste within 3 minutes, or Shortcuts within 24 hours, since Shortcuts give a new run ID each time); or
  - a cross-source match is ambiguous (more than one eligible transaction).

  A held capture is a source event with status `held` and **no transaction**: no balance or spending effect and nothing to sync. Its input is kept (encrypted) and the candidate IDs are stored. The Review inbox offers **Same transaction** (choose which) or **Separate purchase**. Both resolutions are atomic and idempotent (`confirmSameTransaction`, `confirmSeparate`). A purchase that only needs a category check still counts as usual.
- **Pending settlement:** exactly one qualifying authorization (same account and merchant, ±20 %, within 10 days) is settled. If several qualify, the settlement is held, and the user picks which authorization it settles. A re-delivery of the same message through another channel is never applied twice: it joins a held original, or merges into the record the original produced. **Dismiss** applies only while the capture is still held.
- **One rule set for every dedupe path** (`_eligible`): same amount and currency; not deleted; compatible status (a purchase never matches a declined or voided record; a decline matches only a decline); compatible kind and merchant; no conflicting known accounts; not already paired with this source; exactly one match. Identical text through another source goes through the same checks. The one exception: a reversal arriving again through a second channel may match the authorization that reversal voided.

**Data protection is not weakened:**
- The database key stays in the Keychain or Keystore with `first_unlock_this_device`.
- Before the first unlock after a reboot, the key is unreadable. `captureMain` fails safely, the item stays securely queued, and the dialog says so.
- **Concurrency:** WAL journal plus `busy_timeout = 5000`. When the UI engine is alive, native code notifies it instead of starting a second engine.

## Wallet automation input contract

| Aspect | Documented by Apple | Community/forum-reported | Implemented |
|---|---|---|---|
| Trigger exists (iOS 17+, "Transaction"; "Wallet" on iOS 26) | Shortcuts User Guide (no field list found) | Yes | Setup guide in the capture screen |
| Fields | **Not found in official docs** | Transaction, Card or Pass, Merchant, Amount, Name ([forum](https://www.developer.apple.com/forums/thread/758053)) | Intent parameters: `merchant`, `amount`, `card`, `name` (all optional strings) |
| Amount format | Unknown | Amount sometimes `0.0`, Merchant sometimes blank ([forum](https://developer.apple.com/forums/thread/765516)) | Zero or blank → review. A currency is required to post; a bare number goes to review |
| Reliability | — | Timeouts and flaky runs with App Intents ([forum](https://developer.apple.com/forums/thread/797233)); physical taps only, not online purchases | The intent returns immediately; Wallet and SMS for the same purchase are merged (tested) |

**Real-device verification: NOT DONE.** No iPhone was available. Everything in this table needs confirmation on iOS 17, 18 and 26 with a real card.

## Verification state

| Item | State |
|---|---|
| Swift (App Intents, HeadlessCapture, Share Extension) compiles | Checked by the GitHub Actions `macos-15` job (see [test-results.md](test-results.md)) |
| Dart headless pipeline, crash-replay idempotency, Wallet guards | Automated tests pass |
| Android headless runner compiles | Local `flutter build apk` |
| Headless engine actually runs within an App Intent / NotificationListener on a device | **Unverified (no device)** |
| Locked-device behavior, iOS background time limits, Android process death | **Unverified (no device)** |
