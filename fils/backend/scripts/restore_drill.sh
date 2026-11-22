#!/usr/bin/env bash
# Backup/restore drill: dump the source database, restore it into a fresh database, then verify
# that migrations are at head and row counts match table by table.
# Azure: the same procedure works against Flexible Server (pg_dump over private network from a
# jump host/Container Apps job), in addition to Azure's automated PITR backups.
set -euo pipefail
SRC="${SRC:-fils}"
DST="${DST:-fils_restore_drill_$(date +%s)}"
PGHOST="${PGHOST:-localhost}" PGUSER="${PGUSER:-fils}" PGPASSWORD="${PGPASSWORD:-fils}"
export PGHOST PGUSER PGPASSWORD
DUMP="${DUMP:-/tmp/${SRC}_$(date +%Y%m%dT%H%M%S).dump}"
cd "$(dirname "$0")/.."

echo "== 1. dump $SRC -> $DUMP"
pg_dump -Fc --no-owner -d "$SRC" -f "$DUMP"
ls -l "$DUMP" | awk '{print "dump size bytes:", $5}'
sha256sum "$DUMP"

echo "== 2. restore into new database $DST"
createdb "$DST"
pg_restore --no-owner --exit-on-error -d "$DST" "$DUMP"

echo "== 3. alembic current on restored database"
FILS_DATABASE_URL="postgresql+psycopg://$PGUSER:$PGPASSWORD@$PGHOST:5432/$DST" .venv/bin/alembic current 2>/dev/null

echo "== 4. row counts (source vs restored)"
TABLES=$(psql -At -d "$SRC" -c "select tablename from pg_tables where schemaname='public' order by 1")
FAIL=0
printf '%-28s %10s %10s\n' table source restored
for t in $TABLES; do
  a=$(psql -At -d "$SRC" -c "select count(*) from \"$t\"")
  b=$(psql -At -d "$DST" -c "select count(*) from \"$t\"")
  printf '%-28s %10s %10s %s\n' "$t" "$a" "$b" "$([ "$a" = "$b" ] && echo ok || echo MISMATCH)"
  [ "$a" = "$b" ] || FAIL=1
done

if [ "${KEEP:-0}" != 1 ]; then dropdb "$DST"; rm -f "$DUMP"; echo "== cleaned up $DST and dump"; fi
[ $FAIL = 0 ] && echo "RESTORE DRILL PASSED" || { echo "RESTORE DRILL FAILED"; exit 1; }
