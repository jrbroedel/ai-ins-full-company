#!/bin/bash
# VM-side deploy (ADR 0015 section 3): check for dirty local state (refuse,
# don't discard), pull, restart Odoo, then a real smoke test - not just
# "the service started."
#
# Usage: scripts/deploy-vm.sh
# Env overrides: LUXAUTO_ADDONS_CLONE, ODOO_CONF, ODOO_DB

set -euo pipefail

CLONE_DIR="${LUXAUTO_ADDONS_CLONE:-/opt/odoo-custom-addons/luxauto}"
ODOO_CONF="${ODOO_CONF:-/etc/odoo/odoo.conf}"
ODOO_DB="${ODOO_DB:-luxauto}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Checking for dirty local state in $CLONE_DIR ==="
DIRTY=$(sudo -u odoo git -C "$CLONE_DIR" status --short)
if [[ -n "$DIRTY" ]]; then
  echo "REFUSING TO PROCEED: $CLONE_DIR has uncommitted local changes:" >&2
  echo "$DIRTY" >&2
  echo "" >&2
  echo "This script does not discard local state automatically - a script" >&2
  echo "can't tell known test-sync leftovers from someone's real work. Review" >&2
  echo "and resolve manually, then re-run." >&2
  exit 1
fi
echo "Clean - proceeding."

echo ""
echo "=== Pulling latest ==="
sudo -u odoo git -C "$CLONE_DIR" pull

echo ""
echo "=== Restarting Odoo ==="
sudo systemctl restart odoo
sleep 3
if ! sudo systemctl is-active --quiet odoo; then
  echo "Odoo service failed to start after restart." >&2
  exit 1
fi
echo "Service active."

echo ""
echo "=== Smoke test: XML-RPC as a disposable user against all luxauto.* models ==="
SMOKE_OUTPUT=$(sudo -u odoo /usr/bin/odoo shell --config "$ODOO_CONF" -d "$ODOO_DB" --no-http < "$SCRIPT_DIR/lib/smoke_test.py" 2>&1) || true
echo "$SMOKE_OUTPUT" | grep "SMOKE_TEST_MODEL=" || true
RESULT_LINE=$(echo "$SMOKE_OUTPUT" | grep "^SMOKE_TEST_RESULT=" || echo "SMOKE_TEST_RESULT=FAIL_NO_OUTPUT")
echo "$RESULT_LINE"

if [[ "$RESULT_LINE" != "SMOKE_TEST_RESULT=PASS" ]]; then
  echo "" >&2
  echo "Smoke test failed - pull and restart completed, but the app is not" >&2
  echo "verified working. Full smoke test output:" >&2
  echo "$SMOKE_OUTPUT" >&2
  exit 1
fi

echo ""
echo "=== Deploy verified: pull, restart, and smoke test all succeeded ==="
