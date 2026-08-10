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
| Reverse proxy | nginx, proxying to Odoo on `127.0.0.1:8069` (and `:8072` for longpolling/websocket) |
| TLS | `https://mga.ironcliffvertex.com`, Let's Encrypt via certbot, auto-renewing; HTTP redirects to HTTPS |
| Hardening | Database management UI blocked at the nginx layer (see Deviation 5) |

**Not done yet:** application-specific Odoo modules (Policy/Insured/Premium objects, quota-share) haven't been started — see the Consequences section below. TLS and the Blob Storage wiring, both originally listed here as open items, were completed 2026-08-10 — see the TLS section and the fs_storage section below.

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

## TLS (added 2026-08-10)

Domain: `mga.ironcliffvertex.com` — a subdomain of an existing, otherwise-unused domain (`ironcliffvertex.com`), chosen over registering a new dedicated domain since this instance isn't yet customer-facing. `mga` rather than something auto/underwriting-specific, since this Odoo instance is meant to grow beyond the first line of business (quota-share, commissions, eventually homeowners) and a narrower name would age poorly.

DNS is managed in Cloudflare. The record was added as **DNS only** (proxy disabled — grey cloud, not orange) deliberately: routing Let's Encrypt's HTTP-01 challenge through Cloudflare's proxy adds complexity for no benefit at this stage. Whether to enable Cloudflare's proxy (CDN/WAF/DDoS protection) is a separate decision that can be revisited once the certificate itself is working, without needing to redo anything here.

Certificate obtained via `certbot` with the `python3-certbot-nginx` plugin (Let's Encrypt, auto-renewing, ECDSA). One deviation from a clean run:

**Deviation 6: certbot's nginx plugin can't match a wildcard `server_name`.** The nginx config from Deviation 5 (the database-manager block) used `server_name _;` — a catch-all, since at the time there was no real hostname to bind to. `certbot --nginx -d mga.ironcliffvertex.com` obtained the certificate successfully but failed to auto-install it: *"Could not automatically find a matching server block for mga.ironcliffvertex.com. Set the `server_name` directive to use the Nginx installer."* Fixed by setting `server_name mga.ironcliffvertex.com;` explicitly, then running `certbot install --cert-name mga.ironcliffvertex.com --nginx` as a separate step. Certbot then correctly added the `listen 443 ssl` block and an HTTP→HTTPS redirect server block, and — worth explicitly checking, not assuming — the `/web/database/manager` block from Deviation 5 survived the rewrite unchanged.

**Action item for the Bicep/install-script path:** if provisioning this from scratch with a domain name already known upfront, set the real `server_name` in the nginx config from the start rather than `_;`, to skip this step entirely.

Verified post-install: HTTPS login page returns 200, HTTP redirects to HTTPS (301), `/web/database/manager` still returns 403 over HTTPS, `certbot.timer` is enabled and scheduled (twice-daily check, only renews when within Let's Encrypt's renewal window — current certificate expires 2026-11-08).

## fs_storage wired to Blob Storage (added 2026-08-10)

Created the `fs.storage` record (protocol `abfs` — `adlfs.AzureBlobFileSystem`, the correct fsspec protocol identifier for Azure Blob; confirmed by inspecting `fsspec`'s own `known_implementations` registry rather than assuming) pointing at the `documents` container, and set it as the default storage backend for all new attachments. Credentials fetched via the same managed-identity pattern as the rest of this ADR.

Verified in three independent ways before considering this done: a raw `fsspec` write/read/delete directly against the configured filesystem handle; a real `ir.attachment` created through Odoo's normal ORM API, checked for a populated `fs_filename` (proof it left the database) and correct content on read-back; and that same attachment's content re-read via `fsspec` directly, bypassing Odoo's abstraction entirely, confirming the bytes actually live in Azure Blob and not just somewhere Odoo believes they do.

**Deviation 7: `use_as_default_for_attachments` is a config-file-only field with no database column, and getting it to actually take a value required building a small config package from scratch.** The field is registered under `fs_storage`'s (`fs_attachment`-added) `_server_env_fields`, which is the OCA `server_environment` module's mechanism for keeping certain fields out of the database entirely and sourcing them from `.conf` files instead — by design, not a bug, so that environment-specific values (which storage is "the" default, credentials, etc.) don't need per-environment DB migrations and don't end up in backups/exports. Writing `True` via the ORM appeared to succeed (no error) but silently reverted to the field's Python-level default (`False`) on the next read, since there was no config file for it to read from — and the column genuinely doesn't exist in `fs_storage`'s Postgres table (confirmed directly: `column "use_as_default_for_attachments" does not exist`).

Getting this working required:
1. A plain Python package (not a full Odoo module — no `__manifest__.py` needed) named `server_environment_files`, placed *inside* an already-valid `addons_path` entry. It cannot be its own top-level `addons_path` entry: Odoo's path validator rejects any directory whose immediate children aren't themselves recognizable Odoo modules, and a bare config-file package doesn't qualify. (First attempt tried adding `/opt/odoo-custom-addons` itself to `addons_path` to expose the package — Odoo logged `invalid addons directory... skipped` and silently ignored the whole entry.)
2. `running_env = production` set explicitly in `odoo.conf` (an intentionally-unvalidated key — Odoo logs `unknown option 'running_env'... stored as-is`, which is expected and harmless; `server_environment` reads it directly off the parsed config dict, not through Odoo's own option schema).
3. A `.conf` file (not `.cfg` — confirmed by reading `server_env.py`'s `_listconf()` directly rather than guessing; it filters strictly on the `.conf` suffix) at `server_environment_files/production/fs_storage.conf`, containing:
   ```ini
   [fs_storage.azure_blob_documents]
   use_as_default_for_attachments = true
   ```
   The section name format itself required reading source rather than guessing: `<model _name with dots replaced by underscores>.<value of the field named in _server_env_section_name_field>`. `fs_storage` overrides that field to `"code"` rather than the mixin's default `"name"`, so the section is `fs_storage.azure_blob_documents` (matching the record's `code`), not `fs_storage.Azure Blob - documents`.

**Action item for the Bicep/install-script path:** build this `server_environment_files` package (with `running_env` set appropriately per deployment target) as a first-class part of provisioning, not a manual post-install fix — same category of note as Deviation 4's OCA dependency gap.

## Consequences / not yet done

- **No application-specific Odoo modules exist yet** — the Policy/Insured/Premium objects and quota-share module (ADR 0007's scope) haven't been started. This VM currently runs stock Odoo plus the storage integration modules only, now genuinely wired to Blob Storage (see above).
- **Local Postgres on the VM is disabled but not removed.** No functional cost to leaving it uninstalled-but-present; flagged here only so a future audit doesn't wonder why `postgresql-16` packages are present but inactive.
