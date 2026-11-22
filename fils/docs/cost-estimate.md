# Cost estimate (Azure, monthly, USD)

> **These are estimates. Verify every line in the Azure Pricing Calculator for your region before
> committing.** Unit prices are approximate list prices recalled at the time of writing and differ
> by region (UAE North is usually pricier than US regions). They exclude taxes, support plans,
> reservations, Apple/Google developer fees, and store commissions (15–30% of subscription revenue).

## Assumptions

| Parameter | Staging | Production (launch) |
|---|---|---|
| Monthly active users | ~20 testers | 5,000 |
| Sync-enabled users | all testers | 40% (2,000) |
| API traffic | negligible | ~1.5 M requests/month |
| API replicas | 1 × 0.5 vCPU / 1 GiB, always on | 2–6 × 0.5 vCPU / 1 GiB |
| Worker | 1 × 0.25 vCPU / 0.5 GiB | 1–3 × 0.25 vCPU / 0.5 GiB |
| Postgres | B1ms, 32 GB, 7-day PITR | B2s, 64 GB, 35-day PITR, geo-redundant backup |
| Logs | < 1 GB/month | ~10 GB/month (2 GB/day cap) |
| Cloud AI users | testers | 25% of MAU × 30 questions/month × ~3k tokens/question ≈ 112 M tokens/month |
| Cloud speech | testers | 10% of MAU × 20 utterances × 6 s ≈ 17 hours/month |

Cloud AI and speech are **off by default** and consent-gated. The assistant token budget is capped
per user (`FILS_ASSISTANT_MONTHLY_TOKEN_BUDGET`, default 200k tokens), which bounds the worst case.

## Estimate

| Service | Unit-price assumption | Staging | Production |
|---|---|---|---|
| Container Apps (Consumption, always-on replicas) | ~$0.000024/vCPU-s, ~$0.000003/GiB-s, free grant applies | $15–35 | $70–200 |
| PostgreSQL Flexible (B1ms / B2s) + storage + backup | B1ms ~$15–25; B2s ~$50–70; storage ~$0.12–0.14/GB; geo backup storage extra | $20–30 | $70–110 |
| Key Vault (standard) | ~$0.03 per 10k operations | < $1 | $1–3 |
| Storage (LRS, near-empty, lifecycle 1 day) | ~$0.02/GB | < $1 | $1–3 |
| Log Analytics + App Insights | ~$2.3–2.8/GB ingested after free 5 GB | $0–3 | $15–30 |
| Container Registry | Basic ~$5, Standard ~$20 | $5 | $20 |
| VNet / private DNS | private DNS zone ~$0.50 + queries | ~$1 | ~$1 |
| **Infrastructure subtotal** | | **~$45–75** | **~$180–370** |
| Azure OpenAI | assume a small GPT-4o-mini–class deployment at ~$0.0002–0.0007 per 1k tokens blended in+out (verify current model price) | ~$0–2 | $25–80 for 112 M tokens |
| Azure Speech (STT, real-time/short audio) | ~$1 per audio hour (standard) | ~$0 | $15–25 |
| Document Intelligence (image statements, optional) | ~$1.5 per 1k pages (read model) | ~$0 | $0–10 |
| **Total** | | **~$50–80** | **~$220–480** |

## Cost controls already in place

- Log Analytics daily cap of 2 GB (`modules/monitoring.bicep`).
- Per-user monthly assistant token budget and rate limits in the backend.
- Statement blobs purged after 24 h, plus a storage lifecycle delete after 1 day.
- Staging runs one replica with no geo backup.
- Scale-to-zero is possible for staging (`apiMinReplicas = 0`), at the cost of a cold start.
- Postgres HA is off by default. Turning on ZoneRedundant HA roughly doubles the database cost (and
  needs a General Purpose SKU).
