#!/bin/bash
# Automatic renewal generation (ADR 0033): calls generate_renewal_offers(),
# which finds every active policy whose term ends within 30 days (excluding any
# with an active nonrenewal decision or an existing successor) and generates a
# full renewal for each - a fresh copied application, re-referral, re-rating, and
# a contiguous-inception bound successor policy.
#
# Same VM-side operational pattern as expire-policies.sh (pg_cron is blocked on
# luxauto-pg - see that script and ADR 0019 for why), and the scheduling artifact
# stays versioned in this repo. Runs DAILY, not hourly: the 30-day window gives
# ~29 days of runway once a policy enters it, so a day of detection latency is
# immaterial - unlike expire_policies, which acts at the immediate term end.
#
# Runs as the least-privilege `odoo` role: generate_renewal_offers is SECURITY
# DEFINER and granted to odoo, so the job needs no direct table privileges and no
# Key Vault round-trip. Credentials come from the Odoo config the unit user owns.
#
# NOTE (ADR 0033, A1): the renewal copies the predecessor's risk data verbatim
# and nothing here refreshes it, so the re-referral that runs is mechanically real
# but practically inert - it will not catch risk that worsened since the prior
# bind. See ADR 0033's "A1 consequence" section.
#
# Usage: scripts/generate-renewal-offers.sh
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

echo "=== generate_renewal_offers() as of $AS_OF_SQL ==="
RESULT=$(psql -v ON_ERROR_STOP=1 -Atc "SELECT renewed_count || ' renewed, ' || skipped_count || ' skipped' FROM generate_renewal_offers($AS_OF_SQL);")
echo "$RESULT"
echo "=== done ==="
