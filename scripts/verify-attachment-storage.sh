#!/bin/bash
# Standing attachment-storage health check (ADR 0009 Deviation 7, second
# addendum): confirms both that Odoo still INTENDS to store attachments in
# Azure Blob, and that Blob is actually REACHABLE - by writing a small marked
# object, reading it back through Odoo and again through fsspec directly, and
# deleting it. See scripts/lib/verify_attachment_storage.py for what each check
# proves and why they are independent.
#
# Why a VM-side timer, and why this is separate from the deploy-time check:
# smoke_test.py already asserts the intent half, but only on a push. The
# failure modes this catches - a rotated storage key, a deleted container, a
# changed network rule, a hand-edited config, a restored VM - do not coincide
# with deploys, so a deploy-time check can miss them indefinitely. The timer
# shape is the one ADR 0019 established for expire-policies: the schedule stays
# versioned in this repo instead of living only on the host.
#
# Runs as the `odoo` user, not root and not azureuser. That is the same
# privilege level scripts/expire-policies.sh uses and it is sufficient here for
# the same reason: everything this needs is reachable from the Odoo config the
# user already owns. Specifically it needs to read /etc/odoo/odoo.conf (0640
# odoo:odoo) and to run `odoo shell`; the Azure Blob credentials come from the
# fs_storage record in the luxauto database, NOT from Key Vault, so unlike
# apply-and-verify-schema.sh this needs no managed-identity round-trip and no
# admin Postgres role. Checked rather than assumed - see the ADR addendum.
#
# Exit codes are deliberately distinct so a reader of `systemctl status` can
# tell what broke without opening the log:
#   0  both checks passed
#   1  the INTENT check failed - Odoo is no longer routing to Blob
#   2  the REACHABILITY check failed - Blob rejected the round-trip
#   3  both failed
#   4  the check could not be run at all (no parseable result)
#
# Usage: scripts/verify-attachment-storage.sh
# Env overrides: ODOO_CONF, ODOO_DB, ODOO_BIN, LUXAUTO_EXPECTED_STORAGE

set -euo pipefail

ODOO_CONF="${ODOO_CONF:-/etc/odoo/odoo.conf}"
ODOO_DB="${ODOO_DB:-luxauto}"
ODOO_BIN="${ODOO_BIN:-/usr/bin/odoo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/lib/verify_attachment_storage.py"

if [[ ! -r "$ODOO_CONF" ]]; then
  echo "Cannot read $ODOO_CONF." >&2
  echo "This script is meant to run as a user that can read that file (the systemd unit runs as odoo)." >&2
  exit 4
fi

if [[ ! -f "$PAYLOAD" ]]; then
  echo "Payload not found: $PAYLOAD" >&2
  echo "Refusing to run - odoo shell would otherwise read this process's stdin and" >&2
  echo "report nothing at all, which is indistinguishable from a pass here." >&2
  exit 4
fi

echo "=== Verifying attachment storage (db=$ODOO_DB conf=$ODOO_CONF) ==="

# `odoo shell` exits 0 regardless of what the payload concluded, so the result
# line is the contract - the same approach deploy-vm.sh takes with the smoke
# test rather than trusting the exit status of the shell itself.
OUTPUT=$("$ODOO_BIN" shell --config "$ODOO_CONF" -d "$ODOO_DB" --no-http --logfile= \
         < "$PAYLOAD" 2>&1) || true

echo "$OUTPUT" | grep -E "^VERIFY_STORAGE=|^VERIFY_CHECK=|^VERIFY_CLEANUP=" || true

RESULT_LINE=$(echo "$OUTPUT" | grep "^VERIFY_RESULT=" || echo "VERIFY_RESULT=NO_OUTPUT")
echo "$RESULT_LINE"

if [[ "$RESULT_LINE" == "VERIFY_RESULT=PASS" ]]; then
  echo "=== Attachment storage verified: intent and reachability both OK ==="
  exit 0
fi

if [[ "$RESULT_LINE" == "VERIFY_RESULT=NO_OUTPUT" ]]; then
  echo "" >&2
  echo "The check produced no result line at all - it did not run to completion." >&2
  echo "Full output:" >&2
  echo "$OUTPUT" >&2
  exit 4
fi

INTENT_FAILED=0
REACH_FAILED=0
echo "$OUTPUT" | grep -q "^VERIFY_CHECK=intent RESULT=FAIL" && INTENT_FAILED=1
echo "$OUTPUT" | grep -q "^VERIFY_CHECK=reachability RESULT=FAIL" && REACH_FAILED=1

echo "" >&2
echo "ATTACHMENT STORAGE CHECK FAILED." >&2
echo "" >&2
echo "$OUTPUT" | grep -E "^VERIFY_CHECK=.*RESULT=FAIL|^VERIFY_CLEANUP=" >&2

if (( INTENT_FAILED && REACH_FAILED )); then
  exit 3
elif (( REACH_FAILED )); then
  exit 2
elif (( INTENT_FAILED )); then
  exit 1
fi

# A FAIL overall with neither check individually marked FAIL means the payload
# reported something this script does not understand - louder than exiting 0.
echo "Overall result was FAIL but neither check was marked FAIL - unexpected output." >&2
echo "$OUTPUT" >&2
exit 4
