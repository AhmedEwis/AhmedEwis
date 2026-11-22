# Deployment and operations

Nothing in this repo has been deployed to Azure. The templates and workflows are ready, and the steps
below are the exact procedure.

## Local development

```bash
cd fils/backend
docker compose up --build          # postgres → migrate → api (:8000) + worker
# or without Docker:
python3.13 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
export FILS_DATABASE_URL=postgresql+psycopg://fils:fils@localhost:5432/fils
.venv/bin/alembic upgrade head
.venv/bin/uvicorn fils_api.main:app --reload
.venv/bin/python -m fils_api.worker
```

Mobile:

```bash
cd fils/mobile
flutter run --flavor play --dart-define=FILS_ENV=development --dart-define=FILS_API_BASE_URL=http://10.0.2.2:8000
```

## Azure: first deployment (per environment)

Prerequisites:
- Azure subscription and a resource group per environment.
- `az` CLI with `az bicep install`.
- Docker.
- Rights: Owner on the resource group (role assignments) and Key Vault Secrets Officer for the
  secrets step.

```bash
cd fils/infra/azure
export ENV=staging LOCATION=uaenorth FILS_PG_ADMIN_PASSWORD="$(openssl rand -base64 32)"
./deploy.sh infra      # what-if, then network/identity/KV/ACR/Postgres/storage/monitoring
./deploy.sh secrets    # writes fils-jwt-secret, fils-data-key, fils-database-url to Key Vault
./deploy.sh image      # build + push fils-api:<git sha>
TAG=<sha> ./deploy.sh apps     # what-if, then Container Apps env + api + worker + migrate job
TAG=<sha> ./deploy.sh migrate  # alembic upgrade head as a job; must succeed before traffic
```

Then:
1. Point a custom domain plus a managed certificate at the API.
2. Set `FILS_API_BASE_URL` in the mobile build.
3. Configure the App Store Server Notifications URL (`/v1/webhooks/apple`) and the Play RTDN push
   endpoint (`/v1/webhooks/google`).

Region: `uaenorth` is a placeholder near Kuwait. Confirm the data residency decision first (see
`kuwait-regulatory.md`).

## Continuous deployment

`.github/workflows/deploy-backend.yml` (manual dispatch, GitHub Environments `staging` /
`production` with required reviewers on production):

1. OIDC login to Azure.
2. Build and push to ACR.
3. Record the current revision.
4. Run the migrate job.
5. Create the new API revision at 0% traffic and poll its `/readyz`.
6. Shift 100% of traffic.
7. Update the worker.

On failure it prints the exact rollback command.

Required GitHub configuration:

| Name | Kind | Value |
|---|---|---|
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | environment secrets | App registration with a federated credential for this repo/environment; grant Contributor on the RG plus AcrPush on the ACR |
| `ACR_LOGIN_SERVER` | environment variable | output `acrLoginServer` |
| `FILS_STAGING_API_URL` | repository variable | staging API URL for mobile CI builds |
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | secrets (optional) | Play upload key; without them, release APKs are unsigned or debug-signed |
| `GITLEAKS_LICENSE` | secret (org repos only) | gitleaks-action license |

## Migrations policy

Migrations follow an expand/contract approach. Each migration must work with both the previous and
the new app revision, because the migrate job runs before traffic shifts and the old revision keeps
serving until the switch.
- Additive changes ship first.
- Drops and renames ship one release later.
- CI verifies `upgrade → downgrade base → upgrade` on every change.

## Rollback

```bash
az containerapp revision list -g rg-fils-$ENV -n fils-$ENV-api -o table
PREV=<revision> ENV=$ENV ./deploy.sh rollback      # moves 100% traffic back instantly
```

Database migrations are not reverted automatically. Run `alembic downgrade -1` through the migrate
job only when the migration is known to be reversible and no data written since depends on it.
Otherwise roll forward with a fix. For data corruption, use PITR (`backup-recovery.md`).

## Secret rotation

| Secret | Procedure | Impact |
|---|---|---|
| `fils-jwt-secret` | `az keyvault secret set` with a new value, then restart revisions | All access tokens become invalid. Clients refresh automatically: refresh tokens are DB-backed, not JWTs |
| `fils-data-key` | Rotate only when no temp blobs are pending (they expire after 24 h): pause the worker, wait 24 h or purge, then set the new value | In-flight uploads and exports become unreadable |
| `fils-database-url` / Postgres password | `az postgres flexible-server update --admin-password`, update the KV secret, restart | Brief connection errors during restart |
| Azure OpenAI / Speech / Document Intelligence keys | Regenerate key2 → set KV → restart → regenerate key1 | None if done in this order |
| Google service account JSON | Create a new key, set KV, restart, delete the old key | None |

Container Apps cache Key Vault references. Restart (or deploy a new revision) after rotating secrets.

## Scheduled and retention jobs

The worker runs a retention sweep continuously (`fils_api/worker.py`):
- Expired temp blobs and document candidates are purged after 24 h.
- Expired nonces, idempotency keys and refresh tokens are cleaned up.
- Account hard deletes run from the job queue.

Failed jobs retry with backoff and land in a dead-letter state after `FILS_JOB_MAX_ATTEMPTS`. Monitor
them with the query below and alert when it returns more than 0.

```sql
select kind, count(*) from jobs where status = 'dead' group by 1;
```

## Monitoring

- Container Apps logs go to Log Analytics (redacted JSON logs).
- App Insights holds request metrics.
- Suggested alerts:
  - API 5xx above 2% for 5 min
  - `/readyz` failures
  - dead-letter jobs above 0
  - Postgres CPU above 80% or storage above 80%
  - assistant token budget exhaustion rate
- The Log Analytics daily cap is 2 GB (a cost guardrail). Raise it deliberately.

## Provider outage behavior

| Outage | Behavior |
|---|---|
| Backend down | The app keeps working offline. The outbox queues changes and sync retries later |
| Azure OpenAI down or budget hit | The on-device assistant answers common questions; extraction falls back to the review inbox |
| Azure Speech down | On-device speech recognition, then typing |
| Apple or Google JWKS unavailable | Sign-in fails with an error. Existing sessions keep working until their tokens expire |
| Store verification down | Entitlements keep their last verified state plus the configured grace period |
