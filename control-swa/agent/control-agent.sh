#!/bin/bash
# Wrapper for the VM control agent (demo only).
#
# Mirrors scripts/synthetic-generator.sh: its whole job is credential + target
# setup, then hand off to the Python payload. It sources the same managed-
# identity -> IMDS -> Key Vault helper and pins PGDATABASE=luxauto_demo
# EXPLICITLY so the agent (and the reprovision it can trigger) can never point at
# production luxauto - the helper's own default is luxauto, so setting it here is
# deliberate, not incidental.
#
# The agent ALSO talks to blob storage using the VM's managed identity
# (DefaultAzureCredential via IMDS); that needs Storage Blob Data Contributor on
# the demo-control container (operator checklist step).
#
# SUPERVISION: in production this runs under a long-lived systemd *service*
# (Restart=always) - see infra/systemd/luxauto-demo-control-agent.service. That
# unit is intentionally NOT installed yet; run this by hand first.
#
# Usage:
#   control-swa/agent/control-agent.sh            # run the agent loop
#   AGENT_INTERVAL_SECONDS=5 control-swa/agent/control-agent.sh

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$AGENT_DIR/../.." && pwd)"
PAYLOAD="$AGENT_DIR/control_agent.py"

# Pin the target BEFORE sourcing the helper (which only defaults to luxauto when
# PGDATABASE is unset). This is the explicit, auditable choice of the demo DB.
export PGDATABASE="luxauto_demo"

# shellcheck source=../../scripts/lib/fetch-pg-credentials.sh
source "$REPO_ROOT/scripts/lib/fetch-pg-credentials.sh"

# Belt-and-braces guard, matching the generator wrapper.
if [[ "${PGDATABASE:-}" == "luxauto" ]]; then
  echo "REFUSING TO RUN: PGDATABASE is 'luxauto' (production)." >&2
  exit 2
fi
if [[ "${PGDATABASE:-}" != "luxauto_demo" ]]; then
  echo "REFUSING TO RUN: PGDATABASE is '${PGDATABASE:-}', expected 'luxauto_demo'." >&2
  exit 2
fi

echo "=== demo control agent: db=$PGDATABASE host=${PGHOST:-?} container=${CONTROL_CONTAINER:-demo-control} ==="
exec python3 "$PAYLOAD"
