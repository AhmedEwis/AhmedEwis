#!/usr/bin/env bash
# Fils backend deployment to Azure. Review each step; nothing here runs automatically.
# Usage: ENV=staging LOCATION=uaenorth ./deploy.sh <step>
#   steps: infra | secrets | image | apps | migrate | shift | rollback
# Prereqs: az CLI >= 2.60 with bicep (az bicep install), docker, rights on the subscription.
set -euo pipefail

ENV="${ENV:?set ENV=staging|production}"
LOCATION="${LOCATION:-uaenorth}"        # nearest Azure region to Kuwait at time of writing; verify data-residency needs
RG="${RG:-rg-fils-$ENV}"
PARAMS="params/$ENV.bicepparam"
TAG="${TAG:-$(git rev-parse --short HEAD)}"
cd "$(dirname "$0")"

out() { az deployment group show -g "$RG" -n main --query "properties.outputs.$1.value" -o tsv; }

case "${1:-}" in
  infra)
    : "${FILS_PG_ADMIN_PASSWORD:?export FILS_PG_ADMIN_PASSWORD (generate: openssl rand -base64 32)}"
    az group create -n "$RG" -l "$LOCATION" --tags app=fils env="$ENV"
    # Always preview first.
    az deployment group what-if -g "$RG" -n main -f main.bicep -p "$PARAMS" -p deployApps=false
    read -rp "Apply infra (deployApps=false)? [y/N] " ok; [[ "$ok" == y ]] || exit 1
    az deployment group create -g "$RG" -n main -f main.bicep -p "$PARAMS" -p deployApps=false
    ;;
  secrets)
    : "${FILS_PG_ADMIN_PASSWORD:?export FILS_PG_ADMIN_PASSWORD}"
    KV=$(out keyVaultName); PG=$(out postgresFqdn)
    # The operator needs "Key Vault Secrets Officer" on the vault for this step.
    az keyvault secret set --vault-name "$KV" -n fils-jwt-secret  --value "$(python3 -c 'import secrets;print(secrets.token_urlsafe(48))')" -o none
    az keyvault secret set --vault-name "$KV" -n fils-data-key    --value "$(python3 -c 'import os,base64;print(base64.b64encode(os.urandom(32)).decode())')" -o none
    az keyvault secret set --vault-name "$KV" -n fils-database-url --value "postgresql+psycopg://filsadmin:${FILS_PG_ADMIN_PASSWORD}@${PG}:5432/fils?sslmode=require" -o none
    az keyvault secret set --vault-name "$KV" -n fils-pg-admin-password --value "$FILS_PG_ADMIN_PASSWORD" -o none
    echo "Optional (only when configured): fils-azure-openai-api-key, fils-azure-speech-key, fils-docintel-key, fils-google-service-account-json"
    echo "Then pass them via the optionalSecrets param of modules/containerapps.bicep."
    ;;
  image)
    ACR=$(out acrLoginServer)
    az acr login -n "${ACR%%.*}"
    docker build -t "$ACR/fils-api:$TAG" ../../backend
    docker push "$ACR/fils-api:$TAG"
    ;;
  apps)
    az deployment group what-if -g "$RG" -n main -f main.bicep -p "$PARAMS" -p deployApps=true apiImage="fils-api:$TAG"
    read -rp "Apply apps? [y/N] " ok; [[ "$ok" == y ]] || exit 1
    az deployment group create -g "$RG" -n main -f main.bicep -p "$PARAMS" -p deployApps=true apiImage="fils-api:$TAG"
    ;;
  migrate)
    # Run migrations with the new image BEFORE shifting traffic. Migrations must be backward
    # compatible with the previous revision (expand/contract).
    ACR=$(out acrLoginServer)
    az containerapp job update -g "$RG" -n "fils-$ENV-migrate" --image "$ACR/fils-api:$TAG"
    EXEC=$(az containerapp job start -g "$RG" -n "fils-$ENV-migrate" --query name -o tsv)
    echo "Started $EXEC; waiting..."
    for _ in $(seq 1 60); do
      S=$(az containerapp job execution show -g "$RG" -n "fils-$ENV-migrate" --job-execution-name "$EXEC" --query properties.status -o tsv)
      [[ "$S" == Succeeded ]] && { echo "migration ok"; exit 0; }
      [[ "$S" == Failed ]] && { echo "migration FAILED - do not shift traffic"; exit 1; }
      sleep 10
    done
    echo "timeout"; exit 1
    ;;
  shift)
    ACR=$(out acrLoginServer)
    az containerapp update -g "$RG" -n "fils-$ENV-api" --image "$ACR/fils-api:$TAG" --revision-suffix "r$TAG"
    NEW="fils-$ENV-api--r$TAG"
    # Canary: 10% then 100% once /readyz is healthy and error rates are normal.
    az containerapp ingress traffic set -g "$RG" -n "fils-$ENV-api" --revision-weight "$NEW=10" latest=0 || true
    read -rp "Promote $NEW to 100%? [y/N] " ok; [[ "$ok" == y ]] || exit 1
    az containerapp ingress traffic set -g "$RG" -n "fils-$ENV-api" --revision-weight "$NEW=100"
    az containerapp update -g "$RG" -n "fils-$ENV-worker" --image "$ACR/fils-api:$TAG"
    ;;
  rollback)
    : "${PREV:?export PREV=<previous revision name, see: az containerapp revision list -g $RG -n fils-$ENV-api -o table>}"
    az containerapp ingress traffic set -g "$RG" -n "fils-$ENV-api" --revision-weight "$PREV=100"
    echo "API traffic back on $PREV. Roll the worker image back with: az containerapp update -g $RG -n fils-$ENV-worker --image <prev image>"
    echo "Database: migrations are not auto-reverted; only run 'alembic downgrade -1' via the migrate job if the change is known reversible."
    ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
