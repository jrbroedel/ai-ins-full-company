#!/bin/bash
# Rebuild luxauto_demo from the canonical schema and load the frozen $71M canonical
# book into it as the demo dashboard's true data source (ADR 0046, "Option B").
#
# ORDER (STEP 1 rebuild, then STEP 2 hybrid load - see load_canonical_to_demo.py):
#   1. Force PGDATABASE=luxauto_demo and assert it (belt) + assert the LIVE
#      current_database() is luxauto_demo (braces) BEFORE anything destructive.
#      Production 'luxauto' is refused outright; this script NEVER drops/writes it.
#   2. DROP SCHEMA public CASCADE; CREATE SCHEMA public;  (guarded)
#   3. Re-apply the canonical schema via the project's normal apply-and-verify path.
#   4. Run the Python loader (reseed rating world from the artifact snapshot, sanity
#      check, hybrid load, frozen-verdict table, policy-period claims).
#
# Creds via the project's Key Vault path (fetch-pg-credentials.sh), same as every
# other admin script. Usage: scripts/load-canonical-to-demo.sh [--no-rebuild]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REBUILD=1
if [[ "${1:-}" == "--no-rebuild" ]]; then REBUILD=0; fi

# Force the target BEFORE sourcing creds, so fetch-pg-credentials.sh's PGDATABASE
# default (luxauto) can never take effect here.
export PGDATABASE=luxauto_demo

# shellcheck source=lib/fetch-pg-credentials.sh
source "$SCRIPT_DIR/lib/fetch-pg-credentials.sh"

# ---- non-negotiable target guard ------------------------------------------- #
if [[ "${PGDATABASE:-}" == "luxauto" ]]; then
  echo "REFUSING: PGDATABASE is 'luxauto' (production)." >&2; exit 2
fi
if [[ "${PGDATABASE:-}" != "luxauto_demo" ]]; then
  echo "REFUSING: PGDATABASE is '${PGDATABASE:-}', expected 'luxauto_demo'." >&2; exit 2
fi
LIVE_DB="$(psql -tAc 'SELECT current_database()')"
if [[ "$LIVE_DB" != "luxauto_demo" ]]; then
  echo "REFUSING: live current_database() is '$LIVE_DB', expected 'luxauto_demo'." >&2; exit 2
fi
echo "=== target confirmed: $PGDATABASE @ $PGHOST (live current_database=$LIVE_DB) ==="

if [[ "$REBUILD" == "1" ]]; then
  echo "=== STEP 1: rebuild schema (DROP SCHEMA public CASCADE; CREATE SCHEMA public) on $PGDATABASE ==="
  # Re-assert the live database inside the same psql invocation that drops, so the
  # destructive statement cannot run against anything but luxauto_demo.
  psql -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
  IF current_database() <> 'luxauto_demo' THEN
    RAISE EXCEPTION 'REFUSING: current_database() is % (expected luxauto_demo)', current_database();
  END IF;
END $$;
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO PUBLIC;
SQL

  echo "=== STEP 1: re-apply canonical schema (project apply-and-verify path) ==="
  "$SCRIPT_DIR/apply-and-verify-schema.sh"
else
  echo "=== --no-rebuild: skipping schema rebuild ==="
fi

echo "=== STEP 2: hybrid load ==="
python3 "$SCRIPT_DIR/lib/load_canonical_to_demo.py"

echo "=== DONE ==="
