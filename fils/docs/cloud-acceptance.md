# Cloud-feature acceptance (separate from local core)

These features talk to the Fils backend or a third-party service. They aren't part of the device-test build, which has no API URL, and they **can't start** until the prerequisites below exist. Local-core acceptance ([device-acceptance.md](device-acceptance.md)) neither needs nor implies any of this.

**Status: not started.** Nothing below has been verified on a device or against a deployed backend. The backend's behavior is covered only by local tests and the live-localhost E2E tests ([test-results.md](test-results.md)).

## Prerequisites (none exist yet)

| Prerequisite | Needed for | Owner |
|---|---|---|
| Backend deployed to Azure (Bicep in `infra/azure`, workflow `deploy-backend.yml`), reachable over HTTPS | everything below | account holder authorizes the paid infrastructure; then a deploy run |
| `FILS_API_BASE_URL` (HTTPS) build | everything below | build flag |
| Sign in with Apple capability and service config; Google OAuth client IDs (`ios/Flutter/Fils.xcconfig`, `FILS_GOOGLE_SERVER_CLIENT_ID`) | C1 | account holder |
| Azure OpenAI deployment and key (backend Key Vault) | C4 | account holder |
| Azure Speech key and region (backend Key Vault) | C5 | account holder |
| App Store / Play subscription products (`kw.fils.premium.*`) and server notification setup | C6 | account holder |

## Scenarios

| # | Feature | Scenario | Pass criterion |
|---|---|---|---|
| C1 | Sign-in | Sign in with Apple, and with Google, on a device | An account is created. Tokens are kept in the Keychain/Keystore. Sign-out clears them |
| C2 | Cloud sync | Consent, then sync device A → device B; edit on both; delete on one | Data matches on both devices. A conflict is surfaced, never silently lost. A deletion propagates. Held captures never upload (they're local only) |
| C3 | Household sharing | Two accounts; share one transaction; revoke | Only the shared fields are visible; personal totals unchanged; revoke removes it |
| C4 | Cloud AI assistant | Consent, ask a spending question | Answers quote only numbers computed on the device. Without consent, nothing is sent |
| C5 | Azure neural voice | Consent, play a spoken answer | Neural voice plays. On any failure it falls back to device TTS |
| C6 | Subscriptions | Sandbox purchase, restore, expiry | Server-verified entitlement. No local unlock in a production build |
| C8 | My Smart Plan with live AI | Consent, then say the goal in Egyptian Arabic, Kuwaiti Arabic and English; ask for an explanation | The pill says **Live AI** only when the model was used. Amounts are identical to the local planner's for the same request. Any model text containing its own numbers is rejected and replaced by the local explanation. Nothing but category-level aggregates leaves the phone (`docs/smart-plan.md`) |
| C7 | Account deletion | Delete the account from the app | Server data removed; local wipe; sign-in no longer works |

## Results

| # | Pass/Fail | Environment (backend URL, build) | Notes |
|---|---|---|---|
| C1 | | | |
| C2 | | | |
| C3 | | | |
| C4 | | | |
| C5 | | | |
| C6 | | | |
| C7 | | | |
| C8 | | | |
