# Fils API Contract (v1)

> Changes (mobile lead): transaction `kind` uses `adjust_up` and `adjust_down` for reconciliation adjustments instead of a signed `adjustment`.
>
> Changes (backend, as implemented):
> 1. `POST /v1/auth/reauth` body is `{provider: "apple"|"google", token, nonce}`.
> 2. `POST /v1/me/identities/{provider}` body is `{token, nonce}` and requires `X-Reauth`.
> 3. `POST /v1/demo/session` body is a `DeviceInfo` object.
> 4. `POST /v1/sync/push` returns `cursor: null`. Only `GET /v1/sync/pull` advances the cursor, because
>    other devices' changes may interleave.
> 5. Category ids (`category_id`, `parent_id`, `splits[].category_id`) may be a UUID or a built-in
>    system slug matching `^[a-z][a-z0-9_]{1,39}$` (for example `transfers` or `food`). Slugs are never
>    synced as records, are assumed to exist on every device, and skip the server reference check.
>    Envelope `id`s are always UUIDs.
> 6. `GET /v1/jobs/{id}` also returns `result` (candidate rows) for `document_extract` jobs, and
>    `result_url` (`/v1/jobs/{id}/download`, authenticated) for exports. Candidate rows:
>    `{occurred_on, description, amount_minor, currency, direction: debit|credit, needs_review}`.
> 7. Sync payloads reject unknown fields (`extra=forbid`), so the result is `rejected` with
>    `invalid_payload` and never a silent drop.
> 8. `POST /v1/samples` returns `{id, stored_text}`: the text after the server's second sanitization pass.
> 9. `GET /v1/households` items are `{id, name, owner_user_id, my_role, members: [{user_id, role, display_name, joined_at}]}`.
> 10. Billing: the Apple `appAccountToken` must equal the user id (UUID). The Google
>     `obfuscatedExternalAccountId` must equal `sha256_hex(user_id)`. `restore` also returns
>     `restore_errors: [code]`.

This is the contract between the Flutter app (`fils/mobile`) and the backend (`fils/backend`).
The backend's generated OpenAPI at `/v1/openapi.json` is the authoritative version. This file
describes the intent and the wire shapes both sides code against.

- Base path: `/v1`
- JSON in and out, UTF-8, `snake_case` keys.
- Timestamps are RFC 3339 strings in UTC (`2026-11-22T14:03:00Z`).
- **Money is always an integer of minor units plus an ISO-4217 currency code.**
  Example: KWD 5.250 is `{"amount_minor": 5250, "currency": "KWD"}`.
  Floats are never used for money.
- IDs are client-generated UUIDv4 strings for user data (local-first), server-generated for
  server-owned rows such as sessions, invitations and jobs.
- Errors look like `{"error": {"code": "string_code", "message": "human text", "details": {...}}}`
  with the matching HTTP status.
- Mutating endpoints accept an `Idempotency-Key` header. A replay with the same key and the
  same body returns the original response. The same key with a different body returns `409`
  with code `idempotency_mismatch`.
- Auth: `Authorization: Bearer <access_token>`, a JWT of about 15 minutes, signed by the backend.

## Auth

| Method | Path | Body | Result |
|---|---|---|---|
| POST | /v1/auth/nonce | – | `{nonce, expires_at}`: a one-time server nonce. The client sends `sha256(nonce)` to Apple or Google as the provider nonce. |
| POST | /v1/auth/apple | `{identity_token, nonce, authorization_code?, device: DeviceInfo, full_name?}` | `AuthResult` |
| POST | /v1/auth/google | `{id_token, nonce, device: DeviceInfo}` | `AuthResult` |
| POST | /v1/auth/refresh | `{refresh_token}` | `AuthResult`. Refresh tokens rotate; reusing an old one revokes the whole session family. |
| POST | /v1/auth/logout | `{refresh_token}` | 204 |
| POST | /v1/auth/reauth | provider token, as in apple/google | `{reauth_token, expires_at}`: a short-lived proof required by sensitive endpoints in the `X-Reauth` header. |
| GET | /v1/me | – | `User` |
| GET | /v1/me/sessions | – | `[Session]` |
| DELETE | /v1/me/sessions/{id} | – | 204 (revoke) |
| POST | /v1/demo/session | – | `AuthResult` for a synthetic demo user. **Only when `FILS_ENV != production`**; returns 404 in production. |

`DeviceInfo = {device_id, platform: "ios"|"android", app_version, name?}`

`AuthResult = {access_token, access_expires_at, refresh_token, refresh_expires_at, user: User, is_new_user}`

`User = {id, display_name?, email?, email_verified, created_at, locale, identities: [{provider, subject_hint}], entitlements: Entitlements, consents: ConsentState}`

Account linking: a new provider identity is attached **only** while the request is
authenticated as the existing user and carries a valid `X-Reauth`
(`POST /v1/me/identities/{provider}`). A matching email alone never links accounts.

## Consent and privacy

| Method | Path | Notes |
|---|---|---|
| GET | /v1/me/consents | Current state plus history |
| POST | /v1/me/consents | `{kind, granted, policy_version, source}` appends a consent record. `kind` is one of `cloud_backup`, `cloud_sync`, `cloud_ai`, `cloud_voice`, `sample_submission`, `analytics`, `marketing`. |
| POST | /v1/me/export | Starts an export job, returns `Job` (requires `X-Reauth`) |
| GET | /v1/jobs/{id} | `Job = {id, kind, status: queued|running|succeeded|failed, result_url?, error?}` |
| DELETE | /v1/me | Account deletion (requires `X-Reauth`). Revokes sessions immediately and queues a hard delete of all user rows. Returns `Job`. |

`ConsentState = {cloud_backup: bool, cloud_sync: bool, cloud_ai: bool, cloud_voice: bool, sample_submission: bool, ...}`

The server refuses `/v1/sync/*` with `403 consent_required` unless `cloud_sync` or
`cloud_backup` is granted. Sign-in alone never uploads financial data.

## Sync

The model is local-first. Every synced record is an envelope:

```json
{
  "entity": "account|transaction|category|budget|goal|recurring|merchant_alias|asset|setting",
  "id": "uuid",
  "version": 3,
  "base_version": 2,
  "deleted": false,
  "updated_at": "2026-11-22T10:00:00Z",
  "household_id": null,
  "payload": { "...entity fields..." }
}
```

- `POST /v1/sync/push` with `{device_id, ops: [Envelope...]}` (max 500 ops) returns
  `{results: [{id, entity, status: "applied"|"conflict"|"rejected", server_version, server_record?, error?}], cursor}`.
  - `base_version` must equal the server's current version, or 0 for a new record. If it
    doesn't, the result is `conflict` and includes `server_record`. The server never
    overwrites silently; the client resolves and pushes again with the new base.
  - `deleted: true` creates a tombstone. A tombstoned id is never resurrected: a later
    non-deleted push for that id is `rejected` with code `tombstoned`.
- `GET /v1/sync/pull?cursor=<opaque>&limit=500` returns
  `{records: [Envelope...], cursor, has_more}`. The cursor is a server change sequence,
  scoped to the user plus their household memberships.

Entity payloads are validated server-side per entity (see Payloads below).

## Ingestion helpers (cloud AI, consent-gated)

`POST /v1/ingest/extract`, used only when deterministic on-device parsing fails and the user
granted `cloud_ai`.

Request: `{text, sender?, locale_hint?, received_at?}`. The client has already removed OTPs and
masked full card numbers.

Response:

```json
{
  "status": "extracted|not_financial|ambiguous|disabled",
  "result": {
    "kind": "purchase|income|transfer_in|transfer_out|atm_withdrawal|fee|refund|reversal|card_payment|installment|declined|otp|balance_only|unknown",
    "amount_minor": 5250,
    "currency": "KWD",
    "merchant": "Talabat",
    "card_last4": "1234",
    "balance_minor": null,
    "occurred_at": null,
    "confidence": 0.82,
    "evidence": {"amount": "5.250", "currency": "KWD", "merchant": "TALABAT"}
  },
  "provider": "azure_openai",
  "model": "..."
}
```

The server validates that each `evidence` substring appears in the input text and that the
amount parses from that evidence. Otherwise the field is nulled and `status` becomes
`ambiguous`.

`POST /v1/ingest/document` (multipart, PDF/CSV/image up to 10 MB) returns `Job`. Its result is
candidate transactions for preview. The server stores nothing after the job finishes, except an
encrypted temporary blob that is deleted within 24 hours.

`POST /v1/samples` with `{bank_id?, sender?, sanitized_text, kind_hint?, app_version}` submits a
sanitized parser sample (requires the `sample_submission` consent).

## Assistant (LLM proxy, tools execute on device)

`POST /v1/assistant/turn`

```json
{
  "conversation_id": "uuid",
  "locale": "ar|en",
  "messages": [{"role": "user|assistant|tool", "content": "...", "tool_call_id": null, "tool_calls": null}],
  "tools": [{"name": "spending_summary", "description": "...", "parameters": {"type": "object", "properties": {}}}],
  "context": {"currency": "KWD", "timezone": "Asia/Kuwait", "today": "2026-11-22", "cycle_start_day": 25}
}
```

Response: `{message: {role: "assistant", content?, tool_calls?: [{id, name, arguments}]}, usage: {input_tokens, output_tokens}, provider, model}`.

The server never queries the user's financial data for the assistant. The device runs the
deterministic tools and sends back only their results (aggregates). The server enforces the
`cloud_ai` consent, per-user rate limits and a monthly token budget, which are configurable
(`429 quota_exceeded`).

### My Smart Plan (understanding and explanations only)

`POST /v1/assistant/plan`. The request model **forbids extra fields**.

- **`stage: "understand"`:** `{conversation_id, locale, text (≤600), categories: [id], today, cycle_start_day}`.
  - Returns `{status: "ok", intent: {target_minor?, target_evidence?, currency?, deadline?, months?, protected_categories[], income_minor?, income_evidence?, commitments[{category_id, amount_minor, evidence}]}}`, or `{status: "invalid_output"}`.
- **`stage: "explain"`:** `{conversation_id, locale, status, facts: [{id, label (≤80), amount ("NNN.NNN KWD"), source}], actions: [{id: "cut:<category>", category}], limitations: [code]}`.
  - Returns `{status: "ok", explanation: {summary, actions: [{id, why}]}}`, or `{status: "invalid_output"}`.

How it's enforced:
- The tool schemas are defined on the server, and the model is forced to call `record_goal` or `explain_plan`. Arguments are validated, and explanations may cite numbers only as `{fact:ID}`.
- The device re-validates everything: each amount must appear in the user's own words, and every displayed amount comes from facts the device computed.
- Same consent, rate-limit group and monthly budget as `/assistant/turn`.
- Errors: `403 consent_required`, `503 provider_not_configured`, `429 quota_exceeded`, `422` for extra or invalid fields.

## Voice

- `POST /v1/voice/token` returns `{provider: "azure", region, token, expires_at}`: a short-lived
  Azure Speech authorization token (about 10 minutes). The app calls Azure Speech REST directly
  with it. No long-lived key ever reaches the app. Requires the `cloud_voice` consent.
  Returns `503 provider_not_configured` when Azure Speech isn't configured.
- `GET /v1/voice/config` returns `{stt_locales: ["ar-KW","en-US",...], tts_voices: {"ar": "ar-KW-NouraNeural", "en": "en-US-AvaNeural"}, enabled}`.

## Households

| Method | Path | Notes |
|---|---|---|
| POST | /v1/households | `{name}` creates one; the caller becomes `owner` |
| GET | /v1/households | Mine |
| POST | /v1/households/{id}/invitations | `{role: "member"|"viewer", expires_in_hours?}` returns `{invitation_id, code, expires_at}`. Only the owner may invite. The code is shown once; the server stores only its hash. |
| POST | /v1/households/join | `{code}` joins and returns `Membership` |
| DELETE | /v1/households/{id}/members/{user_id} | Owner removes someone, or a member leaves |
| DELETE | /v1/households/{id}/invitations/{inv_id} | Revoke |

Shared data: a sync envelope with `household_id` set is visible to members. Transactions are
never shared automatically. A user explicitly marks a transaction or budget as shared, which
creates a household-scoped copy referencing the original id. Viewers cannot push.

## Billing and entitlements

- `GET /v1/billing/products` returns the configured product ids and plan display metadata. No
  prices: those come from StoreKit or Play.
- `POST /v1/billing/apple/verify` with `{signed_transaction}` (StoreKit 2 JWS) returns `Entitlements`.
- `POST /v1/billing/google/verify` with `{product_id, purchase_token}` returns `Entitlements`.
- `POST /v1/billing/restore` with `{platform, signed_transactions?: [], purchase_tokens?: []}` returns `Entitlements`.
- `POST /v1/webhooks/apple`: App Store Server Notifications V2 (JWS verified against the Apple root CA).
- `POST /v1/webhooks/google`: Play RTDN through a Pub/Sub push with OIDC JWT verification.
- `Entitlements = {plan: "free"|"premium", source: "dev_unlocked"|"apple"|"google"|"none", expires_at?, in_grace_period, features: {...}}`

In `development` and `staging`, every user gets `plan: premium, source: dev_unlocked`.

## Health

`GET /healthz` (liveness) and `GET /readyz` (database plus migrations at head).

## Entity payloads (sync)

Every payload also carries `id`. Every money field is `*_minor` as an integer, with its
currency on the same object. The server validates types, enum values, ownership of any
referenced ids (they must belong to the same user or the same household scope) and
`currency` as a 3-letter uppercase code.

- **account**: `name, kind: bank|card|cash|wallet|loan|savings, institution_id?, currency, mask_last4?, is_liability, credit_limit_minor?, opening_balance_minor, opening_balance_date, reported_balance_minor?, reported_available_minor?, reported_balance_at?, archived, color?, sort_order, is_default, include_in_net_worth`
- **transaction**: `account_id, kind: expense|income|transfer|refund|adjust_up|adjust_down, status: posted|pending|declined|void, amount_minor (>=0), currency, counter_account_id?, counter_amount_minor?, original_amount_minor?, original_currency?, fx_rate? (decimal string), fx_source?, merchant?, merchant_raw?, category_id?, note?, occurred_at, received_at?, source: manual|voice|sms|notification|shortcut|wallet|csv|pdf|image|paste|share|recurring, source_event_id?, refund_of_id?, transfer_group_id?, parser_id?, parser_version?, confidence?, needs_review, splits: [{category_id, amount_minor, note?}]`
- **category**: `name_en, name_ar, icon, color, kind: expense|income, parent_id?, is_system, archived`
- **budget**: `category_id?, amount_minor, currency, period: cycle|monthly|weekly, rollover, alert_thresholds: [int], start_date`
- **goal**: `name, emoji?, target_minor, currency, target_date?, account_id?, planned_monthly_minor?, contributions: [{id, amount_minor, date, note?}], archived`
- **recurring**: `name, kind: subscription|rent|installment|bill|salary|other, amount_minor, currency, account_id?, category_id?, cadence: weekly|monthly|yearly, interval, anchor_date, next_due_date, total_occurrences?, completed_occurrences, merchant_pattern?, status: suggested|active|paused|ended, reminder_days_before`
- **merchant_alias**: `pattern, merchant, category_id?`
- **asset**: `name, kind: gold|property|vehicle|investment|deposit|cash|other|loan, is_liability, value_minor, currency, valuation_date, valuation_source: manual, linked_account_id?, note?`
- **setting**: `key, value` (JSON value). Only synced keys, such as salary day and base currency.
