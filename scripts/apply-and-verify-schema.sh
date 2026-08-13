#!/bin/bash
# Applies schemas/db/postgresql_schema.sql idempotently, then verifies every
# object it declares actually exists in the target database. ADR 0015.
#
# Connection: if PGHOST/PGUSER/PGPASSWORD are already exported, they're used
# as-is (useful for local/manual runs). Otherwise, credentials are fetched
# from Key Vault via this host's managed identity, the same pattern ADR 0009
# established - no secret value is ever printed or stored by this script.
#
# Usage: scripts/apply-and-verify-schema.sh [path-to-postgresql_schema.sql]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_FILE="${1:-$REPO_ROOT/schemas/db/postgresql_schema.sql}"
KEY_VAULT="${LUXAUTO_KEY_VAULT:-luxauto-kv-90a311}"

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "Schema file not found: $SCHEMA_FILE" >&2
  exit 2
fi

fetch_secret() {
  local secret_name="$1"
  local token
  token=$(curl -s -H "Metadata:true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fvault.azure.net" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  curl -s -H "Authorization: Bearer $token" \
    "https://${KEY_VAULT}.vault.azure.net/secrets/${secret_name}?api-version=7.4" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])"
}

if [[ -z "${PGHOST:-}" || -z "${PGUSER:-}" || -z "${PGPASSWORD:-}" ]]; then
  echo "PGHOST/PGUSER/PGPASSWORD not set - fetching from Key Vault ($KEY_VAULT) via managed identity."
  export PGUSER="${PGUSER:-$(fetch_secret postgres-admin-username)}"
  export PGPASSWORD="${PGPASSWORD:-$(fetch_secret postgres-admin-password)}"
  export PGHOST="${PGHOST:-$(fetch_secret postgres-fqdn)}"
fi
export PGSSLMODE="${PGSSLMODE:-require}"
export PGDATABASE="${PGDATABASE:-luxauto}"

echo "=== Applying $SCHEMA_FILE to $PGDATABASE@$PGHOST ==="
psql -v ON_ERROR_STOP=1 -f "$SCHEMA_FILE"

echo ""
echo "=== Verifying ==="
python3 "$SCRIPT_DIR/lib/verify_schema.py" "$SCHEMA_FILE"
