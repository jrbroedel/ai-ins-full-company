#!/usr/bin/env bash
#
# Provision + deploy the luxauto demo dashboard:
#   - Azure Static Web App (Standard) that serves ./frontend and enforces custom Entra auth
#   - Linked Azure Functions app (./api) on the FLEX CONSUMPTION plan that reads the private
#     snapshot blob server-side via its system-assigned managed identity
#
# This reflects what was actually deployed. Notes learned during the deploy:
#   - Azure rejects Node 20 on the legacy Linux *Consumption* plan (EOL); that plan also
#     failed to start (persistent SCM 503) in this region. FLEX CONSUMPTION works and is the
#     recommended serverless plan (~$0 idle).
#   - Deploy the API as a PREBUILT package (node_modules bundled; deps are pure JS) via
#     `func ... publish --no-build`. Remote Oryx build over SCM was unreliable here.
#
# REQUIRES: the caller (the luxauto-odoo VM managed identity) has Contributor on RG
# luxauto-rg. This script performs NO role assignment to another principal — the
# Storage Blob Data Reader grant to the Function App identity is an operator portal step
# (see OPERATOR-CHECKLIST.md, Step 6).
set -euo pipefail

SUBSCRIPTION="ff1d4234-2dc1-476c-b350-ddabbc59c566"
TENANT_ID="2c7981fb-d0ee-46b6-a5c2-87aaa0a84d0b"
RG="luxauto-rg"
LOCATION="eastus2"
STORAGE_ACCT="luxautosa91a2e1"          # existing exporter storage (NOT created/touched here)

SWA_NAME="luxauto-dashboard-swa"
FUNC_NAME="luxauto-dashboard-api"
FUNC_STORAGE="luxautoapi97276"          # backing storage for the Function App (reused if present)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$HERE/../frontend"
API_DIR="$HERE/../api"

echo "==> Login with the VM managed identity"
az login --identity -o none
az account set --subscription "$SUBSCRIPTION"

echo "==> (operator pre-req) providers Microsoft.Web / Microsoft.Storage must be Registered"

echo "==> Backing storage for the Function App"
az storage account show -n "$FUNC_STORAGE" -g "$RG" -o none 2>/dev/null || \
az storage account create -n "$FUNC_STORAGE" -g "$RG" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false -o none

echo "==> Function App (Flex Consumption, Node 20) with a system-assigned identity"
az functionapp show -n "$FUNC_NAME" -g "$RG" -o none 2>/dev/null || \
az functionapp create -n "$FUNC_NAME" -g "$RG" \
  --storage-account "$FUNC_STORAGE" \
  --flexconsumption-location "$LOCATION" \
  --runtime node --runtime-version 20 \
  --assign-identity '[system]' -o none
az functionapp update -n "$FUNC_NAME" -g "$RG" --set httpsOnly=true -o none

echo "==> Publish the API as a prebuilt package (node_modules bundled)"
( cd "$API_DIR" && npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1 \
  && func azure functionapp publish "$FUNC_NAME" --javascript --no-build )

echo "==> Static Web App (Standard)"
az staticwebapp show -n "$SWA_NAME" -g "$RG" -o none 2>/dev/null || \
az staticwebapp create -n "$SWA_NAME" -g "$RG" -l "$LOCATION" --sku Standard -o none

echo "==> Placeholder Entra app settings (operator supplies real values, checklist Step 3)"
az staticwebapp appsettings set -n "$SWA_NAME" \
  --setting-names ENTRA_CLIENT_ID="REPLACE_WITH_APP_CLIENT_ID" ENTRA_CLIENT_SECRET="REPLACE_WITH_APP_CLIENT_SECRET" -o none

echo "==> Deploy the frontend (static content) via the SWA CLI (run from parent dir)"
TOKEN="$(az staticwebapp secrets list -n "$SWA_NAME" -g "$RG" --query 'properties.apiKey' -o tsv)"
( cd "$HERE/.." && swa deploy "$FRONTEND_DIR" --deployment-token "$TOKEN" --env production )

echo "==> Link the Function App as the SWA backend (also locks the backend to SWA-only traffic)"
FUNC_ID="$(az functionapp show -n "$FUNC_NAME" -g "$RG" --query id -o tsv)"
az staticwebapp backends link -n "$SWA_NAME" -g "$RG" \
  --backend-resource-id "$FUNC_ID" --backend-region "$LOCATION" -o none

SWA_HOST="$(az staticwebapp show -n "$SWA_NAME" -g "$RG" --query defaultHostname -o tsv)"
FUNC_MI_OBJID="$(az functionapp identity show -n "$FUNC_NAME" -g "$RG" --query principalId -o tsv)"

echo
echo "=================== DEPLOY COMPLETE — OPERATOR VALUES ==================="
echo "Site URL                : https://$SWA_HOST"
echo "Entra redirect URI      : https://$SWA_HOST/.auth/login/entra/callback"
echo "Function App name       : $FUNC_NAME"
echo "Function App MI objectId: $FUNC_MI_OBJID   <-- grant Storage Blob Data Reader to THIS"
echo "Blob role scope         : /subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCT"
echo "Next steps              : see deploy/OPERATOR-CHECKLIST.md"
echo "========================================================================"
