# Bank coverage and the real-sample workflow

## Current coverage (honest)

| Bank | Adapter | Status | Evidence | Known limitations |
|---|---|---|---|---|
| Warba | `warba` | **Synthetic-tested** | `fixtures/messages/v1/synthetic_kw.json` (written by us) | Sender ID assumed |
| KFH | `kfh` | **Synthetic-tested** | same | Sender ID assumed |
| NBK | `nbk` | **Synthetic-tested** | same | NBK is moving customers from SMS to in-app push notifications ([Kuwait Times](https://kuwaittimes.com/article/18972/kuwait/other-news/nbk-urges-customers-to-enable-transaction-alerts/), [FF News](https://ffnews.com/newsarticle/paytech/nbk-unveils-payment-verification-service-on-its-mobile-banking-app)). On Android, use notification capture. On iOS, push notifications from other apps can't be read: use Wallet automation or paste. |
| Boubyan | `boubyan` | **Synthetic-tested** | same | Alerts can be delivered through Apple Messages for Business ([Boubyan](https://boubyan.bankboubyan.com/en/ways-to-bank/apple-messages)). Whether the Shortcuts "Message" trigger fires for business chats is **unverified** |
| Gulf Bank | `gulfbank` | **Synthetic-tested** | same | Sender ID assumed ([SMS service page](https://e-gulfbank.com/en/direct-banking/247-banking/sms-service)) |
| CBK | `cbk` | **Synthetic-tested** | same | Sender ID assumed |

No public example of real transaction-alert wording was found for these banks (searched 2026-11-22). **No adapter is real-sample-tested or device-verified.** Synthetic fixtures prove the parser's logic, not compatibility with any bank's real format.

## Adding real samples (maintainers)

1. **Collect with consent.**
   - **In the app:** Review inbox → "Help improve bank support". The message is sanitized on the device, you preview exactly what will be sent, and sending requires a separate opt-in (`sample_submission`). The server sanitizes it again (`POST /v1/samples`).
   - **Manually:** the contributor pastes the message into the app's sanitizer preview and copies the result. Never accept unsanitized screenshots or exports.
2. **Create the fixture file.** Copy `fixtures/messages/templates/real_sample_template.json` to `fixtures/messages/v1/real_<bank>.json`. Fill in `provenance` (must start with `REAL-SAMPLE`), `consent_ref`, `channel`, `sender` and `expect`.
3. **Run the tests.** `flutter test test/core/parser_fixtures_test.dart` picks up every file in `fixtures/messages/v1/` automatically. For `REAL-SAMPLE` files it also checks that:
   - re-sanitizing the text changes nothing (no card/account numbers, OTPs, phones, IBANs or names remain);
   - `consent_ref` is present.
4. **If a case fails, fix the parser.** Never edit `expect` to match wrong output. Add bank-specific handling only when the generic engine can't cover the format.
5. **Upgrade the status.** Only when all real cases for a bank pass:
   - set `validation: ValidationStatus.realSampleTested`, `fixtureProvenance` and `lastVerified` in `mobile/lib/core/parsing/bank_registry.dart`;
   - replace the assumed sender IDs with the observed ones (`EvidencedValue(value, 'user-sample:<consent_ref>')`).
6. **Device verification** (`deviceVerified`) additionally requires a recorded end-to-end capture on a real phone (iPhone Shortcuts or Android notification), noted in `docs/test-results.md`.

## Unknown formats

Anything the parser can't read with confidence goes to the **Review inbox** and never silently into the ledger. This is tested in `test/core/capture_recovery_test.dart` ("unknown or ambiguous messages…") and in the parser fixtures. With consent, the cloud AI fallback can propose values, but they must be evidenced in the text and they still go to review.
