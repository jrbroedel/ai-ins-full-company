# Runbook: rebuilding `luxauto-odoo` from scratch

**Type:** operational runbook, not an ADR. It records how to reproduce a host, not a decision.
**Written:** 2026-08-15, from a live enumeration of the running `luxauto-odoo`, not from the ADRs.
**Covers:** total loss or deliberate replacement of the `luxauto-odoo` VM.
**Does NOT cover:** `luxauto-pg`, the Key Vault, the storage account, or the VNet. See [Scope](#scope-what-a-vm-rebuild-does-and-does-not-touch).

> **This runbook has never been executed.** No rebuild, and no parallel test VM, has ever
> been stood up from it. Every step below is reconstructed from the live host and the ADRs,
> and several steps are reconstructions of actions no script has ever performed. Read
> [Confidence: what is tested and what is not](#confidence-what-is-tested-and-what-is-not)
> before relying on any of it. Standing up a throwaway VM and running this end to end is the
> natural and still-outstanding follow-up.

---

## Scope: what a VM rebuild does and does not touch

`luxauto-odoo` is one resource in `luxauto-rg`. Most of this system is not on it.

**Destroyed by a VM rebuild** (everything in this runbook exists to restore these):

- The OS and every package, including Odoo itself
- `/etc/odoo/odoo.conf`, `/etc/nginx/sites-available/odoo`, `/etc/sudoers.d/10-ghrunner-deploy`
- `/usr/local/sbin/luxauto-odoo-deploy-ctl`
- The three addons clones under `/opt/odoo-custom-addons/`
- The GitHub Actions runner at `/opt/actions-runner/` and its registration
- The Let's Encrypt certificate and account at `/etc/letsencrypt/`
- The Odoo filestore at `/var/lib/odoo/.local/share/Odoo/filestore/luxauto` — see step 14
- The VM's system-assigned managed identity (a **new** principal id is issued; the old
  Key Vault role assignment becomes an orphan pointing at a deleted principal)

**NOT touched by a VM rebuild** — these are separate Azure resources and survive:

| Resource | Name | Why it matters here |
|---|---|---|
| Postgres Flexible Server | `luxauto-pg` | **All application data lives here, including the entire `luxauto` database.** A VM rebuild loses no application data. |
| Key Vault | `luxauto-kv-90a311` | Five secrets, listed in step 3 |
| Storage Account + container | `luxautosa91a2e1` / `documents` | Blob-backed attachments |
| VNet / subnets / private DNS zone | `luxauto-vnet-eus2` | The path the rebuilt VM uses to reach Postgres |

**Stated explicitly because it is the single most important fact in this document:**
`luxauto-pg` is a separate managed resource. Deleting and recreating the VM does not touch
it, does not drop the `luxauto` database, and does not lose a row. What a rebuild breaks is
the rebuilt VM's *access* to it — a new managed identity, a new Postgres client, and DNS
resolution through the private zone. Steps 3, 5 and 15 are what re-establish that access.
Do **not** re-run `apply-and-verify-schema.sh` expecting it to "restore" anything; it is
idempotent against a database that already has everything (step 15).

---

## Source-of-truth categories

Every step below is tagged with where the information needed to reproduce it actually lives.

| Tag | Meaning |
|---|---|
| **[VC]** | Version-controlled. In this repo. `git clone` gets it. |
| **[AZ]** | Azure-native. Recoverable with `az` CLI against the existing subscription — the resource still exists and can be inspected. |
| **[HOST]** | Host state / tribal knowledge. Exists **only** on the running VM. If the VM is gone and this runbook is wrong, the information is gone. These are the steps that justify the document. |
| **[EXT]** | External to Azure and to this repo (GitHub, Cloudflare, Let's Encrypt). |

Counting them, because the ratio is the point: of the 17 steps below, **5 are [VC]**,
**5 are [AZ]**, **5 are [HOST]**, and **2 are [EXT]**.

*(Two steps have changed category, which is the shape of progress this document is meant to
drive. Step 13 moved [HOST] → [VC] on 2026-08-15 (ADR 0009's Deviation 7 addendum). Step 6's
Odoo install moved [HOST] → [AZ] on 2026-08-16 when the exact `.deb` was vendored to Blob
(ADR 0009's Deviation 1 addendum); the rest of that step — the package list, the post-install
fixes — is still [HOST], so it carries both tags.)*

---

## Prerequisites for the operator

- `az` CLI, authenticated as a principal with Contributor on `luxauto-rg` and rights to
  create role assignments (`User Access Administrator` or `Owner`) — step 3 needs the latter,
  and Contributor alone is not enough.
  **Note: `az` is NOT installed on `luxauto-odoo` itself** (verified — `which az` finds
  nothing). Every `az` command in this runbook runs from an operator workstation or Cloud
  Shell, never from the VM.
- Subscription `ff1d4234-2dc1-476c-b350-ddabbc59c566`, tenant `2c7981fb-d0ee-46b6-a5c2-87aaa0a84d0b`,
  resource group `luxauto-rg`, region `eastus2`.
- Admin access to the `jrbroedel/ai-ins-full-company` GitHub repository (step 12 needs
  runner-registration rights; step 16 needs the Actions fork-PR setting).
- Access to the Cloudflare zone for `ironcliffvertex.com` (step 10, only if the public IP changes).

---

## Step 0 — Decide whether you actually need a full rebuild **[AZ]**

Three failure modes are often mistaken for each other. Only the third needs this document.

- **In-guest reboot.** Everything comes back unaided, including the runner. This is
  *tested* — ADR 0020 section 5 rebooted the host and observed the runner reconnect in
  seven seconds with `NRestarts=0`. Nothing in this runbook applies.
- **Azure deallocate/start.** Untested (ADR 0020 section 5 says so explicitly). The systemd
  units are identical either way, so it is *expected* to behave like a reboot. The one thing
  that plausibly changes is the public IP, if it is dynamic — check step 10 if the site is
  unreachable by name afterwards. Nothing else in this runbook should be needed.
- **VM lost, corrupted, or deliberately replaced.** This runbook.

---

## Step 1 — Capture what you can before destroying anything **[HOST]**

**Only possible on a planned rebuild.** On an unplanned loss, skip to step 2 and accept that
steps 6, 9, 11 and 14 are reconstructions.

If the old VM is still reachable, take these off it first. They are the items no other source
can supply:

```bash
sudo tar czf ~/luxauto-host-state.tgz \
  /etc/odoo/odoo.conf \
  /etc/nginx/sites-available/odoo \
  /etc/sudoers.d/10-ghrunner-deploy \
  /usr/local/sbin/luxauto-odoo-deploy-ctl \
  /etc/letsencrypt \
  /var/lib/odoo/.local/share/Odoo/filestore
```

`server_environment_files` used to be on this list and no longer is — it is version-controlled
as of 2026-08-15 (step 13).

The running Odoo `.deb` is also worth grabbing if it is still in the apt cache, as a second
copy independent of the vendored one in Blob — this is exactly where the vendored artifact
came from:

```bash
sudo cp /var/cache/apt/archives/odoo_*.deb ~/    # 221MB for 19.0.20260809
```

That tarball contains the `odoo` Postgres role password and the Odoo master password (both in
`odoo.conf`) and the TLS private key. Treat it as a secret: move it off the host over `scp`,
do not commit it, and delete it when the rebuild is verified.

---

## Step 2 — Create the VM **[AZ]** / **[HOST]**

**There is no Infrastructure-as-Code for this VM. Stated plainly because the repo's
`infra/bicep/` directory invites the opposite assumption.**

`infra/bicep/main.bicep` exists and is real, but it deploys **only** the ADR 0008 layer:
VNet, the Postgres-delegated subnet, the private DNS zone, the Postgres server, the storage
account, and the Key Vault. Read its own closing comment — it says so. It does **not**
contain the VM, its NIC, its public IP, its NSG, its managed identity, the Key Vault role
assignment, or the `luxauto-app-subnet` the VM actually sits in. None of the VM layer has
ever been expressed as IaC in any form — no Bicep, no Terraform, no ARM template, anywhere
in this repo.

**Two traps in that template, both verified rather than assumed:**

1. **It does not describe the subnet this VM lives in.** The template defines exactly one
   subnet, `luxauto-pg-subnet` at `10.20.1.0/24`. The running VM's NIC is at **`10.20.3.4/24`**
   — subnet `10.20.3.0/24`, which ADR 0009 names `luxauto-app-subnet` and which appears in no
   template. Recover its real definition with `az`, not from the repo.
2. **Its generated names do not match the deployed ones.** The template derives
   `luxauto-kv-${uniqueString(resourceGroup().id)}` and `luxautosa${uniqueString(...)}` — one
   deterministic value, so both suffixes would be identical. The real resources are
   `luxauto-kv-**90a311**` and `luxautosa**91a2e1**`: different suffixes, so at least one
   cannot have come from that formula. The names were generated by hand before the template
   was written to describe them. **Deploying this template into `luxauto-rg` would create a
   second, parallel set of resources rather than adopting the existing ones.** Do not run it
   as part of a VM rebuild. It is a reference for a greenfield rebuild of the *data* layer,
   which a VM rebuild is not.

Recover the real VM shape from the live subscription instead:

```bash
# The old VM's definition, while it still exists
az vm show -g luxauto-rg -n luxauto-odoo -o json > luxauto-odoo-vm.json
az network nic show --ids $(az vm show -g luxauto-rg -n luxauto-odoo \
  --query 'networkProfile.networkInterfaces[0].id' -o tsv) -o json > luxauto-odoo-nic.json
az network vnet subnet list -g luxauto-rg --vnet-name luxauto-vnet-eus2 -o table
az network nsg list -g luxauto-rg -o table
```

Observed values to reproduce (from IMDS on the live host, 2026-08-15):

| Property | Value | Source |
|---|---|---|
| Name | `luxauto-odoo` | IMDS |
| Size | `Standard_B2s` | IMDS |
| Image | `Canonical:ubuntu-24_04-lts:server:latest` | IMDS |
| OS disk | 64 GB, `ReadWrite` caching | IMDS |
| Region | `eastus2` | IMDS |
| Zone | none (no availability zone) | IMDS |
| Resource group | `luxauto-rg` | IMDS |
| Private IP | `10.20.3.4/24` (`luxauto-app-subnet`) | IMDS |
| Public IP | `20.110.2.164` | verified: egress IP and the A record for `mga.ironcliffvertex.com` both resolve to it |
| Admin user | `azureuser`, SSH key only, password auth disabled | IMDS |
| Identity | system-assigned (see step 3) | IMDS |

**ADR reference:** ADR 0009 (VM shape), ADR 0002 (Azure as provider).
**Confidence:** the shape is verified live. Whether a VM created to these values behaves
identically has never been tested.

---

## Step 3 — Managed identity and the Key Vault grant **[AZ]**

**This is the step whose omission breaks everything downstream in a way that looks like a
different problem.** Without it, `apply-and-verify-schema.sh`, `run-tests.sh` and the whole
CI path fail at credential fetch, not at anything resembling identity.

The rebuilt VM gets a **new** system-assigned identity with a **new** principal id. The old
role assignment does not transfer — it points at a principal that no longer exists.

Observed on the live host: client id `52449dd0-c05e-4bd6-9804-c78b75f3d8c0`,
principal (object) id `e67de137-c107-41fd-8226-1b3c0276504b`. **Both are dead after a
rebuild. Recorded here only so an orphaned assignment can be recognised and cleaned up.**

```bash
# 1. Enable the identity on the new VM
az vm identity assign -g luxauto-rg -n luxauto-odoo

# 2. Grant it read-only access to the vault
PRINCIPAL=$(az vm show -g luxauto-rg -n luxauto-odoo --query 'identity.principalId' -o tsv)
az role assignment create \
  --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope $(az keyvault show -n luxauto-kv-90a311 --query id -o tsv)

# 3. Clean up the orphan left by the old VM
az role assignment list --scope $(az keyvault show -n luxauto-kv-90a311 --query id -o tsv) \
  --query "[?principalId=='e67de137-c107-41fd-8226-1b3c0276504b']" -o table
```

`Key Vault Secrets User` is read-only and deliberately narrower than the `Key Vault Secrets
Officer` role used for initial setup (ADR 0009). Do not widen it.

**Vault contents, verified live via the identity — names only, values stay in the vault:**
`postgres-admin-password`, `postgres-admin-username`, `postgres-fqdn`,
`storage-account-key`, `storage-account-name`. Exactly the five ADR 0008 recorded; no drift.

**Verify before moving on**, from the new VM:

```bash
curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fvault.azure.net" \
  | python3 -c "import sys,json; print('token OK' if 'access_token' in json.load(sys.stdin) else 'FAILED')"
```

> **The VM's identity cannot read Azure resource metadata, and this was verified rather than
> assumed.** An ARM token is obtainable, but every read fails: `az`-equivalent REST calls for
> the VM, the Postgres server and the VNet each return `AuthorizationFailed`, and a resource
> listing returns an empty array rather than an error. **Nothing in the [AZ] category can be
> recovered from the VM itself** — those steps need an operator with their own Azure
> credentials. That is correct least-privilege behaviour, not a defect, but it means a
> rebuild cannot bootstrap its own Azure facts.

**ADR reference:** ADR 0009 (the managed-identity pattern), ADR 0008 (vault, and its
"whatever identity ends up running Odoo will need its own role assignment" note).
**Confidence:** the grant's *effect* is continuously proven — every CI run depends on it.
Re-creating it on a fresh identity has never been done.

---

## Step 4 — Network and NSG **[AZ]**

The rebuilt VM must land in `luxauto-app-subnet` (`10.20.3.0/24`) inside `luxauto-vnet-eus2`,
which is VNet-linked to the private DNS zone `luxauto-eus2.postgres.database.azure.com`.
That link is what makes step 5 work.

**The NSG is load-bearing security, is not in version control, and cannot be read from the
VM.** Recover it before destroying the old VM:

```bash
az network nsg rule list -g luxauto-rg --nsg-name <nsg-name> -o table
```

What the rules must achieve, verified live from the host:

- **80 and 443 inbound from the internet — open.** Intended (ADR 0009: it is a web app).
- **22 inbound** — sshd listens on `0.0.0.0:22`. Restrict as the old NSG did.
- **8069 and 8072 inbound — MUST be blocked.** This is the non-obvious one.

> **Odoo binds `0.0.0.0:8069` and `0.0.0.0:8072`, not loopback.** Verified with `ss -tlnp`.
> ADR 0009 describes nginx "proxying to Odoo on `127.0.0.1:8069`", which is accurate about
> the proxy *target* but says nothing about the *bind address* — and the bind address is all
> interfaces. `ufw` is inactive on this host, so **the NSG is the only thing preventing direct
> internet access to Odoo on 8069, bypassing nginx entirely** — including the
> `/web/database/manager` deny block from ADR 0009's Deviation 5, which lives only in the
> nginx config.
>
> Verified from the host against its own public IP: 8069 and 8072 both time out while 443
> returns 200, so the current NSG does block them. **A rebuilt VM given a default or
> permissive NSG would silently expose the Odoo database manager to the internet** — the
> exact risk Deviation 5 was written to close, reopened by a different layer. Test this
> explicitly in step 17.

**ADR reference:** ADR 0009 Deviation 5 (the risk), ADR 0008 (network model).
**Confidence:** current NSG behaviour verified live. The rule set itself has never been
captured into any document or template — recover it with `az` while the old VM exists.

---

## Step 5 — Confirm Postgres reachability before installing anything **[AZ]**

`luxauto-pg` is VNet-injected with no public endpoint (ADR 0008). Fixed at creation, no
toggle. Confirm the new VM can reach it before spending an hour on an Odoo install that will
fail at the end.

```bash
getent hosts luxauto-pg.postgres.database.azure.com
```

Expected, verified live:

```
10.20.1.4  c5000dd43191.luxauto-eus2.postgres.database.azure.com  luxauto-pg.postgres.database.azure.com
```

The public name CNAMEs into the **private** DNS zone and resolves to a private VNet address.
If it resolves to a public address or not at all, the private DNS zone is not linked to the
VNet — fix that (step 4) before continuing. Nothing later in this runbook can succeed.

---

## Step 6 — Base packages and the Odoo install **[AZ]** / **[HOST]**

Ubuntu 24.04, not 22.04 — ADR 0009 Deviation 1. The Odoo 19 `.deb` names Noble as the only
supported base. Start on 24.04; do not repeat the delete-and-recreate cycle that ADR 0009 paid for.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg nginx python3-pip

# Odoo 19 apt source - kept configured for dependency resolution and future
# deliberate upgrades, even though the install below does NOT come from it.
curl -fsSL https://nightly.odoo.com/odoo.key | sudo gpg --dearmor \
  -o /usr/share/keyrings/odoo-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/odoo-archive-keyring.gpg] https://nightly.odoo.com/19.0/nightly/deb/ ./" \
  | sudo tee /etc/apt/sources.list.d/odoo.list
sudo apt-get update
```

**Install the vendored build, not whatever the channel currently serves** — see the box
below for why this is the only durable option. The `.deb` lives in the `infra-artifacts`
container of the existing `luxautosa91a2e1` storage account (ADR 0008's account, a container
separate from `documents`):

```bash
# Credentials via this VM's managed identity + Key Vault - the ADR 0009 pattern.
# Requires step 3 to be done first.
TOKEN=$(curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fvault.azure.net" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
ACCOUNT=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://luxauto-kv-90a311.vault.azure.net/secrets/storage-account-name?api-version=7.4" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
KEY=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://luxauto-kv-90a311.vault.azure.net/secrets/storage-account-key?api-version=7.4" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

python3 - "$ACCOUNT" "$KEY" <<'PY'
import sys, hashlib
from azure.storage.blob import BlobServiceClient
acct, key = sys.argv[1], sys.argv[2]
cc = BlobServiceClient(f"https://{acct}.blob.core.windows.net",
                       credential=key).get_container_client("infra-artifacts")
data = cc.download_blob("odoo/odoo_19.0.20260809_all.deb").readall()
open("/tmp/odoo_19.0.20260809_all.deb", "wb").write(data)
print("sha256", hashlib.sha256(data).hexdigest())
PY

# MUST print ff0299061691d689a7fe30596e5024bdc67d05e7ed6fa48331578d3588863be5
sha256sum /tmp/odoo_19.0.20260809_all.deb

sudo apt-get install -y /tmp/odoo_19.0.20260809_all.deb
sudo apt-mark hold odoo
```

`apt-get install ./file.deb` (not `dpkg -i`) so apt resolves the package's dependencies from
the Ubuntu archive normally. The `apt-mark hold` is what stops a later routine
`apt-get upgrade` from undoing the pin.

> **Deviation 1a — the Odoo build is not reproducible from upstream. Vendored as of
> 2026-08-16; see ADR 0009's addendum to Deviation 1 for the full investigation.**
>
> The running host has `odoo 19.0.20260809`, a dated nightly. Three things were checked
> before choosing the fix, and each ruled out an option that looks reasonable:
>
> - **There is no stable channel to switch to.** `nightly.odoo.com` publishes only
>   `<series>/nightly/` for *every* series, 7.0 through master; `19.0/releases/` is a 404.
>   This is not a pre-release channel this project picked — it is Odoo's only apt channel.
> - **`apt-get install odoo=19.0.20260809` cannot work.** The repo's `Packages` index holds
>   exactly **one** `odoo` entry (today `19.0.20260816`). A version-qualified install can only
>   resolve what the index lists, so it fails outright. The earlier version of this runbook
>   suggested this as an option; it was wrong.
> - **Upstream prunes the artifact on a schedule.** The `.deb` is still there today, but
>   enumerating both the 19.0 and 18.0 directories shows the same pattern: dailies for
>   roughly the last 3–4 months, then **one build per month** kept indefinitely. `20260809`
>   is not a month boundary, so on this pattern it disappears around **late Nov–mid Dec
>   2026**. Fetching from upstream at rebuild time is a fix with a silent expiry date.
>   (Inferred from directory listings — Odoo publishes no retention policy.)
>
> So the artifact is vendored to Blob, verified byte-identical to both the VM's apt cache and
> a fresh upstream download (`sha256 ff0299…3be5`), and verified retrievable by downloading
> it back and re-hashing.
>
> **`apt-mark hold` is applied on the live host but does not solve this step.** A hold stops
> an installed package from moving; it does nothing for a fresh install. It was worth applying
> for its own reason: `apt-get -s upgrade` confirmed a routine patch run would have moved the
> live host to `20260816` silently. (unattended-upgrades never would have — the Odoo repo
> publishes no `Origin`, so it matches no `Allowed-Origins` pattern and gets a `-32768` pin.)
>
> **Residual risk, honestly:** one blob, one Standard_LRS account, one region, not replicated
> or versioned — this protects against upstream pruning and VM loss, not against loss of the
> resource group. And **only this build is vendored**: every future deliberate Odoo upgrade
> must vendor its artifact too, or this gap reopens one upgrade later. Nothing enforces that
> but this sentence.

**Immediately after install, before ever starting Odoo** — ADR 0009 Deviation 2. The `.deb`
pulls in `postgresql-16` and initialises a local cluster nobody wants:

```bash
sudo systemctl stop postgresql
sudo systemctl disable postgresql
```

Verified live: `postgresql-16` is installed, `postgresql.service` is `disabled` and
`inactive`. Left installed rather than purged, deliberately (ADR 0009 Consequences).

Then the dependency the packages do not pull in — ADR 0009 Deviation 4:

```bash
sudo pip3 install --break-system-packages python-slugify adlfs
```

Verified live: `python-slugify 8.0.4`, `adlfs 2026.5.0`, `fsspec 2026.7.0`,
`azure-storage-blob 12.30.0`, `psycopg2 2.9.9`. `adlfs` is what provides the `abfs` protocol
step 13 depends on; `fsspec`/`azure-storage-blob` arrive as its dependencies.

**Confidence:** the package list is verified live. The install sequence has never been run
end to end from this document.

---

## Step 7 — The OCA addons clones **[EXT]**

Two upstream OCA repos, both on branch `19.0`, verified live:

```bash
sudo mkdir -p /opt/odoo-custom-addons
sudo chown odoo:odoo /opt/odoo-custom-addons
sudo -u odoo git clone -b 19.0 https://github.com/OCA/storage.git    /opt/odoo-custom-addons/storage
sudo -u odoo git clone -b 19.0 https://github.com/OCA/server-env.git /opt/odoo-custom-addons/server-env
```

`fs_storage` depends on `server_environment`, which lives in the *other* repo — ADR 0009
Deviation 4. Both are required; cloning only `storage` fails.

Commits on the live host (for reference, not pinning — these are moving branches):
`storage` at `33d0fd4`, `server-env` at `fe6a410`.

---

## Step 8 — The first-party clone **[VC]**

```bash
sudo -u odoo git clone https://github.com/jrbroedel/ai-ins-full-company \
  /opt/odoo-custom-addons/luxauto
```

This is the clone Odoo loads addons from and the one `deploy-vm.sh` pulls — **not** the
Actions checkout under `/opt/actions-runner/_work/`, which is a different directory with a
different owner and a different trust story (ADR 0020 addendum).

Verified live: remote `https://github.com/jrbroedel/ai-ins-full-company`, branch `main`,
clean working tree, at `fcad2e8`. **The clone carries no credentials** — the `odoo` user has
no `.gitconfig` and no `.git-credentials` (verified). The repository is public, so pulls are
anonymous. Do not add a credential here; the deploy path does not need one.

The path must be exactly `/opt/odoo-custom-addons/luxauto` — it is hardcoded in
`/etc/sudoers.d/10-ghrunner-deploy` (twice) and in the deploy wrapper. A different path
means `sudo` refuses and the deploy fails.

---

## Step 9 — `/etc/odoo/odoo.conf` **[HOST]**

**Not in version control anywhere.** Reproduce it exactly. Mode `0640`, owner `odoo:odoo`.

```ini
[options]
admin_passwd = <generate a strong one; NOT recoverable from anywhere>
db_host = luxauto-pg.postgres.database.azure.com
db_port = 5432
db_user = odoo
db_password = <the `odoo` role's password - see below>
db_sslmode = require
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/opt/odoo-custom-addons/storage,/opt/odoo-custom-addons/server-env,/opt/odoo-custom-addons/luxauto/odoo/addons
default_productivity_apps = True
proxy_mode = True
workers = 3
logfile = /var/log/odoo/odoo-server.log
list_db = False
running_env = production
```

Every non-default value and where it came from:

| Key | Why it is set | Traces to |
|---|---|---|
| `db_user = odoo` | Dedicated least-privilege role, not the Flexible Server admin | ADR 0009 Deviation 3 |
| `db_sslmode = require` | Azure Flexible Server | ADR 0008 |
| `addons_path` | Four entries. The last three are step 7 and step 8. Order matters only in that stock Odoo comes first. | ADR 0009, ADR 0012 |
| `proxy_mode = True` | Required because nginx terminates TLS (step 11) | ADR 0009 |
| `workers = 3` | Prefork. **Load-bearing for deploys**: with `workers > 0`, `odoo -u --stop-after-init` binds the HTTP port before loading the registry, which is why `deploy-vm.sh` stops the service around the upgrade | ADR 0015 / `deploy-vm.sh` header |
| `list_db = False` | Set, and **verified not to work** — it does not block `/web/database/manager` in Odoo 19. Kept anyway; nginx does the real blocking | ADR 0009 Deviation 5 |
| `running_env = production` | Read by OCA `server_environment`. Odoo logs `unknown option 'running_env'... stored as-is` — expected and harmless. **Without this, step 13 silently does nothing.** | ADR 0009 Deviation 7 |

**Two credentials you must be able to supply, and neither is in Key Vault:**

- **`db_password`** — the `odoo` Postgres role's password. The vault holds
  `postgres-admin-password`, which is the **admin** role, a *different* credential. The
  `odoo` role's password exists only in this file. On an unplanned loss it is unrecoverable
  and must be reset as the admin role against the surviving server:
  `ALTER ROLE odoo WITH PASSWORD '<new>';`
- **`admin_passwd`** — Odoo's master password. Not stored anywhere else. Generate a new one;
  nothing depends on continuity, and the route it guards is blocked by nginx regardless.

**Drift noted, not corrected:** `/etc/odoo/` also holds `odoo.conf.bak.20260812153144` and
`odoo.conf.bak.20260812203626` — leftovers from hand-edits. Do not recreate them.

**Confidence:** the file is transcribed from the live host. **The two secrets in it are the
clearest single-point-of-loss in this system** — a planned rebuild must capture them (step 1);
an unplanned one must reset the Postgres role and regenerate the master password.

---

## Step 10 — DNS **[EXT]**

`mga.ironcliffvertex.com` is an A record in **Cloudflare**, pointing at the VM's public IP,
set **DNS only** (grey cloud, proxy disabled) — deliberately, so the Let's Encrypt HTTP-01
challenge in step 11 is not routed through Cloudflare's proxy (ADR 0009).

Verified live: `mga.ironcliffvertex.com` → `20.110.2.164`, which is also the VM's egress IP.

If the rebuilt VM has a different public IP, update this record and let it propagate
**before** step 11. Certbot's HTTP-01 challenge fails against a stale record, and a handful
of failures will hit Let's Encrypt rate limits.

---

## Step 11 — nginx **[HOST]**

**Not in version control anywhere.** This is the file that enforces ADR 0009 Deviation 5.

Write it to `/etc/nginx/sites-available/odoo` and symlink it into `sites-enabled/`. Note the
ordering trap below — write it **without** the certbot-managed TLS lines first, then let
certbot add them.

```nginx
upstream odoo     { server 127.0.0.1:8069; }
upstream odoochat { server 127.0.0.1:8072; }

server {
    listen 80;
    # Deviation 6: a real hostname from the start, NOT `server_name _;`.
    # certbot's nginx plugin cannot match a catch-all and will obtain the
    # certificate but fail to install it.
    server_name mga.ironcliffvertex.com;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;

    # ADR 0009 Deviation 5. This block, not `list_db = False`, is what
    # actually blocks the database manager. Do not remove it.
    location ~ ^/web/database/(manager|selector|list|create|duplicate|drop|backup|restore|change_password) {
        deny all;
        return 403;
    }
    location = /websocket {
        proxy_pass http://odoochat;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location /longpolling { proxy_pass http://odoochat; }
    location / {
        proxy_redirect off;
        proxy_pass http://odoo;
    }

    client_max_body_size 100M;
}
```

```bash
sudo ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo
sudo rm -f /etc/nginx/sites-enabled/default   # matches the live host
sudo nginx -t && sudo systemctl reload nginx
```

Then TLS — ADR 0009 Deviation 6:

```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d mga.ironcliffvertex.com
```

With a real `server_name` already in place, the plugin matches the block, adds the
`listen 443 ssl` directives and the HTTP→HTTPS redirect server, and the separate
`certbot install --cert-name ... --nginx` step ADR 0009 needed is not required.

**Check afterwards, do not assume:** certbot rewrites this file, and the
`/web/database/(manager|...)` block must survive the rewrite. ADR 0009 checked this
explicitly; so should you. On the live host it did survive.

Certificate on the live host: ECDSA, expires 2026-11-08, auto-renewing via `certbot.timer`
(enabled, twice-daily). The renewal timer is set up by the package — nothing extra to do.

---

## Step 12 — The GitHub Actions runner **[HOST]** / **[EXT]**

Nothing about this exists in version control. ADR 0020 describes it; this is the reconstruction.

```bash
# Dedicated non-root service account - NOT azureuser (which holds NOPASSWD:ALL
# via /etc/sudoers.d/waagent) and NOT root. ADR 0020 section 1.
sudo useradd -m -d /opt/actions-runner -s /bin/bash -u 999 ghrunner
sudo passwd -l ghrunner

sudo -u ghrunner mkdir -p /opt/actions-runner
cd /opt/actions-runner
sudo -u ghrunner curl -o actions-runner-linux-x64-2.336.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-linux-x64-2.336.0.tar.gz
sudo -u ghrunner tar xzf actions-runner-linux-x64-2.336.0.tar.gz

# Registration token from the repo's Settings > Actions > Runners > New self-hosted runner.
# Short-lived; generate it immediately before this command.
sudo -u ghrunner ./config.sh \
  --url https://github.com/jrbroedel/ai-ins-full-company \
  --token <REGISTRATION-TOKEN> \
  --name luxauto-odoo \
  --labels self-hosted,linux,luxauto-odoo \
  --work _work --unattended

sudo ./svc.sh install ghrunner
sudo ./svc.sh start
```

Verified live: runner **v2.336.0**, agent name `luxauto-odoo`, `ghrunner` uid **999**,
home `/opt/actions-runner`, service unit
`actions.runner.jrbroedel-ai-ins-full-company.luxauto-odoo.service` — `enabled` and `active`,
`ExecStart=/opt/actions-runner/runsvc.sh`, `User=ghrunner`.

**The labels matter.** Both workflows pin `runs-on: [self-hosted, linux, luxauto-odoo]`
(ADR 0020 section 2), so a runner registered without the `luxauto-odoo` label is invisible to
them and every push queues forever.

**Register exactly one runner.** A second converts ADR 0020 section 2's ordering hazard from
arbitrary serialization into genuine parallelism. Do not add one during a rebuild "to speed
things up."

**Credentials:** registration writes `.credentials` and `.credentials_rsaparams` (an RSA
keypair) into `/opt/actions-runner/`. These are **not** recoverable and **not** transferable —
a rebuilt VM must re-register and get new ones. Deregister the old runner in the GitHub UI
afterwards, or it lingers as a permanently offline entry.

**Verify:**

```bash
sudo journalctl -u actions.runner.jrbroedel-ai-ins-full-company.luxauto-odoo.service -b | tail
# expect: "√ Connected to GitHub" then "Listening for Jobs"
```

**Confidence:** ADR 0020 section 5 proved this service **survives a reboot** — that is real
evidence, and it is evidence about `systemctl` restarting an already-registered runner. It
says nothing about a fresh install and registration succeeding from these instructions, which
has never been done.

---

## Step 13 — `server_environment_files` **[VC]**

ADR 0009 Deviation 7, and its 2026-08-15 addendum. **This step used to be the most dangerous
one in this runbook — host-only, easy to skip, and silent when wrong. It is now carried by
step 8's `git clone` and needs no action.** The history is kept because the failure mode it
guards against is still worth understanding.

The package lives at `odoo/addons/server_environment_files/` in this repository, so the
clone from step 8 already contains it at
`/opt/odoo-custom-addons/luxauto/odoo/addons/server_environment_files/`. Nothing to create.

Every detail is still load-bearing, and was established by reading source rather than guessing:

- It is imported as `from odoo.addons import server_environment_files`, through the
  `odoo.addons` namespace — so it works from **any** `addons_path` entry, which is what made
  relocating it into this repo possible. It still cannot be its own top-level `addons_path`
  entry.
- `production/` matches `running_env = production` in `odoo.conf` (step 9). **Without that
  key, this package does nothing** — the two are a pair.
- The suffix must be `.conf`, not `.cfg` — `server_env.py`'s `_listconf()` filters on it.
- The section name is `fs_storage.azure_blob_documents` — `<model name, dots to underscores>.<the
  record's `code`>`, because `fs_storage` overrides `_server_env_section_name_field` to `"code"`.
  Verified live: the record's `code` is `azure_blob_documents`.
- It has no `__manifest__.py` and is not a module. The deploy wrapper's module scan
  (`odoo/addons/*/__manifest__.py`) skips it — checked, not assumed.

**Verified live: `fs_storage` has no `use_as_default_for_attachments` column in Postgres**
(`information_schema` returns 0 rows for it). There is no database row to fall back on. The
config file is the only source.

> **Do not recreate this directory in the OCA `server-env` clone.** That is where it used to
> live, and the copy there has been deleted deliberately. `addons_path` lists `server-env`
> *before* this repo's addons directory, so a stray copy there would win — and the
> version-controlled one would sit there looking authoritative while doing nothing.

**The failure modes, reproduced live rather than reasoned about** — worth knowing because
two of the three are silent:

| What goes missing | What happens |
|---|---|
| The whole package | `ImportError`, logged at **INFO** only, config ignored — **silent** |
| `production/fs_storage.conf` | field falls back to `False`, **no log at all** — **silent** |
| `production/` directory | `Exception: Provided server environment does not exist...` — Odoo refuses to start |

In both silent cases `ir.attachment._storage()` returns `'file'` — **the local filestore on
the VM's own disk** (step 14), *not* the database. That is the worse of the two possible
fallbacks here: new attachments would land on the one piece of storage a VM rebuild destroys.

**This is now checked at deploy time.** `scripts/lib/smoke_test.py` asserts
`env['ir.attachment']._storage() == 'azure_blob_documents'` and fails the whole deploy if not,
emitting `SMOKE_TEST_CHECK=attachment_storage RESULT=...`. Confirm that line reads `PASS` in
step 17b. The check runs per deploy, not continuously — between deploys this could still
regress unnoticed.

---

## Step 14 — Odoo filestore **[HOST]**

`odoo.conf` sets no `data_dir`, so Odoo uses the default under the `odoo` user's home:
`/var/lib/odoo/.local/share/Odoo/filestore/luxauto`. Verified live: **18 files, 2.5 MB**.

This is on the VM's OS disk. Not in Blob, not in Postgres, not in git. **A rebuild destroys it.**

What is actually in it, checked rather than assumed — of 206 `ir_attachment` rows:

- **190** are stored in the database (`db_datas`) and are unaffected by a rebuild.
- **15** have a `store_fname` and live in this filestore.
- **0** are in Blob Storage (`fs_filename` is null on every row).

That last number looks alarming and is not. The `fs_storage` record's
`force_db_for_default_attachment_rules` is `{"image/": 51200, "application/javascript": 0,
"text/css": 0}`, and every one of the 206 attachments is an `image/*`, `application/javascript`,
`text/scss` or `text/css` — precisely the types those rules keep out of the object store.
Blob is configured correctly and simply has nothing routed to it yet. **This is expected
behaviour, not drift**, but it does mean the Blob path (step 13) is currently unexercised by
real data and a rebuild would not notice if it broke.

Most of the 15 filestore entries are Odoo's own generated web-asset bundles, which Odoo
regenerates automatically on first request after an upgrade. A few are real images
(`image_1920`/`image_512`/`image_256` — company or partner avatars) that would be lost.
Small, but real, and non-recoverable if not captured in step 1.

```bash
# On a planned rebuild, restore what step 1 captured
sudo -u odoo mkdir -p /var/lib/odoo/.local/share/Odoo/filestore
sudo tar xzf ~/luxauto-host-state.tgz -C / var/lib/odoo/.local/share/Odoo/filestore
sudo chown -R odoo:odoo /var/lib/odoo/.local
```

---

## Step 15 — Database: connect, do not recreate **[VC]** / **[AZ]**

**The `luxauto` database already exists on `luxauto-pg` with all its data.** Do not run
`odoo -d luxauto -i base`. Do not create a database. Do not run ADR 0009's Deviation 3 grants
(`ALTER SCHEMA public OWNER TO odoo`) — they were a one-time fix at database *creation*, the
schema is already owned by `odoo`, and re-running them against a live database is
unnecessary risk for no benefit.

What the rebuilt VM needs is the `odoo` role's password (step 9) and network reachability
(step 5). That is all.

Then run the repo's own idempotent apply-and-verify, which is safe against a database that
already has every object:

```bash
cd /opt/odoo-custom-addons/luxauto
sudo -u odoo ./scripts/apply-and-verify-schema.sh
```

It fetches admin credentials from Key Vault via the managed identity (step 3), applies
`schemas/db/postgresql_schema.sql`, then parses that file for every declared table, type,
function, view and trigger and confirms each exists (ADR 0015 sections 1–2). On an unchanged
database it is a no-op that ends in a verification pass — **which makes it the best available
end-to-end proof that steps 3, 5 and 9 are all correct**, since it exercises the managed
identity, Key Vault, DNS, the private network path and the Postgres credential in one command.

Start Odoo:

```bash
sudo systemctl enable --now odoo
```

**ADR reference:** ADR 0015 (the script), ADR 0011 (why verification exists at all — the
schema silently went missing once and nothing caught it).
**Confidence:** this script runs on every push to `main`, so it is the **best-tested step in
this runbook**. Running it against a freshly rebuilt host is untested only in that the host
is new; the script itself is exercised continuously.

---

## Step 16 — sudoers and the deploy wrapper **[HOST]** ⚠

ADR 0020 section 3 and its addendum. **Neither file is in version control and neither can be:
a workflow able to write them would hand back exactly the privilege they remove.** They are
provisioned by hand as `azureuser`, and this runbook is the only reconstruction path.

### 16a — `/usr/local/sbin/luxauto-odoo-deploy-ctl`

Root-owned, mode `0755`, `root:root`, **outside the git clone**. The repo references this path
by name (in `deploy-vm.sh` and ADR 0020) but **contains none of its contents** — verified.

The full script is reproduced in [Appendix A](#appendix-a-luxauto-odoo-deploy-ctl) —
transcribed verbatim from the live host, since nothing else can supply it.

```bash
sudo install -o root -g root -m 0755 /path/to/luxauto-odoo-deploy-ctl /usr/local/sbin/
```

Verify ownership, which is the actual security property (not the mode bits, and not setuid —
Linux ignores setuid on `#!` scripts entirely, and sudo's `(odoo)` target does the transition):
the file must not be writable by `ghrunner` **or** by `odoo`.

### 16b — `/etc/sudoers.d/10-ghrunner-deploy`

Mode `0440` `root:root`. **Validate before installing** — a malformed sudoers file can lock
out sudo entirely:

```bash
sudo visudo -c -f /path/to/candidate      # check the candidate first
sudo install -o root -g root -m 0440 /path/to/candidate /etc/sudoers.d/10-ghrunner-deploy
sudo visudo -c                            # then re-check the whole set
```

Contents in [Appendix B](#appendix-b-etcsudoersd10-ghrunner-deploy), transcribed from the live host.

**Verify the effective grants** — the resolved output matters more than the file:

```bash
sudo -l -U ghrunner
```

Expected exactly (verified live, matching ADR 0020's addendum with no drift):

```
(root) NOPASSWD: /usr/bin/systemctl stop odoo, /usr/bin/systemctl start odoo,
                 /usr/bin/systemctl is-active --quiet odoo
(odoo) NOPASSWD: /usr/bin/git -C /opt/odoo-custom-addons/luxauto status --short,
                 /usr/bin/git -C /opt/odoo-custom-addons/luxauto pull,
                 /usr/local/sbin/luxauto-odoo-deploy-ctl upgrade,
                 /usr/local/sbin/luxauto-odoo-deploy-ctl smoketest
```

**No `/usr/bin/odoo *` wildcard.** If you see one, you have reconstructed the pre-addendum
state and reopened what ADR 0020's addendum closed.

Also verify, because the addendum's argument depends on it: **`ghrunner` must not be in the
`odoo` group.** Verified live — `id ghrunner` shows `groups=988(ghrunner)` only. If it is in
the `odoo` group it can write the clone, and therefore the smoke-test payload, which is the
precise hole the wrapper exists to close.

### 16c — Repository Actions setting **[EXT]**

**A requirement, not a suggestion** (ADR 0020 section 4). This repository is **public**, and a
self-hosted runner on a public repo is the configuration GitHub explicitly warns against.

In repo Settings → Actions → General, "Fork pull request workflows from outside collaborators"
must be **"Require approval for all outside collaborators."** This is repository state, not VM
state, so a VM rebuild does not disturb it — **verify it anyway**, since it is the control
standing between an anonymous fork PR and code execution on this host, with the managed
identity and the sudoers grant attached.

---

## Step 17 — The systemd timer, first deploy, and verification **[VC]** / **[HOST]**

### 17a — `luxauto-expire-policies` timer

ADR 0019. **The unit files ARE in version control** — `infra/systemd/` — and were verified
byte-identical to the installed copies. Installation is manual and is *not* done by
`deploy-vm.sh`:

```bash
sudo cp /opt/odoo-custom-addons/luxauto/infra/systemd/luxauto-expire-policies.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now luxauto-expire-policies.timer
```

Verified live: timer `active`, hourly with `Persistent=true`, running
`/opt/odoo-custom-addons/luxauto/scripts/expire-policies.sh` as the `odoo` user.

Easy to forget in a rebuild, and its absence is silent — policies past their term keep
showing the wrong status and nothing complains.

### 17b — First deploy

```bash
cd /opt/odoo-custom-addons/luxauto
./scripts/deploy-vm.sh
```

Expect `LUXAUTO_DEPLOY_CTL=upgrade ...` and `LUXAUTO_DEPLOY_CTL=smoketest ...` banners in the
output — the wrapper announcing itself, which is how you confirm step 16a's pinned path
actually ran rather than inferring it from a sudoers file. End state must be
`SMOKE_TEST_RESULT=PASS`.

### 17c — Verification checklist

Nothing is done until all of these pass. Several are things the ADRs verified once and no
automation re-checks:

| Check | Command | Expected |
|---|---|---|
| Odoo running | `systemctl is-active odoo` | `active` |
| nginx running | `systemctl is-active nginx` | `active` |
| Local Postgres disabled | `systemctl is-enabled postgresql` | `disabled` |
| Runner connected | `journalctl -u actions.runner.*luxauto-odoo.service -b \| tail` | `Listening for Jobs` |
| Expire timer armed | `systemctl list-timers luxauto-expire-policies.timer` | scheduled |
| Login page | `curl -o /dev/null -w '%{http_code}' https://mga.ironcliffvertex.com/web/login` | `200` |
| **DB manager blocked** | `curl -o /dev/null -w '%{http_code}' https://mga.ironcliffvertex.com/web/database/manager` | **`403`** |
| HTTP redirects | `curl -o /dev/null -w '%{http_code}' http://mga.ironcliffvertex.com/` | `301` |
| **Odoo NOT exposed** | `curl --max-time 8 http://<public-ip>:8069/` | **timeout** (step 4) |
| Managed identity | IMDS token snippet, step 3 | `token OK` |
| Schema verified | `./scripts/apply-and-verify-schema.sh` | all objects pass |
| Test suites | `./scripts/run-tests.sh` | pass |
| Smoke test | `./scripts/deploy-vm.sh` | `SMOKE_TEST_RESULT=PASS` |
| sudo grants exact | `sudo -l -U ghrunner` | the seven entries in 16b, no wildcard |
| **Blob storage active** | the `SMOKE_TEST_CHECK=attachment_storage` line from 17b | **`RESULT=PASS`** (step 13) |
| **Full CI path** | push a trivial commit to `main` | both workflows green |

That last row is the only check that exercises the runner, the workflows, the sudoers grant,
the wrapper, the schema path and the deploy path together. Do it.

Check the database-manager row **against the public URL, not localhost** — and check the
response *content*, not only the status code, the way ADR 0009 Deviation 5 did. The unblocked
version also returned 200, so a status code alone proves nothing.

---

## Confidence: what is tested and what is not

The whole point of this section is that "documented" and "tested" are different words.

### Has real evidence behind it

| Item | What the evidence actually covers | Source |
|---|---|---|
| Runner survives a restart | The host was deliberately rebooted; the service reconnected in 7s, `NRestarts=0`, log lines from the current boot. **This covers "an already-registered runner comes back after systemd restarts it." It does not cover installing or registering one from scratch.** | ADR 0020 §5 |
| Schema apply/verify | Runs on every push to `main`. Idempotent and continuously exercised. | ADR 0015, ADR 0020 |
| Deploy path incl. wrapper | Run end to end through the wrapper, both banners observed, seven models passing. **Covers the wrapper working. Does not cover creating it on a new host.** | ADR 0020 addendum |
| sudoers grants | `sudo -l -U ghrunner` verified before and after the addendum; negative cases (`/usr/bin/odoo` directly, `restart`, no-arg, `(root)`) all confirmed refused. | ADR 0020 addendum |
| TLS / DB-manager block | 200 / 403 / 301 verified at the time and **re-verified live while writing this runbook**. | ADR 0009 |
| Blob wiring | Verified three independent ways (raw `fsspec`, ORM round-trip, `fsspec` read-back). | ADR 0009 |
| Everything transcribed here | Read off the running host on 2026-08-15, not copied from the ADRs. | this runbook |

### Has NEVER been tested for reprovisioning

Every one of these is a first-time-ever operation on a rebuild:

1. **Creating the VM.** No IaC. No `az vm create` invocation is recorded anywhere.
2. **Creating a new managed identity and Key Vault role assignment.** Done once, by hand,
   for the current identity. Never repeated.
3. **The NSG rule set.** Never captured. Not in any template or document. Currently
   verified-working only by black-box probing from the host.
4. **Installing Odoo from the vendored `.deb`.** No longer guaranteed to install a
   *different* build — the exact artifact is vendored and checksum-verified (step 6) — but
   installing from it, and the `apt-get install ./file.deb` dependency resolution around it,
   has never been exercised on a fresh host.
5. **Reconstructing `odoo.conf`**, including a `db_password` that must be reset if not
   captured first.
6. **Reconstructing the nginx config** and surviving certbot's rewrite of it.
7. **Installing and registering the runner from scratch**, including labels.
8. ~~Creating `server_environment_files`.~~ **No longer applicable** — it is version-controlled
   as of 2026-08-15 and arrives with step 8's clone. Its silent failure mode is now caught by
   the smoke test, and that check was verified by reproducing all three failure modes live.
9. **Creating the wrapper and sudoers file** from Appendices A and B. These are transcriptions.
   A transcription error in the sudoers file breaks CI loudly; one in the wrapper could break
   it quietly.
10. **The filestore restore.**
11. **The whole thing in sequence.** Each step above is individually untested for
    reprovisioning; their *ordering* is inferred from dependencies, not observed.

### The follow-up this document does not do

**Stand up a parallel VM — a different name, the same subnet, its own identity — and execute
this runbook end to end against it.** That is the only thing that converts this from a
careful reconstruction into a verified procedure, and it is deliberately out of scope here.
It is a larger undertaking: it needs a second Azure VM, its own Key Vault role assignment, a
DNS name that is not `mga.ironcliffvertex.com` (so TLS can be exercised without disturbing
production), a second runner registration that must be removed afterwards (see step 12's
warning about parallelism), and a decision about whether it points at the production
`luxauto` database or a copy — almost certainly a copy.

Until that happens, treat every time estimate implied by this document as unknown, and expect
to debug at least a few of the eleven items above during a real rebuild.

---

## Appendix A: `luxauto-odoo-deploy-ctl`

Transcribed verbatim from `/usr/local/sbin/luxauto-odoo-deploy-ctl` on the live host
(mode `0755`, `root:root`). Reproduced in full because **this repository does not contain it
and deliberately must not** — ADR 0020's addendum. This appendix is the only recovery path.

```bash
#!/bin/bash
# luxauto-odoo-deploy-ctl - the two privileged Odoo operations scripts/deploy-vm.sh
# needs, with every parameter pinned here instead of supplied by the caller.
# ADR 0020 addendum; closes the `/usr/bin/odoo *` sudoers wildcard that ADR 0020
# section 3 recorded as a deferred hardening item.
#
# THIS FILE IS DELIBERATELY OUTSIDE THE GIT CLONE, root-owned and mode 0755.
# That is the whole mechanism: /etc/sudoers.d/10-ghrunner-deploy grants ghrunner
# exactly `luxauto-odoo-deploy-ctl upgrade` and `luxauto-odoo-deploy-ctl smoketest`
# as the odoo user and nothing else, so neither ghrunner nor odoo can rewrite what
# those two words do. Anything that let a CI job edit this file would give back
# precisely the privilege it removes - do not move it into the repository, and do
# not have a workflow install it.

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly CLONE_DIR=/opt/odoo-custom-addons/luxauto
readonly ODOO_CONF=/etc/odoo/odoo.conf
readonly ODOO_DB=luxauto
readonly ODOO_BIN=/usr/bin/odoo
readonly SMOKE_TEST="$CLONE_DIR/scripts/lib/smoke_test.py"

usage() {
  cat >&2 <<'EOF'
luxauto-odoo-deploy-ctl: exactly one of two literal arguments is accepted.

  upgrade     Upgrade every first-party module in the addons clone against the
              pinned config and database, then stop.
  smoketest   Run the addons clone's own scripts/lib/smoke_test.py through
              `odoo shell` against the pinned config and database.

No other argument is accepted, and no argument is passed through to odoo. If you
need a different invocation, run it directly as the odoo user - this wrapper
exists so that the CI runner's sudo grant cannot.
EOF
  exit 2
}

# No pass-through of any kind: exactly one argument, from a closed set.
[[ $# -eq 1 ]] || usage

# A deterministic working directory. Under sudo this would otherwise inherit the
# caller's cwd, which the odoo user may not even be able to read.
cd /

case "$1" in
  upgrade)
    MODULES=""
    for manifest in "$CLONE_DIR"/odoo/addons/*/__manifest__.py; do
      [[ -e "$manifest" ]] || continue
      MODULES="${MODULES:+$MODULES,}$(basename "$(dirname "$manifest")")"
    done

    if [[ -z "$MODULES" ]]; then
      echo "luxauto-odoo-deploy-ctl: no module with a __manifest__.py found under" >&2
      echo "$CLONE_DIR/odoo/addons - a wrong clone path or a bad pull is likelier" >&2
      echo "than a real answer. Refusing to run an upgrade with an empty module list." >&2
      exit 1
    fi

    echo "LUXAUTO_DEPLOY_CTL=upgrade db=$ODOO_DB conf=$ODOO_CONF modules=$MODULES"

    exec "$ODOO_BIN" --config "$ODOO_CONF" -d "$ODOO_DB" -u "$MODULES" \
         --stop-after-init --no-http --logfile=
    ;;

  smoketest)
    if [[ ! -f "$SMOKE_TEST" ]]; then
      echo "luxauto-odoo-deploy-ctl: $SMOKE_TEST does not exist - refusing to run" >&2
      echo "a smoke test with no payload, which would otherwise read this process's" >&2
      echo "stdin and report a pass on an empty program." >&2
      exit 1
    fi

    echo "LUXAUTO_DEPLOY_CTL=smoketest db=$ODOO_DB conf=$ODOO_CONF payload=$SMOKE_TEST"

    # The redirection is performed HERE on purpose. It used to be performed by
    # the caller's shell, which meant ghrunner chose the payload; now the caller's
    # stdin is discarded no matter what it contains.
    exec "$ODOO_BIN" shell --config "$ODOO_CONF" -d "$ODOO_DB" --no-http < "$SMOKE_TEST"
    ;;

  *)
    usage
    ;;
esac
```

*(The live file carries a longer comment header explaining what the wrapper does and does not
narrow; it is preserved on the host and summarised in ADR 0020's addendum. The executable
logic above is complete and verbatim.)*

---

## Appendix B: `/etc/sudoers.d/10-ghrunner-deploy`

Transcribed verbatim from the live host (mode `0440`, `root:root`). Validate with
`visudo -c -f` before installing.

```
# ADR 0020: the minimum privileges the GitHub Actions self-hosted runner
# (service user `ghrunner`) needs to execute scripts/deploy-vm.sh without a
# TTY. Every entry here corresponds to a specific line in that script; nothing
# is granted speculatively. See docs/decisions/0020-cicd-automation.md.
#
# NOPASSWD is required, not convenience: a workflow job has no TTY, so a sudo
# password prompt fails the step outright rather than waiting for anyone.

# deploy-vm.sh lines 77, 97, 104 - stop/start around the module upgrade.
# line 106 - post-start liveness check.
Cmnd_Alias LUXAUTO_ODOO_SVC = /usr/bin/systemctl stop odoo, \
                              /usr/bin/systemctl start odoo, \
                              /usr/bin/systemctl is-active --quiet odoo

# deploy-vm.sh lines 34, 48 - dirty-state check and pull of the addons clone.
# Pinned to the exact argument vectors the script uses: bare `git` as another
# user is arbitrary code execution (aliases, core.sshCommand, -c overrides).
Cmnd_Alias LUXAUTO_GIT = /usr/bin/git -C /opt/odoo-custom-addons/luxauto status --short, \
                         /usr/bin/git -C /opt/odoo-custom-addons/luxauto pull

# deploy-vm.sh's module upgrade and smoke test. ADR 0020's addendum replaced the
# `/usr/bin/odoo *` wildcard that used to live here with these two exact-match
# entries. The wrapper is root-owned, mode 0755, and deliberately OUTSIDE the git
# clone: it hardcodes the clone path, config, database and smoke-test payload, so
# neither ghrunner nor odoo can change what these two words do.
Cmnd_Alias LUXAUTO_ODOO_BIN = /usr/local/sbin/luxauto-odoo-deploy-ctl upgrade, \
                              /usr/local/sbin/luxauto-odoo-deploy-ctl smoketest

ghrunner ALL=(root) NOPASSWD: LUXAUTO_ODOO_SVC
ghrunner ALL=(odoo) NOPASSWD: LUXAUTO_GIT, LUXAUTO_ODOO_BIN
```

---

## Appendix C: drift and discrepancies found during this investigation

Recorded rather than silently corrected, per the instruction that produced this document.
None of these were fixed here; each is a separate, deliberate decision.

1. ~~**Odoo is installed from a rolling nightly channel and is not version-pinned.**~~
   **MITIGATED 2026-08-16.** Investigation found there is no stable channel to switch to
   (`nightly.odoo.com` runs only nightly channels, for every series), that
   `apt-get install odoo=<version>` cannot work because the index lists exactly one version,
   and that upstream prunes non-month-boundary `.deb`s after ~3–4 months — so `20260809`
   would have vanished around late 2026. The artifact is now vendored to the `infra-artifacts`
   container of the existing storage account, checksum-verified against upstream and verified
   retrievable, and step 6 installs from it. `apt-mark hold odoo` was applied separately for
   live drift. **Not fully closed:** one un-replicated blob, and each future Odoo upgrade must
   vendor its own artifact or the gap reopens. See ADR 0009's addendum to Deviation 1.
2. ~~**`server_environment_files` is untracked inside a third-party clone.**~~ **FIXED
   2026-08-15 — no longer true.** Investigated, found to contain no secrets (the Blob
   credentials live in the database, not in it) and to be untracked simply because it had
   been created inside someone else's clone, not because upstream excludes it. It is now
   version-controlled at `odoo/addons/server_environment_files/`, the copy in the OCA clone
   has been deleted, and `smoke_test.py` now fails the deploy if attachment storage is not
   resolving to Blob. Step 13 is rewritten accordingly and is now **[VC]**. See ADR 0009's
   Deviation 7 addendum. One correction that came out of it: the silent fallback goes to the
   **local filestore**, not the database, which is worse for a rebuild than previously stated
   here — see step 14.
3. **Odoo binds `0.0.0.0:8069`/`:8072`, not loopback.** ADR 0009 describes the nginx proxy
   *target* as `127.0.0.1:8069`, which is accurate but easy to misread as the bind address.
   Only the NSG prevents direct access, `ufw` is inactive, and the NSG is not in version
   control (step 4).
4. **`infra/bicep/main.bicep` cannot reproduce the deployed resources.** Its
   `uniqueString()`-derived names would give both the storage account and the Key Vault the
   same suffix; the real ones are `91a2e1` and `90a311`. It also omits `luxauto-app-subnet`
   (`10.20.3.0/24`), where the VM actually is. Deploying it into `luxauto-rg` would create
   parallel resources rather than adopt existing ones (step 2).
5. **The VM's managed identity has no ARM read access** — verified `AuthorizationFailed` for
   the VM, the Postgres server and the VNet. Correct least privilege, but it means no Azure
   fact in this runbook is recoverable from the VM (step 3).
6. **A fourth non-stock systemd unit pair exists that ADR 0020 does not mention:**
   `luxauto-expire-policies.service`/`.timer` (ADR 0019). Unlike the runner and the wrapper,
   these **are** in version control (`infra/systemd/`), and the installed copies are
   byte-identical to the repo's. Installation is still manual (step 17a).
7. **The `odoo` Postgres role password and Odoo master password exist only in
   `/etc/odoo/odoo.conf`.** Key Vault holds the *admin* role's password, which is a different
   credential. Unplanned VM loss means resetting the role (step 9).
8. **Leftover artifacts from hand-edits:** `/etc/odoo/odoo.conf.bak.20260812153144`,
   `/etc/odoo/odoo.conf.bak.20260812203626`, and
   `/opt/odoo-custom-addons/luxauto.bak.20260812203529` (a stale copy of `luxauto_policy`
   from the ADR 0012 clone conversion). Harmless; do not recreate them.
9. **ADR 0009's opening paragraph says "five deviations"; the document contains seven.**
   Deviations 6 (certbot/`server_name`) and 7 (`server_environment_files`) were appended later
   and the intro was never updated.
10. **The "seven documented Odoo 19 deviations" are not referenced outside ADR 0009.**
    Checked directly: `Insurance_Industry_Guide.docx` and `Power_Energy_MGA_Manual.docx`
    contain **zero** occurrences of "deviation" or "Odoo"; `MGA_Software_Options.docx`
    mentions Odoo (12 times) but no deviations. ADR 0009 is the sole source, and this runbook
    traces all seven to it. Separately, and unrelated to rebuilds: all three
    `docs/reference-materials/*.docx` files are **plain UTF-8 text, not Word documents**,
    despite the extension.
11. **`deploy-vm.yml`'s checkout-step comment is known-inaccurate** — it describes "its
    `scripts/lib/smoke_test.py` payload", but the payload comes from the clone. ADR 0020's
    addendum records this as deliberately unfixed: this host's credential lacks the `workflow`
    scope, so nothing on the VM can edit `.github/workflows/`.
12. **`docs/runbooks/` is a new directory.** `docs/` previously held only `decisions/`,
    `reference-materials/` and `sample-renderings/`. This is the first runbook, and it
    introduces the convention the same way ADR 0015 introduced `scripts/`. The README's
    "Repo structure" block has been updated to list it — the one incidental change made
    outside this runbook and ADR 0020.

---

## Related documents

- [ADR 0008](../decisions/0008-azure-infra-provisioned.md) — the Azure layer that survives a VM rebuild
- [ADR 0009](../decisions/0009-odoo-installed-on-vm.md) — the Odoo install and all seven deviations
- [ADR 0011](../decisions/0011-pipeline-schema-reapplied.md) — why schema verification exists
- [ADR 0012](../decisions/0012-odoo-module-source-and-deployment.md) — the addons clone
- [ADR 0015](../decisions/0015-deployment-and-schema-automation.md) — both scripts
- [ADR 0019](../decisions/0019-nonrenewal-and-expiration.md) — the expire-policies timer
- [ADR 0020](../decisions/0020-cicd-automation.md) — the runner, sudoers, and the wrapper addendum
- [`infra/bicep/README.md`](../../infra/bicep/README.md) — what the Bicep does and does not cover
- [`infra/systemd/README.md`](../../infra/systemd/README.md) — timer installation
