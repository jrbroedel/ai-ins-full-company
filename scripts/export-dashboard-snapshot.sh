#!/bin/bash
# Wrapper for the read-only investor-dashboard snapshot exporter.
#
# Its whole job is credential + target setup, then hand off to the Python loop
# in scripts/lib/export_dashboard_snapshot.py. It reuses the established
# managed-identity -> IMDS -> Key Vault -> Postgres pattern by sourcing
# scripts/lib/fetch-pg-credentials.sh (the same helper apply-and-verify-schema.sh
# and run-tests.sh use), then pins the database to luxauto_demo EXPLICITLY so
# this can never point at production luxauto - the helper's own default is
# luxauto, so setting it here is deliberate, not incidental.
#
# The Blob account key comes from the SAME Key Vault, fetched inside the Python
# process (the VM's managed identity has no Blob data-plane RBAC on the account,
# so an account-key round-trip mirrors exactly what we do for Postgres). No
# secret is ever placed on a command line or written to the repo.
#
# SUPERVISION: in production this runs under a long-lived systemd *service*
# (Restart=always), NOT a timer - see infra/systemd/luxauto-dashboard-exporter.
# service. That unit is intentionally not installed yet; run this by hand first.
#
# Usage:
#   scripts/export-dashboard-snapshot.sh                 # continuous loop
#   SNAPSHOT_ONCE=1 SNAPSHOT_STDOUT=1 scripts/export-dashboard-snapshot.sh
#                                                        # one cycle, echo JSON
#
# Env overrides are passed straight through to the Python (SNAPSHOT_INTERVAL_
# SECONDS, DEMO_DASHBOARD_CONTAINER, SNAPSHOT_BLOB_KEY, LUXAUTO_KEY_VAULT, ...).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/lib/export_dashboard_snapshot.py"

# Pin the target BEFORE sourcing the helper. fetch-pg-credentials.sh honours an
# already-set PGDATABASE (it only defaults to luxauto when unset), so this is
# the explicit, auditable choice of the demo database over production.
export PGDATABASE="luxauto_demo"

# shellcheck source=lib/fetch-pg-credentials.sh
source "$SCRIPT_DIR/lib/fetch-pg-credentials.sh"

# Belt-and-braces guard, matching the one in the Python: refuse to proceed if
# anything downstream flipped the target back to production.
if [[ "${PGDATABASE:-}" != "luxauto_demo" ]]; then
  echo "REFUSING TO RUN: PGDATABASE is '${PGDATABASE:-}', expected 'luxauto_demo'." >&2
  exit 2
fi

echo "=== dashboard snapshot exporter: db=$PGDATABASE host=$PGHOST ==="
exec python3 "$PAYLOAD"
