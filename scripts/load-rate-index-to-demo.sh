#!/bin/bash
# STEP FOUR one-shot (ADR 0046): create + populate canonical_rate_index in luxauto_demo
# from the frozen artifact's monthly softening index, WITHOUT a rebuild - for applying to
# the already-loaded demo DB. The rate-trend line reads this table so the DB stays the
# single source (the softening index is a generation parameter, not an emergent DB fact).
#
# This is the ONLY DB write; it touches no existing table. Guarded exactly like the
# ADR 0046 loader: forces PGDATABASE=luxauto_demo, refuses production luxauto, and the
# Python re-asserts the live current_database() before writing.
#
# The same create+populate step is ALSO folded into load_canonical_to_demo.py (Phase F),
# so a future full rebuild recreates the table; this wrapper is the no-rebuild path.
#
# Usage: scripts/load-rate-index-to-demo.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Force the target BEFORE sourcing creds (the helper defaults PGDATABASE to luxauto).
export PGDATABASE=luxauto_demo

# shellcheck source=lib/fetch-pg-credentials.sh
source "$SCRIPT_DIR/lib/fetch-pg-credentials.sh"

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

python3 "$SCRIPT_DIR/lib/load_canonical_to_demo.py" --rate-index-only

echo "=== DONE ==="
