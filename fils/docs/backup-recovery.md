# Backup and recovery

## What is backed up

| Data | Location | Backup |
|---|---|---|
| Cloud data (users, sessions, consents, sync records, households, billing, jobs) | Azure Database for PostgreSQL Flexible Server | Automated daily full backups plus WAL. Point-in-time restore (PITR) for **7 days in staging, 35 days in production**. Geo-redundant backup in production (`infra/azure/params/production.bicepparam`). |
| Temporary uploads and exports | `temp_blobs` table (AES-GCM, purged after 24 h) | Not meant to be restored. Regenerate instead. |
| Secrets | Key Vault | Soft delete 90 days, purge protection in production. |
| On-device data | Encrypted local DB | Restored from cloud sync only if the user enabled sync or backup. Otherwise the user's own data export is the only copy. The DB key is device-bound by design and never in OS backups. |

RPO/RTO targets (proposed): RPO ≤ 5 min (PITR), RTO ≤ 1 h for a regional restore within the same
region, ≤ 4 h for a geo-restore.

## Restore procedures (Azure)

**Point-in-time restore to a new server.** The original stays untouched for forensics.

```bash
az postgres flexible-server restore -g rg-fils-production \
  --name fils-production-pg-restore-$(date +%Y%m%d%H%M) \
  --source-server <source-server-name> \
  --restore-time "2026-11-22T10:15:00Z"
```

**Geo-restore** (production; the paired region must have capacity):

```bash
az postgres flexible-server geo-restore -g rg-fils-production-dr \
  --name fils-production-pg-geo --source-server <source-server-resource-id> --location <paired-region>
```

**After a restore:**

1. Update the Key Vault secret `fils-database-url` to the restored server.
2. Restart the API and worker revisions, then run the migrate job (`alembic upgrade head` is a no-op
   at head).
3. Check `/readyz` and compare row counts against the last known metrics.

Note: restoring rolls sync state back. Clients with local changes newer than the restore point push
them again (their outbox), and records the server no longer knows are created again with
`base_version` 0. Version mismatches surface as conflicts. Never resurrect tombstones manually.

**Logical dumps** (extra protection, and moving data between environments) run from a Container Apps
job or jump host inside the VNet:

```bash
pg_dump -Fc --no-owner -h <server>.postgres.database.azure.com -U filsadmin -d fils -f fils.dump
```

## Restore drill (executed locally on 2026-11-22)

Scripts: `backend/scripts/seed_drill_data.sh` seeds synthetic data through the public API (demo
session, consent and a sync push). `backend/scripts/restore_drill.sh` dumps the database, restores it
into a fresh database, checks the Alembic revision and compares row counts table by table.

Commands run:

```text
$ API=http://localhost:8077 scripts/seed_drill_data.sh
seeded: {'applied': 6}
$ scripts/restore_drill.sh
== 1. dump fils -> /tmp/fils_20261122T183857.dump
dump size bytes: 38070
a9773aaed25b984194d5d06d9ac3b448070b8be7ac73ee84ee3d333698826646  /tmp/fils_20261122T183857.dump
== 2. restore into new database fils_restore_drill_1795372737
== 3. alembic current on restored database
0001 (head)
== 4. row counts (source vs restored)
table                            source   restored
ai_usage                              0          0 ok
alembic_version                       1          1 ok
audit_events                          0          0 ok
auth_identities                       2          2 ok
auth_nonces                           0          0 ok
billing_events                        0          0 ok
consent_records                       1          1 ok
entitlements                          0          0 ok
household_invitations                 0          0 ok
household_members                     0          0 ok
households                            0          0 ok
idempotency_keys                      1          1 ok
jobs                                  0          0 ok
parser_samples                        0          0 ok
purchase_links                        0          0 ok
refresh_tokens                        2          2 ok
sessions                              2          2 ok
sync_records                          6          6 ok
temp_blobs                            0          0 ok
users                                 2          2 ok
== cleaned up fils_restore_drill_1795372737 and dump
RESTORE DRILL PASSED
```

Scope of this evidence: the drill used local PostgreSQL 16 with synthetic data. **An Azure PITR or
geo-restore has not been exercised**, because no Azure environment exists yet. Repeat the drill
against staging after the first deployment, then quarterly.
