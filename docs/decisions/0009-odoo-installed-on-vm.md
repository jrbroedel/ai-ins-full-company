# ADR 0009: Odoo 19.0 installed and running on luxauto-odoo

**Status:** Implemented
**Date:** 2026-08-10

## Decision

Installed Odoo 19.0 Community on a dedicated Azure VM (`luxauto-odoo`, provisioned per the VM-hosting side of ADR 0002), connected it to the already-running `luxauto-pg` Postgres server, and installed the OCA `fs_storage`/`fs_attachment` modules that ADR 0003 named as the Azure Blob integration path. This ADR records what was actually built and seven deviations from the "just install the package" plan, each of which would silently break a from-scratch reproduction if skipped. (Deviations 6 and 7 were appended later the same day, with the TLS and `fs_storage` work; this sentence said "five" until 2026-08-15.)

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

**Action item for the Bicep/install-script path:** build this `server_environment_files` package (with `running_env` set appropriately per deployment target) as a first-class part of provisioning, not a manual post-install fix — same category of note as Deviation 4's OCA dependency gap. ~~Outstanding.~~ **Closed 2026-08-15 — see the addendum below.** The package is now version-controlled at `odoo/addons/server_environment_files/`, so a `git clone` carries it and no post-install step is needed.

---

### Addendum to Deviation 7: the package is now in version control, and its silent failure is now loud (2026-08-15)

`docs/runbooks/vm-rebuild.md`'s Appendix C recorded that this package lived at `/opt/odoo-custom-addons/server-env/server_environment_files` — a directory this project created **inside a clone of a third-party repository** — and was untracked there, so a `git clean -fdx` or a re-clone of `server-env` would delete it with no visible symptom. That was accurate. It has been fixed, and investigating it first changed what the right fix was.

**Investigated before deciding, not assumed:**

- **Nothing in it is sensitive.** The package is three files: an empty `__init__.py`, `production/fs_storage.conf`, and a `__pycache__`. The `.conf` contains exactly one key — `use_as_default_for_attachments = true`. The Azure Blob credentials are **not** here: `account_name` and `account_key` live in the `luxauto` database, in `fs_storage.server_env_defaults` (verified by reading the JSON keys directly). Version-controlling this file therefore publishes no secret. This was the load-bearing question — the fix would have been different had it come out the other way.
- **It was not gitignored upstream; it was never meant to be there at all.** `git check-ignore -v` in the OCA clone exits non-zero (not ignored), and upstream `OCA/server-env` tracks nothing by that name. So the state was not "upstream deliberately excludes it" but "we put a first-party file in someone else's working tree." That makes the correct fix relocation, not `git add` in a clone we do not own.
- **The import is namespace-based, so relocation is possible at all.** `server_env.py` does `from odoo.addons import server_environment_files`, then takes `os.path.dirname(...)`. Because that resolves through the `odoo.addons` namespace, the package works from **any** `addons_path` entry — including this repo's own `odoo/addons/`. Deviation 7's original constraint (it cannot be its own top-level `addons_path` entry) still holds and is unchanged; it simply never required the OCA clone specifically.

**The failure taxonomy, established by reading `server_env.py` and then reproducing all three live** — this is the part that had never been written down:

| What goes missing | What Odoo does | Loud? |
|---|---|---|
| The whole `server_environment_files` package | `ImportError` caught, logged at **INFO**, `_dir = None`, config silently ignored | **No** |
| `production/fs_storage.conf` only | `_listconf()` returns a shorter list, field falls back to its Python default `False` — no log at all | **No** |
| The `production/` directory, package still present | `raise Exception("Provided server environment does not exist...")` at import — Odoo refuses to start | Yes |

Two of the three are silent, and the two silent ones are precisely the ones a `git clean` or a botched edit produces.

**One correction to how this was previously described, including in the runbook.** The silent fallback does *not* send attachments to the database. `fs_attachment`'s `_storage()` falls through to stock Odoo's `super()._storage()`, which reads the `ir_attachment.location` config parameter — **not set on this database** (verified: no such row in `ir_config_parameter`) — so the answer is `'file'`, the **local filestore on the VM's own disk** at `/var/lib/odoo/.local/share/Odoo/filestore/luxauto`. Reproduced live: with the package moved aside, `_storage()` returns `'file'`. That is worse than the database fallback everyone assumed, because the filestore is exactly the state a VM rebuild destroys — silently degrading to Blob-less storage would put new attachments on the one disk that is not backed up by anything.

**What was built:**

1. **The package moved into this repository** at `odoo/addons/server_environment_files/`, with a `README.md` stating plainly that credentials must not be added to it now that it is version-controlled and this repo is public, and naming the two correct channels if a future value genuinely needs to be secret (`SERVER_ENV_CONFIG`/`SERVER_ENV_CONFIG_SECRET` on the systemd unit, or the existing Key Vault path). It has no `__manifest__.py`, so `deploy-vm.sh` and the deploy wrapper's module scan skip it — checked, not assumed.
2. **The copy in the OCA clone was deleted.** Keeping both would have been worse than either: `addons_path` lists `server-env` before this repo's addons directory, so the OCA copy would win and the version-controlled one would sit there looking authoritative while doing nothing.
3. **`scripts/lib/smoke_test.py` now asserts attachment storage**, via `env['ir.attachment']._storage()` — the same resolver `_file_write()` actually calls, rather than re-reading the config file and hoping it means what it says. It emits `SMOKE_TEST_CHECK=attachment_storage RESULT=...` and forces `SMOKE_TEST_RESULT=FAIL`, which fails the deploy and therefore the push. `deploy-vm.sh`'s output filter was widened to surface `SMOKE_TEST_CHECK=` lines on success too, not only in the failure dump.

**Verified by reproducing the failure before trusting the fix**, the same discipline the test suites use — and note that `odoo shell` re-imports `server_environment` in a fresh process, which is both how the real smoke test runs and why none of this required restarting the production service:

| Check | Result |
|---|---|
| Check passes in the healthy state | `SMOKE_TEST_CHECK=attachment_storage RESULT=PASS` |
| Whole package removed | INFO log only; `_storage()` → `'file'`; check **FAILs**, `SMOKE_TEST_RESULT=FAIL` |
| `fs_storage.conf` removed | no log at all; `_storage()` → `'file'`; check **FAILs** |
| `production/` removed | `Exception: Provided server environment does not exist...` — refuses to start, as documented |
| Repo copy alone drives the config | with the OCA copy removed, `_dir` = `/opt/odoo-custom-addons/luxauto/odoo/addons/server_environment_files`, `use_as_default_for_attachments` still `True`, `_storage()` → `azure_blob_documents` |
| Restored state | check passes clean again |

**What this does not fix.** The check runs at deploy time, not continuously. Between deploys, something could delete the config and the only symptom would still be new attachments landing on local disk until the next push. A periodic check (the ADR 0019 timer is the obvious host for one) is a reasonable follow-up and is not done here. The check also does not verify that Blob is *reachable* — only that Odoo intends to use it; ADR 0009's original three-way `fsspec` verification remains the thing that proved reachability, and nothing re-runs it.

## Consequences / not yet done

- **No application-specific Odoo modules exist yet** — the Policy/Insured/Premium objects and quota-share module (ADR 0007's scope) haven't been started. This VM currently runs stock Odoo plus the storage integration modules only, now genuinely wired to Blob Storage (see above).
- **Local Postgres on the VM is disabled but not removed.** No functional cost to leaving it uninstalled-but-present; flagged here only so a future audit doesn't wonder why `postgresql-16` packages are present but inactive.
