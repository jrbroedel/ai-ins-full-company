#!/bin/bash
# Term-end status transitions (ADR 0019 section 3): calls expire_policies(),
# which moves every still-active policy whose term has ended to 'nonrenewed'
# (if a nonrenewal decision is in force) or 'expired' (if not).
#
# Why a VM-side timer instead of pg_cron: pg_cron is preloaded on luxauto-pg
# (it is in shared_preload_libraries) but not allow-listed - azure.extensions
# is UUID-OSSP,BTREE_GIST, and CREATE EXTENSION pg_cron is refused outright.
# Widening that list is an Azure control-plane parameter change plus a server
# restart, which is infrastructure work this ADR does not carry. A systemd
# timer on luxauto-odoo is the same VM-side operational pattern
# scripts/deploy-vm.sh already established, and it keeps the scheduling
# artifact versioned in this repo rather than living only in a database.
#
# Runs as the least-privilege `odoo` role, not the table owner: expire_policies
# is SECURITY DEFINER and granted to odoo, so the job needs no direct table
# privileges and no Key Vault round-trip. Credentials come from the Odoo
# config the systemd unit's user already owns.
#
# The function is idempotent - it only touches rows still 'active' - so a
# re-run, an overlapping run, or a catch-up run after downtime is safe.
#
# Usage: scripts/expire-policies.sh
# Env overrides: ODOO_CONF, PGHOST, PGDATABASE, LUXAUTO_AS_OF

set -euo pipefail

ODOO_CONF="${ODOO_CONF:-/etc/odoo/odoo.conf}"
export PGHOST="${PGHOST:-luxauto-pg.postgres.database.azure.com}"
export PGDATABASE="${PGDATABASE:-luxauto}"
export PGUSER="${PGUSER:-odoo}"
export PGSSLMODE="${PGSSLMODE:-require}"

if [[ -z "${PGPASSWORD:-}" ]]; then
  if [[ ! -r "$ODOO_CONF" ]]; then
    echo "Cannot read $ODOO_CONF for the odoo role's password, and PGPASSWORD is not set." >&2
    echo "This script is meant to run as a user that can read that file (the systemd unit runs as odoo)." >&2
    exit 1
  fi
  PGPASSWORD="$(sed -n 's/^db_password *= *//p' "$ODOO_CONF")"
  export PGPASSWORD
fi

# LUXAUTO_AS_OF exists for testing against a specific instant; unset means now().
AS_OF_SQL="now()"
if [[ -n "${LUXAUTO_AS_OF:-}" ]]; then
  AS_OF_SQL="'${LUXAUTO_AS_OF}'::timestamptz"
fi

echo "=== expire_policies() as of $AS_OF_SQL ==="
RESULT=$(psql -v ON_ERROR_STOP=1 -Atc "SELECT expired_count || ' expired, ' || nonrenewed_count || ' nonrenewed' FROM expire_policies($AS_OF_SQL);")
echo "$RESULT"
echo "=== done ==="
