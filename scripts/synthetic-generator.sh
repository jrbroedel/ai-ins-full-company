#!/bin/bash
# Wrapper for the autonomous synthetic-application generator (demo only).
#
# Its whole job is credential + target setup, then hand off to the Python payload
# in scripts/lib/synthetic_generator.py. It reuses the established managed-
# identity -> IMDS -> Key Vault -> Postgres pattern by sourcing scripts/lib/
# fetch-pg-credentials.sh (the same helper the exporter and apply-and-verify-
# schema.sh use), then pins the database to luxauto_demo EXPLICITLY so this can
# never point at production luxauto - the helper's own default is luxauto, so
# setting it here is deliberate, not incidental.
#
# Unlike the read-only exporter, this job WRITES (it drives the real submit/quote
# path), so the target guard matters even more: both this wrapper and the Python
# refuse to run against anything but luxauto_demo, and refuse outright if the
# name is production luxauto.
#
# SUPERVISION: in production this would run under a long-lived systemd *service*
# (Restart=always) - see infra/systemd/luxauto-synthetic-generator.service. That
# unit is intentionally NOT installed yet; run this by hand first.
#
# Usage:
#   scripts/synthetic-generator.sh                 # continuous generation loop
#   GEN_MAX_APPS=5 scripts/synthetic-generator.sh  # generate 5 apps then exit
#   scripts/synthetic-generator.sh --reset --yes   # restore the curated book
#
# Env overrides pass straight through (GEN_INTERVAL_SECONDS, GEN_INTERVAL_JITTER,
# GEN_MAX_APPS, GEN_PERFORMED_BY, LUXAUTO_KEY_VAULT, ...).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/lib/synthetic_generator.py"

# Pin the target BEFORE sourcing the helper. fetch-pg-credentials.sh honours an
# already-set PGDATABASE (it only defaults to luxauto when unset), so this is the
# explicit, auditable choice of the demo database over production.
export PGDATABASE="luxauto_demo"

# shellcheck source=lib/fetch-pg-credentials.sh
source "$SCRIPT_DIR/lib/fetch-pg-credentials.sh"

# Belt-and-braces guard, matching the one in the Python: refuse to proceed if
# anything downstream flipped the target back to production.
if [[ "${PGDATABASE:-}" == "luxauto" ]]; then
  echo "REFUSING TO RUN: PGDATABASE is 'luxauto' (production)." >&2
  exit 2
fi
if [[ "${PGDATABASE:-}" != "luxauto_demo" ]]; then
  echo "REFUSING TO RUN: PGDATABASE is '${PGDATABASE:-}', expected 'luxauto_demo'." >&2
  exit 2
fi

echo "=== synthetic-application generator: db=$PGDATABASE host=$PGHOST args=[$*] ==="
exec python3 "$PAYLOAD" "$@"
