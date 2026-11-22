#!/usr/bin/env bash
# Seeds synthetic data through the public API (demo session + consent + sync push) so a restore
# drill has real rows to verify. Development/staging only (the demo endpoint 404s in production).
set -euo pipefail
API="${API:-http://localhost:8000}"
DEV=$(python3 -c 'import uuid;print(uuid.uuid4())')
AUTH=$(curl -fsS -X POST "$API/v1/demo/session" -H 'content-type: application/json' \
  -d "{\"device_id\":\"$DEV\",\"platform\":\"android\",\"app_version\":\"drill\"}")
TOKEN=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["access_token"])' "$AUTH")
H=(-H "authorization: Bearer $TOKEN" -H 'content-type: application/json')
curl -fsS -X POST "$API/v1/me/consents" "${H[@]}" -d '{"kind":"cloud_sync","granted":true,"policy_version":"drill","source":"script"}' >/dev/null
ACC=$(python3 -c 'import uuid;print(uuid.uuid4())')
OPS=$(python3 - "$ACC" <<'PY'
import json, sys, uuid
acc = sys.argv[1]
ops = [{"entity": "account", "id": acc, "version": 1, "base_version": 0, "deleted": False,
        "updated_at": "2026-11-22T10:00:00Z", "household_id": None,
        "payload": {"id": acc, "name": "Drill Bank", "kind": "bank", "currency": "KWD",
                    "opening_balance_minor": 100000, "opening_balance_date": "2026-11-01"}}]
for i in range(5):
    t = str(uuid.uuid4())
    ops.append({"entity": "transaction", "id": t, "version": 1, "base_version": 0, "deleted": False,
                "updated_at": "2026-11-22T10:00:00Z", "household_id": None,
                "payload": {"id": t, "account_id": acc, "kind": "expense", "status": "posted",
                            "amount_minor": 1250 * (i + 1), "currency": "KWD", "category_id": "food",
                            "occurred_at": f"2026-11-1{i}T09:00:00Z", "source": "manual", "merchant": "Synthetic"}})
print(json.dumps({"device_id": str(uuid.uuid4()), "ops": ops}))
PY
)
curl -fsS -X POST "$API/v1/sync/push" "${H[@]}" -H "idempotency-key: $(python3 -c 'import uuid;print(uuid.uuid4())')" -d "$OPS" \
  | python3 -c 'import json,sys;r=json.load(sys.stdin)["results"];print("seeded:", {s:sum(1 for x in r if x["status"]==s) for s in {x["status"] for x in r}})'
