# ADR 0009: Odoo 19.0 installed and running on luxauto-odoo

**Status:** Implemented
**Date:** 2026-08-10

## Decision

Installed Odoo 19.0 Community on a dedicated Azure VM (`luxauto-odoo`, provisioned per the VM-hosting side of ADR 0002), connected it to the already-running `luxauto-pg` Postgres server, and installed the OCA `fs_storage`/`fs_attachment` modules that ADR 0003 named as the Azure Blob integration path. This ADR records what was actually built and five deviations from the "just install the package" plan, each of which would silently break a from-scratch reproduction if skipped.

## What was built

| Component | Detail |
|---|---|
| VM | `luxauto-odoo`, Standard_B2s, **Ubuntu 24.04 LTS** (not 22.04 — see Deviation 1), 64GB Standard SSD, `eastus2`, in `luxauto-vnet-eus2`'s `luxauto-app-subnet` |
| Odoo | 19.0, installed from the official `nightly.odoo.com/19.0` apt repo |
| Database connection | Dedicated `odoo` Postgres role (not the admin account — see Deviation 3), connecting to `luxauto-pg.postgres.database.azure.com` over the private VNet |
| Application database | `luxauto`, with `base`, `server_environment`, `fs_storage`, `fs_attachment` installed |
| Secrets | Fetched at configuration time via the VM's **system-assigned managed identity** against Key Vault — no credential passed through the operator or committed anywhere |
| Reverse proxy | nginx on port 80, proxying to Odoo on `127.0.0.1:8069` (and `:8072` for longpolling/websocket) |
| Hardening | Database management UI blocked at the nginx layer (see Deviation 5) |

**Not done yet:** TLS (no domain name pointed at the VM's public IP yet), and the actual `fs.storage` record wiring `fs_storage` to the `documents` Blob container — the module is installed but no storage backend has been configured. Both are open items, tracked below.

## Deviation 1: Ubuntu 24.04, not 22.04

The VM was first created on Ubuntu 22.04 (the only alias this `az` CLI version's local cache had, since the sandbox building this couldn't refresh the alias doc over the network). Odoo's own packaged-installer docs are explicit: the 19.0 `.deb` "currently supports Ubuntu Noble (24.04LTS)" — no other distribution is named as supported. Rather than risk dependency mismatches on an unsupported base, the VM was deleted and recreated on `Canonical:ubuntu-24_04-lts:server:latest` before installing anything. Cost: one throwaway VM creation cycle. If reproducing this from scratch, start on 24.04 directly.

## Deviation 2: the Odoo `.deb` package installs a local PostgreSQL server as a side effect

`apt-get install odoo` pulled in `postgresql-16` and initialized a local cluster — unwanted, since the whole point of ADR 0001/0002 was an externally-managed Azure Postgres Flexible Server. This happens regardless of `odoo.conf` pointing elsewhere; it's a package dependency, not a runtime choice. Fixed by stopping and disabling (not removing — no strong reason to, and removing risks apt dependency resolution surprises) the local `postgresql` service immediately after install, before ever starting Odoo itself.

**Action item for the Bicep template or any install script:** stop/disable `postgresql.service` as a standard post-install step, not an afterthought.

## Deviation 3: PostgreSQL 15+ schema ownership breaks Odoo's default `CREATE TABLE`

The first attempt to initialize the `luxauto` database (`odoo -d luxauto -i base --stop-after-init`) failed with `permission denied for schema public`, even though the `odoo` Postgres role created the database (via `CREATEDB`) and therefore owns it. The reason: PostgreSQL 15 changed the default privileges on the `public` schema — it's no longer world-writable, and critically, **a new database's `public` schema is copied from `template1` and retains `template1`'s owner**, not the new database's owner. So `odoo` owned the *database* but not the *schema inside it*, and had no `CREATE` privilege there.

Fix, run once per database as the Postgres admin after creation:
```sql
ALTER SCHEMA public OWNER TO odoo;
GRANT ALL ON SCHEMA public TO odoo;
```
This is a genuinely easy thing to miss if following an Odoo self-hosting guide written before Postgres 15 (most are), since older Postgres defaults didn't have this restriction. Also worth knowing: this is also why a dedicated least-privilege `odoo` role (rather than pointing Odoo straight at the Flexible Server's admin account) doesn't cost anything in practice — the role still needs this one grant regardless of which account creates the database.

## Deviation 4: two undocumented OCA module dependencies

Installing `fs_storage`/`fs_attachment` failed twice before succeeding, on two separate missing dependencies neither the ADR 0003 evaluation nor the OCA `storage` repo's own README flagged:

1. **`fs_storage` depends on `server_environment`**, which lives in a *different* OCA repository (`OCA/server-env`), not in `OCA/storage`. Needed cloning both repos and adding both to `addons_path`.
2. **`fs_attachment` needs the Python package `python_slugify`** (`pip install python-slugify`), not installed by the Odoo `.deb` package or pulled in automatically as an OCA module dependency.

**Action item:** any future OCA module evaluation for this project should check the module's `__manifest__.py` `depends` and `external_dependencies` keys directly, rather than assuming the repo the module lives in is self-contained.

## Deviation 5: `list_db = False` does not block the database manager UI in Odoo 19

Standard hardening advice for internet-facing Odoo is to set `list_db = False` in `odoo.conf` to hide the database manager. Tested directly against this Odoo 19 install: with `list_db = False` set and the service restarted, `/web/database/manager` still returned the full database manager page (`Master Password` / `Create Database` form fields present in the response body) with an HTTP 200. This option appears to only affect the database *selector dropdown* on the login page in this version, not the manager route's reachability.

Since `luxauto-odoo`'s NSG deliberately keeps ports 80/443 open to the whole internet (it's a web app that needs to be reachable), an exposed database manager is a real risk — someone with the master password (a strong generated one, but still) could create, duplicate, or drop databases from the open internet. Fixed at the nginx layer instead, which doesn't depend on Odoo's internal option semantics:

```nginx
location ~ ^/web/database/(manager|selector|list|create|duplicate|drop|backup|restore|change_password) {
    deny all;
    return 403;
}
```
Verified: `/web/database/manager` returns 403, `/web/login` still returns 200.

**Action item:** don't trust `list_db = False` alone on any future Odoo deployment exposed to the internet — verify the manager route is actually blocked, the same way it was verified here (checking response *content*, not just status code — the unblocked version also returned 200, so status code alone doesn't tell you anything).

## Operational note: `run-command` output redirection is unreliable for long-running child processes

Several debugging attempts redirected the Odoo CLI's own output to a file (`... > /tmp/output.log 2>&1`) when invoking scripts via `az vm run-command invoke`. These files were consistently empty (0 bytes) even on runs independently confirmed to have succeeded (verified via direct database queries). Switching to reading Odoo's own persistent log file (`/var/log/odoo/odoo-server.log`, truncating it before each attempt to isolate that run's output) worked reliably every time. Worth knowing for any future `run-command`-driven debugging on this or similar VMs — don't trust an empty redirected-output file as evidence of failure; check the application's own log instead.

## Managed identity pattern for secret retrieval

`luxauto-odoo` has a system-assigned managed identity, granted the narrow `Key Vault Secrets User` role (read-only) scoped to `luxauto-kv-90a311` — deliberately narrower than the `Key Vault Secrets Officer` role used for initial setup from Cloud Shell. Configuration scripts fetch secrets via the standard IMDS token flow:
```bash
TOKEN=$(curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fvault.azure.net" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://luxauto-kv-90a311.vault.azure.net/secrets/<name>?api-version=7.4" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])"
```
No secret value ever passed through the operator or any chat/log channel during this process — the pattern established in ADR 0008 for jump-box work extends cleanly to standing compute.

## Consequences / not yet done

- **TLS is not configured.** Everything is plaintext HTTP on port 80. Needs a domain name pointed at `20.110.2.164` before certbot can issue a certificate. Until then, credentials (including the eventual first-login admin password) travel in the clear — acceptable for continued build-out, not for anything resembling production use.
- **`fs_storage` is installed but not wired to Blob Storage.** No `fs.storage` record exists yet pointing at `luxautosa91a2e1`/`documents`. This is the direct next step and is deliberately being done once, interactively, through the Odoo UI rather than scripted — worth a human confirming it actually works before trusting document attachments to it.
- **No application-specific Odoo modules exist yet** — the Policy/Insured/Premium objects and quota-share module (ADR 0007's scope) haven't been started. This VM currently runs stock Odoo plus the storage integration modules only.
- **Local Postgres on the VM is disabled but not removed.** No functional cost to leaving it uninstalled-but-present; flagged here only so a future audit doesn't wonder why `postgresql-16` packages are present but inactive.
