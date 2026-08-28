#!/usr/bin/env bash
#
# Provision + deploy the luxauto demo OPERATOR CONTROL PANEL:
#   - Azure Static Web App (Standard) serving ./frontend, custom Entra auth,
#     gated behind a SEPARATE allow-list (Entra group `luxauto-control-access`).
#   - Linked Azure Functions app (./api) on FLEX CONSUMPTION whose system-assigned
#     managed identity reads/writes three small control blobs in a PRIVATE
#     container. The API holds NO database credential.
#
# This is a SIBLING to the dashboard's SWA + Function App and reuses the exact
# proven pattern (see ../../dashboard-swa/deploy/deploy.sh). It does NOT touch,
# redeploy, or reconfigure the dashboard, its API, its exporter, or its auth.
#
# Learned deploy notes carried over from the dashboard build:
#   - Legacy Linux *Consumption* rejects Node 20 (EOL) and had SCM 503s in this
#     region. FLEX CONSUMPTION works (~$0 idle).
#   - Publish the API PREBUILT (node_modules bundled; deps pure JS) via
#     `func ... publish --no-build`. Remote Oryx build over SCM was unreliable.
#
# REQUIRES: the caller (the luxauto-odoo VM managed identity) has Contributor on
# RG luxauto-rg. This script performs NO role assignment to another principal —
# the Storage Blob Data Contributor grants (to the Function App identity AND the
# VM identity, both scoped to the demo-control container) are operator portal
# steps (see OPERATOR-CHECKLIST.md).
set -euo pipefail

SUBSCRIPTION="ff1d4234-2dc1-476c-b350-ddabbc59c566"
TENANT_ID="2c7981fb-d0ee-46b6-a5c2-87aaa0a84d0b"
RG="luxauto-rg"
LOCATION="eastus2"
STORAGE_ACCT="luxautosa91a2e1"          # existing storage (shared with the dashboard); NOT created here
CONTROL_CONTAINER="demo-control"        # NEW private container for the 3 control blobs

SWA_NAME="luxauto-control-swa"
FUNC_NAME="luxauto-control-api"
FUNC_STORAGE="luxautoctlapi12b4"        # backing storage for THIS Function App (reused if present)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$HERE/../frontend"
API_DIR="$HERE/../api"

echo "==> Login with the VM managed identity"
az login --identity -o none
az account set --subscription "$SUBSCRIPTION"

echo "==> Private control container '$CONTROL_CONTAINER' in $STORAGE_ACCT (best-effort; see checklist if this errors)"
az storage container create --name "$CONTROL_CONTAINER" --account-name "$STORAGE_ACCT" \
  --auth-mode login --public-access off -o none 2>/dev/null \
  && echo "    container ready" \
  || echo "    (could not create with current data-plane rights — do checklist Step A)"

echo "==> Backing storage for the control Function App"
az storage account show -n "$FUNC_STORAGE" -g "$RG" -o none 2>/dev/null || \
az storage account create -n "$FUNC_STORAGE" -g "$RG" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false -o none

echo "==> Control Function App (Flex Consumption, Node 20) with a system-assigned identity"
az functionapp show -n "$FUNC_NAME" -g "$RG" -o none 2>/dev/null || \
az functionapp create -n "$FUNC_NAME" -g "$RG" \
  --storage-account "$FUNC_STORAGE" \
  --flexconsumption-location "$LOCATION" \
  --runtime node --runtime-version 20 \
  --assign-identity '[system]' -o none
az functionapp update -n "$FUNC_NAME" -g "$RG" --set httpsOnly=true -o none

echo "==> Publish the control API as a prebuilt package (node_modules bundled)"
( cd "$API_DIR" && npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1 \
  && func azure functionapp publish "$FUNC_NAME" --javascript --no-build )

echo "==> Static Web App (Standard)"
az staticwebapp show -n "$SWA_NAME" -g "$RG" -o none 2>/dev/null || \
az staticwebapp create -n "$SWA_NAME" -g "$RG" -l "$LOCATION" --sku Standard -o none

echo "==> Entra app settings (seed placeholders only where missing/placeholder; PRESERVE real values)"
# On redeploy the operator's real ENTRA_CLIENT_ID/SECRET (supplied per checklist Step 3) must
# survive. Only (re)write the placeholder when the setting is empty/missing OR still holds a
# REPLACE_WITH_* placeholder. A "real value" (non-empty AND not REPLACE_WITH_*) is left untouched.
CUR_ID="$(az staticwebapp appsettings list -n "$SWA_NAME" -g "$RG" --query "properties.ENTRA_CLIENT_ID" -o tsv 2>/dev/null || true)"
CUR_SECRET="$(az staticwebapp appsettings list -n "$SWA_NAME" -g "$RG" --query "properties.ENTRA_CLIENT_SECRET" -o tsv 2>/dev/null || true)"

ENTRA_SETTINGS=()
if [ -z "$CUR_ID" ] || [[ "$CUR_ID" == REPLACE_WITH_* ]]; then
  ENTRA_SETTINGS+=( ENTRA_CLIENT_ID="REPLACE_WITH_APP_CLIENT_ID" )
else
  echo "    ENTRA_CLIENT_ID already holds a real value — preserving"
fi
if [ -z "$CUR_SECRET" ] || [[ "$CUR_SECRET" == REPLACE_WITH_* ]]; then
  ENTRA_SETTINGS+=( ENTRA_CLIENT_SECRET="REPLACE_WITH_APP_CLIENT_SECRET" )
else
  echo "    ENTRA_CLIENT_SECRET already holds a real value — preserving"
fi

if [ "${#ENTRA_SETTINGS[@]}" -gt 0 ]; then
  az staticwebapp appsettings set -n "$SWA_NAME" --setting-names "${ENTRA_SETTINGS[@]}" -o none
else
  echo "    both Entra settings already populated — nothing to write"
fi

echo "==> Deploy the frontend (static content) via the SWA CLI"
TOKEN="$(az staticwebapp secrets list -n "$SWA_NAME" -g "$RG" --query 'properties.apiKey' -o tsv)"
( cd "$HERE/.." && swa deploy "$FRONTEND_DIR" --deployment-token "$TOKEN" --env production )

echo "==> Link the Function App as the SWA backend (locks the backend to SWA-only traffic)"
FUNC_ID="$(az functionapp show -n "$FUNC_NAME" -g "$RG" --query id -o tsv)"
az staticwebapp backends link -n "$SWA_NAME" -g "$RG" \
  --backend-resource-id "$FUNC_ID" --backend-region "$LOCATION" -o none

SWA_HOST="$(az staticwebapp show -n "$SWA_NAME" -g "$RG" --query defaultHostname -o tsv)"
FUNC_MI_OBJID="$(az functionapp identity show -n "$FUNC_NAME" -g "$RG" --query principalId -o tsv)"

echo
echo "=================== CONTROL PANEL DEPLOY COMPLETE — OPERATOR VALUES ==================="
echo "Site URL                 : https://$SWA_HOST"
echo "Entra redirect URI       : https://$SWA_HOST/.auth/login/entra/callback"
echo "Control Function App     : $FUNC_NAME"
echo "Function App MI objectId : $FUNC_MI_OBJID   <-- grant Storage Blob Data Contributor to THIS"
echo "VM identity (agent)      : luxauto-odoo (object ID e67de137-c107-41fd-8226-1b3c0276504b)"
echo "                           <-- ALSO grant Storage Blob Data Contributor to THIS"
echo "Blob role scope          : /subscriptions/$SUBSCRIPTION/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCT/blobServices/default/containers/$CONTROL_CONTAINER"
echo "Allow-list group to make : luxauto-control-access  (DISTINCT from luxauto-dashboard-access)"
echo "Next steps               : see deploy/OPERATOR-CHECKLIST.md"
echo "======================================================================================"
