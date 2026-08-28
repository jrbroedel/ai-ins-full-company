#!/bin/bash
# Wrapper for the deterministic canonical 12-month dataset generator (ADR 0043,
# Build 1: generate-and-freeze). Demo only.
#
# Like scripts/synthetic-generator.sh it reuses the managed-identity -> IMDS ->
# Key Vault -> Postgres pattern (scripts/lib/fetch-pg-credentials.sh) and pins
# PGDATABASE=luxauto_demo EXPLICITLY so it can never point at production luxauto.
#
# UNLIKE that job, this one is READ-ONLY: it only snapshots the rating tables and
# cross-checks the live rater, then writes a deterministic JSON artifact to disk.
# It performs NO writes to luxauto_demo (submit_application/create_quote belong to
# the separate replay build). The Python payload additionally sets the session
# read-only and re-checks current_database() after connecting.
#
# Usage:
#   scripts/generate-canonical-dataset.sh                       # full year -> sample-data/canonical
#   scripts/generate-canonical-dataset.sh --out-dir /tmp/small  # custom output dir
#   CANON_SUBMISSIONS=120 CANON_MONTHS=2 scripts/generate-canonical-dataset.sh --out-dir /tmp/small
#
# Env overrides pass straight through (CANON_SEED, CANON_SUBMISSIONS, CANON_MONTHS,
# CANON_START_YM, CANON_VALUE_SCALE, LUXAUTO_KEY_VAULT, ...).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/lib/canonical_generator.py"

# Pin the target BEFORE sourcing the helper (it only defaults to luxauto when
# PGDATABASE is unset), so this is the explicit, auditable choice of the demo DB.
export PGDATABASE="luxauto_demo"

# shellcheck source=lib/fetch-pg-credentials.sh
source "$SCRIPT_DIR/lib/fetch-pg-credentials.sh"

if [[ "${PGDATABASE:-}" == "luxauto" ]]; then
  echo "REFUSING TO RUN: PGDATABASE is 'luxauto' (production)." >&2
  exit 2
fi
if [[ "${PGDATABASE:-}" != "luxauto_demo" ]]; then
  echo "REFUSING TO RUN: PGDATABASE is '${PGDATABASE:-}', expected 'luxauto_demo'." >&2
  exit 2
fi

echo "=== canonical dataset generator (read-only): db=$PGDATABASE host=$PGHOST args=[$*] ==="
exec python3 "$PAYLOAD" "$@"
