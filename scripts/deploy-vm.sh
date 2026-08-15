#!/bin/bash
# VM-side deploy (ADR 0015 section 3): check for dirty local state (refuse,
# don't discard), pull, upgrade the first-party Odoo modules, restart Odoo,
# then a real smoke test - not just "the service started."
#
# The module upgrade is not decoration on the restart. A restart reloads
# Python code, but new or changed models, fields, views and ACLs only reach
# the database through an explicit `odoo -u <module>`. Without that step a
# deploy carrying model changes restarts "successfully" and then fails the
# smoke test - which is what this script would have done during ADR 0016 had
# the upgrade not already been run by hand during pre-commit testing, masking
# the gap and making a restart-only deploy look complete.
#
# Ordering - stop, upgrade, start - is forced by Odoo, not preference: with
# workers > 0 (this host runs 3) `odoo -u ... --stop-after-init` takes the
# prefork path, which binds the HTTP port *before* it loads the registry, so
# running it against a live service dies with "Address already in use". The
# deploy restarts Odoo anyway, so the upgrade takes that same window rather
# than racing three live workers holding the pre-upgrade registry.
#
# The two privileged Odoo calls go through /usr/local/sbin/luxauto-odoo-deploy-ctl
# (ADR 0020's addendum), a root-owned wrapper outside this repository that pins the
# config, database, module list and smoke-test payload. That is what let the
# `/usr/bin/odoo *` sudoers wildcard be replaced with two exact-match entries; this
# script can no longer choose any of those values, which is the point.
#
# Usage: scripts/deploy-vm.sh
# Env overrides: LUXAUTO_ADDONS_CLONE

set -euo pipefail

CLONE_DIR="${LUXAUTO_ADDONS_CLONE:-/opt/odoo-custom-addons/luxauto}"
# Not overridable, unlike CLONE_DIR: the point of the wrapper is that this path
# is fixed and root-owned. SCRIPT_DIR is gone with it - the only thing this script
# used its own directory for was the smoke-test payload, which the wrapper now
# resolves inside the clone.
DEPLOY_CTL=/usr/local/sbin/luxauto-odoo-deploy-ctl

# ODOO_CONF, ODOO_DB, ODOO_BIN and LUXAUTO_MODULES used to be honoured here and
# are now pinned inside the wrapper. Refusing beats ignoring: silently upgrading
# every module against the production database while the operator believes
# LUXAUTO_MODULES limited it is exactly the kind of quiet lie this script's
# dirty-state check exists to avoid. Change the wrapper, or call odoo directly as
# the odoo user.
for pinned in ODOO_CONF ODOO_DB ODOO_BIN LUXAUTO_MODULES; do
  if [[ -n "${!pinned:-}" ]]; then
    echo "REFUSING TO PROCEED: $pinned is set, but it no longer has any effect." >&2
    echo "" >&2
    echo "The module upgrade and smoke test now run through $DEPLOY_CTL," >&2
    echo "which hardcodes the clone path, config, database and payload so that the" >&2
    echo "CI runner's sudo grant cannot choose them (ADR 0020 addendum). Honouring" >&2
    echo "this variable here would report one thing and do another." >&2
    exit 1
  fi
done

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
echo "=== Collecting first-party modules to upgrade ==="
# Every first-party module, every deploy, rather than deriving the list from
# the commit's diff: a no-op upgrade of an unchanged module is cheap, and it
# means the script never has to be right about which files imply a model
# change. `-u` only touches modules already installed (odoo/modules/loading.py
# filters on state in installed/to upgrade), so a brand-new module directory
# is skipped here and still needs its own deliberate one-time `-i` install.
#
# This scan is now a PREFLIGHT, not the authoritative one: the wrapper repeats it
# and its answer is what actually reaches `odoo -u`. The duplication is deliberate
# and earns its keep by ordering - failing here happens BEFORE `systemctl stop
# odoo`, so a bad clone does not take the service down on its way to an upgrade
# that was never going to run. The wrapper echoes the list it actually used
# (LUXAUTO_DEPLOY_CTL=upgrade ... modules=...), so the two disagreeing would be
# visible in the log rather than silent.
MODULES=""
for manifest in "$CLONE_DIR"/odoo/addons/*/__manifest__.py; do
  [[ -e "$manifest" ]] || continue
  MODULES="${MODULES:+$MODULES,}$(basename "$(dirname "$manifest")")"
done
if [[ -z "$MODULES" ]]; then
  echo "No module with a __manifest__.py found under $CLONE_DIR/odoo/addons." >&2
  echo "That is not a state this repo is ever in - a wrong clone path or a" >&2
  echo "bad pull is likelier than a real answer. Refusing to continue." >&2
  exit 1
fi
echo "Modules: $MODULES"

echo ""
echo "=== Stopping Odoo for the upgrade ==="
sudo systemctl stop odoo

echo ""
echo "=== Upgrading modules ($MODULES) ==="
UPGRADE_LOG="$(mktemp -t deploy-vm-upgrade.XXXXXX)"
# The wrapper passes --logfile= so the upgrade reports here instead of
# disappearing into /var/log/odoo/odoo-server.log, and pins everything else.
if ! sudo -u odoo "$DEPLOY_CTL" upgrade 2>&1 | tee "$UPGRADE_LOG"; then
  echo "" >&2
  echo "MODULE UPGRADE FAILED ($MODULES) - stopping here." >&2
  echo "No restart-and-smoke-test was run: a smoke test after a failed" >&2
  echo "upgrade tells you nothing about this deploy either way." >&2
  echo "" >&2
  echo "Errors from the upgrade:" >&2
  grep -E "CRITICAL|ERROR" "$UPGRADE_LOG" | tail -n 20 >&2 || true
  echo "" >&2
  echo "Full upgrade log: $UPGRADE_LOG" >&2
  echo "Starting Odoo again so the host isn't left down - it will come up on" >&2
  echo "the pulled code WITHOUT the upgrade, which is not a deployed state." >&2
  sudo systemctl start odoo || true
  exit 1
fi
echo "Upgrade completed."

echo ""
echo "=== Starting Odoo ==="
sudo systemctl start odoo
sleep 3
if ! sudo systemctl is-active --quiet odoo; then
  echo "Odoo service failed to start after the upgrade." >&2
  exit 1
fi
echo "Service active."

echo ""
echo "=== Smoke test: XML-RPC as a disposable user against all luxauto.* models ==="
# The payload is the CLONE's scripts/lib/smoke_test.py, chosen by the wrapper -
# not this checkout's copy, which under CI lives in the runner's own workspace and
# is writable by the runner. Same file in practice (both are origin/main, and the
# pull above is what put it there); different trust story.
SMOKE_OUTPUT=$(sudo -u odoo "$DEPLOY_CTL" smoketest 2>&1) || true
# LUXAUTO_DEPLOY_CTL= is the wrapper announcing itself: it keeps the pinned path
# visible in the deploy log, so a reader can see it ran rather than infer it.
echo "$SMOKE_OUTPUT" | grep -E "^LUXAUTO_DEPLOY_CTL=|SMOKE_TEST_MODEL=|SMOKE_TEST_CHECK=" || true
RESULT_LINE=$(echo "$SMOKE_OUTPUT" | grep "^SMOKE_TEST_RESULT=" || echo "SMOKE_TEST_RESULT=FAIL_NO_OUTPUT")
echo "$RESULT_LINE"

if [[ "$RESULT_LINE" != "SMOKE_TEST_RESULT=PASS" ]]; then
  echo "" >&2
  echo "Smoke test failed - pull, upgrade and restart completed, but the app" >&2
  echo "is not verified working. Full smoke test output:" >&2
  echo "$SMOKE_OUTPUT" >&2
  exit 1
fi

rm -f "$UPGRADE_LOG"

echo ""
echo "=== Deploy verified: pull, module upgrade, restart, and smoke test all succeeded ==="
