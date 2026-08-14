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

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "Schema file not found: $SCHEMA_FILE" >&2
  exit 2
fi

# Was inline here until ADR 0022; run-tests.sh needs the identical connection
# and a second copy would be a second thing to keep right.
# shellcheck source=lib/fetch-pg-credentials.sh
source "$SCRIPT_DIR/lib/fetch-pg-credentials.sh"

echo "=== Applying $SCHEMA_FILE to $PGDATABASE@$PGHOST ==="
psql -v ON_ERROR_STOP=1 -f "$SCHEMA_FILE"

echo ""
echo "=== Verifying ==="
python3 "$SCRIPT_DIR/lib/verify_schema.py" "$SCHEMA_FILE"
