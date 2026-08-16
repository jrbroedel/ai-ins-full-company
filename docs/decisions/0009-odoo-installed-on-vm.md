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

### Addendum to Deviation 1: the build is not reproducible from upstream, and the vendored copy is the fix (2026-08-16)

The table above records "installed from the official `nightly.odoo.com/19.0` apt repo" as a fact and never examined it as a choice. `docs/runbooks/vm-rebuild.md` step 6 later called the consequence out — the running host has `19.0.20260809`, a dated nightly, from a rolling channel, so a rebuild installs whatever is current instead — and named it the largest un-reproducibility in the whole rebuild path. This addendum closes it, and investigating first changed what the fix had to be.

**There is no stable channel to switch to.** Not "not yet, because 19.0 is early" — `nightly.odoo.com` publishes only `<series>/nightly/` for **every** series it carries, 7.0 through 19.0 and master. `19.0/releases/` is a 404. The nightly channel is not a pre-release channel this project happened to pick; it is the only apt channel Odoo operates, and it is the one Odoo's own install documentation points at. Switching channels is not an available option, so the question was only how to make a specific build reproducible.

**`apt-get install odoo=19.0.20260809` cannot work, which is why the runbook's own suggested fix was wrong.** The repo's `Packages` index contains exactly **one** `odoo` entry — today, `19.0.20260816`. Verified directly against the fetched index, not inferred. A version-qualified install can only resolve versions the index lists, so this fails immediately on a rebuild with "Version '19.0.20260809' for 'odoo' was not found." The runbook offered this as an option with the caveat "if that build is still served"; the caveat was too generous, because the build being *present as a file* and being *installable by version* are different things and only the first is ever true here.

**`apt-mark hold` solves a different problem, and it turned out to be a real one anyway.** A hold prevents an installed package from moving on a live host; it has no effect on a fresh install, which is the rebuild scenario. But checking what it would actually guard against found something worth acting on independently:

- **unattended-upgrades already cannot touch Odoo.** The Odoo repo publishes no `Origin`, `Label` or `Suite` in its `Release` file, so it matches none of the four `Allowed-Origins` patterns. A `--dry-run --debug` shows it applying a `-32768` pin to that index and adjusting the candidate back to `odoo=19.0.20260809`. Automatic drift was never a live risk.
- **A human running `apt-get upgrade` was.** Simulated before changing anything: `apt-get -s upgrade` listed `Inst odoo [19.0.20260809] (19.0.20260816 nightly.odoo.com)`. Routine patching would have moved Odoo forward seven days onto an untested build, silently. `apt-mark hold odoo` was applied and re-simulated: `The following packages have been kept back: odoo`. That is a genuine fix for the live-drift problem and is **not** a fix for the rebuild problem — recorded as two separate things rather than one that reads like both.

**The retention policy is the finding that settled it.** The `.deb` for `19.0.20260809` *is* still on nightly.odoo.com today, so "just fetch it from upstream at rebuild time" looks workable. Enumerating the directory shows it is not, in a way with a predictable expiry:

| | 19.0 | 18.0 |
|---|---|---|
| builds with `.dsc`/`.changes` metadata retained | 312 | 687 |
| builds with the `.deb` artifact retained | ~110 | 131 |

The surviving `.deb`s follow the same shape in both series, which is what makes this a policy rather than a coincidence: **every day for roughly the last 3–4 months, then one build per month kept indefinitely.** 18.0's older survivors are `20241001`, `20241101`, `20241201`, `20250101`… — month boundaries only. `19.0.20260809` is **not** a month-boundary build, so on this pattern it is pruned once it falls out of the daily window, somewhere around **late November to mid-December 2026**. Odoo publishes no retention policy that I could find, so this is inferred from two independent directory listings rather than read from documentation — stated as inference, with the evidence, rather than as fact.

That is the whole argument against pinning by URL: it is a fix with a silent expiry date, which is worse than no fix, because it would look correct in the runbook right up until the first rebuild that needed it.

**Decision: vendor the artifact.** The exact `.deb` was already sitting in the VM's own apt cache at `/var/cache/apt/archives/odoo_19.0.20260809_all.deb` (221 MB) — an immediately available copy independent of upstream retention entirely. It was cross-checked against a fresh download from nightly.odoo.com and the two are **byte-identical** (`sha256 ff0299…3be5`), so the vendored copy is provably what Odoo published and not something locally mutated. `dpkg -V odoo` reports no discrepancies apart from `/etc/odoo/odoo.conf`, which is a conffile this project deliberately edits — so the running install also matches the package.

**Stored in a new `infra-artifacts` container in the existing `luxautosa91a2e1` storage account, not in `documents`.** The storage account is the one ADR 0008 provisioned and ADR 0009 already uses, so this introduces no new storage mechanism. A separate container rather than a path inside `documents` because `documents` is bound to the `fs.storage` record as Odoo's attachment backend: Odoo enumerates it, writes into it, and the attachment health check lists it. **Checked rather than assumed: the `fs_attachment` garbage collector works from an explicit `fs.file.gc` table of marked filenames and would not delete a foreign object**, so this is a separation-of-lifecycle decision — infrastructure artifact versus application data — not a data-loss risk. `documents` was confirmed untouched afterwards.

Alongside the `.deb` is `odoo_19.0.20260809_all.deb.manifest.json` recording the version, sha256, size, upstream URL, vendoring date and why it exists, so the artifact explains itself to whoever finds it without this ADR in hand.

**Verified by retrieval, not by upload succeeding:** the blob was downloaded back and re-hashed — 230,750,058 bytes, `sha256 ff0299…3be5`, matching both the local cache and upstream, and matching the manifest's own recorded hash.

**Nothing about the live install changed except the hold**, but it was re-tested anyway on the principle that a version-adjacent change is exactly where a silent break would hide: Odoo restarted cleanly, `deploy-vm.sh` ran the module upgrade and all seven models passed, the attachment-storage smoke check passed, and the standalone `luxauto-verify-attachment-storage.service` returned `Result=success` with both its intent and fsspec-reachability checks passing — so ADR 0009's Blob assumptions still hold.

**What this does not solve, stated plainly:**

- **The vendored copy is one blob in one storage account in one region.** It is not replicated, versioned or backed up; the account is Standard_LRS (ADR 0008). If the resource group is lost, the artifact is lost along with the VM and the database — this protects against upstream pruning and against VM loss, not against subscription-level loss.
- **It is a floor, not a pin.** Nothing forces a rebuild to *use* it. The runbook now installs from the vendored `.deb` by default, but an operator following habit rather than the document still gets whatever nightly is current.
- **Only this one build is vendored.** Every future deliberate Odoo upgrade needs its artifact vendored too, or this gap silently reopens one upgrade later. That step is now in the runbook; nothing enforces it.
- **The apt source is unchanged**, deliberately. The repo stays configured so that dependency resolution and any future intentional upgrade still work normally; the hold is what makes the difference between "available" and "applied."

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

**What this does not fix.** The check runs at deploy time, not continuously. Between deploys, something could delete the config and the only symptom would still be new attachments landing on local disk until the next push. A periodic check (the ADR 0019 timer is the obvious host for one) is a reasonable follow-up and is not done here. The check also does not verify that Blob is *reachable* — only that Odoo intends to use it; ADR 0009's original three-way `fsspec` verification remains the thing that proved reachability, and nothing re-runs it. **Both of these are closed by the second addendum below.**

---

### Second addendum to Deviation 7: a standing check that proves reachability, not just intent (2026-08-15)

The addendum above named two gaps and left them open: the check ran **only on deploy**, and it proved only **intent** (`ir.attachment._storage()` resolving to `azure_blob_documents`), never that Blob would accept a write. Both are now closed, by a timer rather than by extending the deploy path.

**Why a timer and not a bigger deploy check.** The failure modes that matter here do not coincide with deploys. A rotated storage-account key, a deleted or renamed container, a changed network rule on the storage account, a hand-edited config, a restored VM — none of these involve a push, so a deploy-time check can miss them for as long as nobody happens to deploy. `smoke_test.py` keeps the intent assertion because it is nearly free there and it fails a bad deploy at the moment it is made; the standing check is what covers the rest of the time.

**What was built:**

- `scripts/verify-attachment-storage.sh`, following `scripts/expire-policies.sh`'s shape — same header-comment discipline, same `set -euo pipefail`, same env-override convention, same "run as `odoo`, read the password from the config file that user already owns, no Key Vault round-trip" privilege model. Verified rather than assumed to be the right privilege level: the Blob credentials come from the `fs_storage` record in the `luxauto` database, not from Key Vault, so this check needs neither the managed identity nor the admin Postgres role. It needs only to read `/etc/odoo/odoo.conf` (0640 `odoo:odoo`) and to run `odoo shell`.
- `scripts/lib/verify_attachment_storage.py`, run through `odoo shell` — the same execution pattern as `smoke_test.py`, for consistency.
- `infra/systemd/luxauto-verify-attachment-storage.{service,timer}`, matching the ADR 0019 pair's structure, installed by the procedure in `infra/systemd/README.md`.

**The two checks are independent and both always run**, because "intent is wrong" and "Blob is unreachable" have different causes and different fixes, and a report that hides one behind the other is worse than two lines. The reachability probe forces the attachment onto the expected storage via `storage_location` in the context, so it tests Blob even when intent has already failed and a default-routed attachment would have gone to local disk. Exit codes are distinct — `1` intent, `2` reachability, `3` both, `4` could not run — so `systemctl status` is legible without opening the journal.

The reachability check reproduces ADR 0009's original three-way verification rather than re-reading config: create a real `ir.attachment` through the ORM and confirm `fs_filename` is populated and `db_datas` empty (the bytes left the database); read it back through the ORM; read the same object again through `fsspec` directly at the path parsed from `store_fname`, bypassing Odoo entirely; then delete it and confirm it is gone.

**Daily, and the reasoning is not the one ADR 0019 used.** ADR 0019 chose hourly because policy status is time-dependent — a policy whose term ended is *wrong* from that instant, and every hour of delay is an hour of visibly wrong data. Nothing about attachment storage degrades on its own; it regresses only when something acts on the system, and those events arrive days or weeks apart. The decisive argument is the alerting gap below: since a failure is recorded in the journal and nowhere else, the time to *notice* is set by when a human next looks, not by how often the check runs. Hourly would multiply the cost — each run writes, reads twice and deletes a real object in the production container — by 24 and improve time-to-notice by nothing. Daily bounds the undetected window at ~24h, against a previous bound of "until somebody pushes." `Persistent=true` so a VM that was down or deallocated catches up on the next boot, which matters more here than for policy expiry because a restored VM is one of the scenarios this check exists to catch.

**What the first run found, which is why this was tested rather than trusted.** The check failed on its first run against a perfectly healthy system, asserting that the probe object was still in the container after `unlink()`. That was the check being wrong, not the system — and it had already left an object in the production container, which was removed by hand. **Odoo does not delete Blob objects synchronously.** `ir.attachment.unlink()` → `_file_delete` → `fs_attachment._storage_file_delete` → `_fs_mark_for_gc`: it *marks* the object for a later garbage-collection pass and returns. So any probe that relies on `unlink()` to tidy up leaves its object in the container until the GC happens to run. The check now deletes through `fsspec` explicitly, which is both the honest cleanup and a stronger assertion — it exercises a real Blob *delete*, so the round-trip covers write, read and delete rather than only the first two. Cleanup is three-layered: the explicit delete on the success path, a `finally` that removes the object if any assertion returned early (reporting on `VERIFY_CLEANUP=` if that fails), and a transaction that is rolled back rather than committed so the `ir.attachment` row never lands even on a hard kill. Probe objects are named `luxauto-storage-healthcheck-<timestamp>-<token>.bin` so anything ever stranded is identifiable at a glance.

**Verified by reproducing every failure mode before trusting the fix.** The reproductions use `SERVER_ENV_CONFIG`, which `server_env.py` loads *last* and which therefore overrides the config files for one process only — so no live config, no file, and no database row was modified to produce any of these:

| Scenario | Result |
|---|---|
| Healthy system | `intent=PASS reachability=PASS`, exit **0**; container and database confirmed clean afterwards |
| Container missing (`directory_path` → nonexistent) | `reachability=FAIL: ResourceNotFoundError: The specified container does not exist`, intent still PASS, exit **2** |
| Blob no longer the default (`use_as_default_for_attachments=false`) | `intent=FAIL` naming `'file'` and the config file to check, reachability still PASS, exit **1** |
| Rotated/invalid storage key **and** not default | `intent=FAIL` and `reachability=FAIL: ClientAuthenticationError: Server failed to authenticate the request`, exit **3** |
| After every failure run | no probe object in the container, no `ir_attachment` row — checked explicitly, not assumed |
| Timer actually fires | see below — proven by observation, not by `is-enabled` |

The intent-failure reproduction was re-run against this standalone check rather than assumed to transfer from `smoke_test.py`'s earlier reproduction; it produces the same `'file'` fallback and the same diagnosis, through a different code path.

## What this still does NOT solve — nobody is notified

**There is no alerting on this project, and this addendum does not add any.** Checked before deciding, not assumed: there is no outgoing mail server configured in Odoo (`ir_mail_server` is empty), no webhook, no Slack integration, no `OnFailure=` handler on any unit, and nothing resembling alerting anywhere in the repository.

So the honest description of what a failure does today: **`luxauto-verify-attachment-storage.service` exits non-zero, systemd records the failure, and the message sits in the journal on `luxauto-odoo` until a human runs `systemctl status` or `journalctl -u luxauto-verify-attachment-storage.service`. No one is told.** A regression is detected within ~24 hours and *surfaced* only when somebody looks — which, on a project with no on-call and no dashboard, could be much longer.

That is a real reduction in exposure and it is not the same as monitoring. This addendum deliberately does not build alerting: choosing a channel (email via an SMTP relay, an Azure Monitor action group, a webhook) is a larger decision with its own credential-handling and cost consequences, and it belongs in its own ADR rather than being smuggled in behind a health check. **The obvious next step, named and not taken here:** a `OnFailure=` unit pointing at whatever notification transport that future ADR picks — the systemd shape for it is already in place and costs one line per unit once there is somewhere to send to.

Two smaller residuals, stated rather than left to be discovered:

- **The check proves the container is writable, not that existing attachments are intact.** It writes and reads its own probe object; it does not audit the 0 attachments currently routed to Blob (all 206 are `image/*`, `text/css` or `application/javascript`, which `force_db_for_default_attachment_rules` deliberately keeps in the database). A silent corruption of stored objects would not be caught.
- **A ~24h window remains** between a regression and its detection, plus however long until someone reads the journal. Shortening the first half is a one-word change to the timer; shortening the second half requires the alerting decision above.

## Consequences / not yet done

- **No application-specific Odoo modules exist yet** — the Policy/Insured/Premium objects and quota-share module (ADR 0007's scope) haven't been started. This VM currently runs stock Odoo plus the storage integration modules only, now genuinely wired to Blob Storage (see above).
- **Local Postgres on the VM is disabled but not removed.** No functional cost to leaving it uninstalled-but-present; flagged here only so a future audit doesn't wonder why `postgresql-16` packages are present but inactive.
