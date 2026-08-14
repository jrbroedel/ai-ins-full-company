#!/bin/bash
# Shared Postgres connection setup for the scripts that talk to luxauto-pg as
# the admin role. SOURCE this, do not execute it - it exports into the caller's
# environment and deliberately has no side effect beyond that.
#
#   source "$SCRIPT_DIR/lib/fetch-pg-credentials.sh"
#
# Behaviour, unchanged from where this logic lived inline in
# apply-and-verify-schema.sh (ADR 0015/0009):
#   - If PGHOST, PGUSER and PGPASSWORD are ALL already set, they are used as-is
#     and Key Vault is never contacted. That is what makes local and manual
#     runs possible without a managed identity.
#   - Otherwise each missing value is fetched from Key Vault using this host's
#     managed identity via IMDS - the pattern ADR 0009 chose so that no
#     Postgres credential is ever stored in the repo, passed on a command line,
#     or left in an operator's shell history.
#   - No secret value is ever printed. The echo below names the vault, not the
#     secrets, and every fetch_secret result goes straight into a variable.
#
# NOT used by expire-policies.sh, and that is deliberate rather than an
# oversight: that script connects as the `odoo` role with the password read
# from odoo.conf, not as the admin role from Key Vault. Folding it in here
# would either widen its privileges to admin or force this file to grow a
# second credential source; both are worse than two small paths that each do
# one thing. Checked before extracting, not assumed.

KEY_VAULT="${LUXAUTO_KEY_VAULT:-luxauto-kv-90a311}"

fetch_secret() {
  local secret_name="$1"
  local token
  token=$(curl -s -H "Metadata:true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fvault.azure.net" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  curl -s -H "Authorization: Bearer $token" \
    "https://${KEY_VAULT}.vault.azure.net/secrets/${secret_name}?api-version=7.4" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])"
}

if [[ -z "${PGHOST:-}" || -z "${PGUSER:-}" || -z "${PGPASSWORD:-}" ]]; then
  echo "PGHOST/PGUSER/PGPASSWORD not set - fetching from Key Vault ($KEY_VAULT) via managed identity."
  export PGUSER="${PGUSER:-$(fetch_secret postgres-admin-username)}"
  export PGPASSWORD="${PGPASSWORD:-$(fetch_secret postgres-admin-password)}"
  export PGHOST="${PGHOST:-$(fetch_secret postgres-fqdn)}"
fi
export PGSSLMODE="${PGSSLMODE:-require}"
export PGDATABASE="${PGDATABASE:-luxauto}"
