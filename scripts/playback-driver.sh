#!/bin/bash
# Wrapper for the read-only-except-cursor playback driver (ADR 0047). It reveals the
# frozen $71M canonical book over demo-time by advancing ONE cursor row
# (demo_playback_state); it NEVER inserts into the book. Retires the synthetic
# generator's fabrication + DROP-reprovision write path.
#
# Credential + target setup only, then hands off to the Python. Reuses the
# managed-identity -> IMDS -> Key Vault path every admin job here uses
# (scripts/lib/fetch-pg-credentials.sh), and pins PGDATABASE=luxauto_demo EXPLICITLY
# so this can never point at production luxauto (the helper's own default is luxauto,
# so setting it here is deliberate). The Python re-guards env + live current_database().
#
# Usage:
#   scripts/playback-driver.sh            # the playback loop
#   scripts/playback-driver.sh --rewind   # rewind the cursor to the start (one-shot)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pin the target BEFORE sourcing the helper (its default is luxauto).
export PGDATABASE="luxauto_demo"

# shellcheck source=lib/fetch-pg-credentials.sh
source "$SCRIPT_DIR/lib/fetch-pg-credentials.sh"

exec python3 "$SCRIPT_DIR/lib/playback_driver.py" "$@"
