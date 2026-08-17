# ADR 0008: Azure infrastructure provisioned per ADR 0001/0002

**Status:** Implemented
**Date:** 2026-08-09

## Decision

Provisioned the Azure infrastructure specified by ADR 0001 (PostgreSQL data layer) and ADR 0002 (Azure as cloud provider) into resource group `luxauto-rg`, subscription `ff1d4234-2dc1-476c-b350-ddabbc59c566`, tenant `2c7981fb-d0ee-46b6-a5c2-87aaa0a84d0b`. This ADR records what was actually built, including two deviations from the original plan forced by real-world constraints, so the Bicep template (`infra/bicep/main.bicep`) and this document stay the source of truth for anyone standing this environment up again.

## What was built

| Resource | Name | Region | Notes |
|---|---|---|---|
| PostgreSQL Flexible Server | `luxauto-pg` | **East US 2** | PostgreSQL 16, Burstable `Standard_B1ms`, 32GB storage, VNet-injected (no public endpoint) |
| Virtual Network | `luxauto-vnet-eus2` | East US 2 | `10.20.0.0/16` |
| Delegated subnet (Postgres) | `luxauto-pg-subnet` | East US 2 | `10.20.1.0/24`, delegated to `Microsoft.DBforPostgreSQL/flexibleServers` |
| Private DNS zone | `luxauto-eus2.postgres.database.azure.com` | global | Linked to `luxauto-vnet-eus2` |
| Storage Account | `luxautosa91a2e1` | East US | Standard LRS, TLS 1.2 minimum, public blob access disabled |
| Blob container | `documents` | — | Private access, lives in the storage account above |
| Key Vault | `luxauto-kv-90a311` | East US 2 | RBAC authorization model (not legacy access policies) |

## Deviation 1: East US, not East US 2, for the database

ADR 0001/0002 didn't pin a specific Azure region. `eastus` was the natural first choice (matches the resource group's default region), but the subscription returned `The location is restricted from performing this operation` when creating the PostgreSQL Flexible Server there — confirmed via `az postgres flexible-server list-skus --location eastus`, which showed `reason: "Provisioning is restricted in this region... open a support request with Issue type of 'Service and subscription limits'"` for every SKU. This is a subscription-level restriction, not anything wrong with the request.

Checked `eastus2`, `centralus`, `westus2`, `westus3`, `southcentralus` — all open. Picked **East US 2** for lowest latency to `eastus`.

**Consequence:** the storage account (`luxautosa91a2e1`) stayed in `eastus` since object storage wasn't subject to the same restriction and there was no reason to move it. Database and blob storage are therefore in different (adjacent) regions. This is a minor latency consideration for anything reading/writing both in the same request path — worth revisiting if it matters once real traffic patterns exist, but not a correctness problem.

**Action item:** if `eastus` capacity is actually needed later (e.g. to colocate with other `eastus` resources), open the Azure support ticket referenced in the error message rather than assuming the restriction is permanent.

## Deviation 2: Extension allow-listing required before schema load

`schemas/db/postgresql_schema.sql` opens with `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"` and `CREATE EXTENSION IF NOT EXISTS btree_gist`. Both are supported by Azure Database for PostgreSQL but are **not enabled by default** — Azure requires them to be explicitly allow-listed via the `azure.extensions` server parameter before `CREATE EXTENSION` will succeed. First schema-load attempt failed on both extensions (and cascaded into ~30 downstream errors — every `uuid_generate_v4()` default and the `btree_gist`-based exclusion constraint on `state_rating_table_versions` failed in turn).

Fix:
```bash
az postgres flexible-server parameter set \
  --resource-group luxauto-rg --server-name luxauto-pg \
  --name azure.extensions --value "UUID-OSSP,BTREE_GIST"
```
This is a dynamic parameter (no server restart required). After setting it, `DROP SCHEMA public CASCADE; CREATE SCHEMA public;` to clear the partial first attempt, then re-running `postgresql_schema.sql` succeeded cleanly end to end — all 19 tables, all indexes, all triggers, both extensions.

**Action item for the Bicep template:** set `azure.extensions` as part of server provisioning (a `Microsoft.DBforPostgreSQL/flexibleServers/configurations` sub-resource), not as a manual post-creation step, so a from-scratch deployment doesn't hit this the same way.

## Network access model

Postgres Flexible Server's network mode (private/VNet-injected vs. public with firewall rules) is **fixed at creation time** — there is no toggle to add public access to an already-VNet-integrated server, and no toggle to add VNet integration to a public one, without recreating the server. This matters operationally: any one-off admin task (loading the schema, running migrations) needs either (a) a machine already inside/peered to the VNet, or (b) a temporary jump-box VM inside the VNet, used and then deleted. Schema loading in this session used approach (b) — see the deployment log for the mechanics. There is currently no standing way to reach `luxauto-pg` except from inside `luxauto-vnet-eus2`.

## Key Vault contents

Secrets currently stored in `luxauto-kv-90a311` (names only — values are in the vault, not here or anywhere else in the repo):

- `postgres-admin-password` — rotated after the jump-box exercise, since the original was displayed in chat during setup
- `postgres-admin-username`
- `postgres-fqdn`
- `storage-account-name`
- `storage-account-key`

Access is RBAC-based. Currently only `joshua@broedel.net` (via the `Key Vault Secrets Officer` role, scoped to the vault) has data-plane access. Whatever identity ends up running the pipeline/Odoo in production will need its own role assignment here — not yet provisioned, since there's no running compute identity to grant it to.

## Consequences / not yet done

- **Odoo hosting** (VM vs. App Service) — still open per ADR 0002, tracked as the next infra decision.
- **Key Vault → running-service wiring** — nothing currently reads from the vault; it's populated but not yet consumed. Whatever hosts Odoo/the pipeline needs a managed identity granted `Key Vault Secrets User` (read-only; narrower than the `Secrets Officer` role used for setup) once that compute exists.
- **`azure.extensions` and other server-parameter configuration** should move into the Bicep template (see Deviation 2) so this isn't a manual step next time.
- The orphaned `eastus`-region VNet/subnet/DNS zone created during the first (failed) Postgres attempt were deleted; no cleanup debt there.
- The jump-box VM and all its resources (NIC, public IP, OS disk, NSG) used for schema loading were deleted after use; no standing compute exists in `luxauto-rg` right now beyond the Postgres server itself.

---

# Addendum: the Bicep template never described what was built, and is now a parallel-environment template instead (2026-08-16)

**Status:** Decided; implemented; **not deployed** (see "What is still unproven").
**Amends:** this ADR's framing of `infra/bicep/main.bicep` as something that keeps "this document the source of truth for anyone standing this environment up again."
**Not in scope:** compute, NSG rules, and identity/role assignments — excluded when this ADR was written because VM-vs-App-Service was still open, and still excluded now. ADR 0009 settled that question, but **the VM layer has never been expressed as IaC in any form**, and this addendum does not change that.

## What was found

`docs/runbooks/vm-rebuild.md` step 2 recorded that the template's generated names do not match the deployed resources. Re-derived live before acting on it, rather than trusting the runbook:

1. **The storage account and Key Vault cannot both have come from this template.** Both names derive from the *same* `uniqueString(resourceGroup().id)` expression, which by definition yields one value — so both suffixes must be identical. The live resources are `luxautosa**91a2e1**` and `luxauto-kv-**90a311**`. Different. Confirmed live from this host: the `storage-account-name` secret reads `luxautosa91a2e1`, and the Key Vault URL `luxauto-kv-90a311.vault.azure.net` is the one the managed identity successfully authenticates against. No parameter value reconciles this; the names were generated by hand before the template was written to describe them.
2. **A second naming mismatch, not previously flagged anywhere.** `vnetName` and `privateDnsZoneName` interpolated the raw `location` parameter, producing `luxauto-eastus2...`. The real environment uses the abbreviated region. Confirmed live rather than from the table above: `dig luxauto-pg.postgres.database.azure.com` resolves through `c5000dd43191.**luxauto-eus2**.postgres.database.azure.com`. The template would have created a differently-named zone.
3. **The template's VNet had one subnet; the real one has two.** Only the Postgres-delegated `10.20.1.0/24` was defined. Confirmed live from IMDS: this VM's NIC sits in `10.20.3.0/24` — the app subnet, absent from the template entirely. A VNet deployed from it had nowhere for compute to attach.
4. **`postgresAllowedExtensions` was already correct and was left alone.** Deviation 2's fix is genuinely implemented as a `configurations` sub-resource. Verified live: `pg_extension` on `luxauto-pg` lists `uuid-ossp 1.1` and `btree_gist 1.7`.

**The severity is not "the template is stale" but "the template is armed."** It compiled clean, and its own header instructed deploying it into `luxauto-rg` with default parameters. That deployment would have **succeeded** — creating a second VNet, DNS zone, Postgres server, storage account and Key Vault alongside the real ones, adopting nothing, failing nowhere. A template that is obviously broken is harmless; one that silently doubles infrastructure is worse than having no IaC at all.

## The decision: a parallel-environment template, not a description of production

Two options were considered. **Rejected: an `existing`-reference template** that names the real resources for lookup. It cannot create anything, so it could never serve the one piece of named future work this project has for IaC — and it would duplicate what this ADR's own table and the runbook's step 2 already record in prose, in a form that cannot be run. Its only advantage would be accuracy about production, which documentation already provides.

**Chosen: make it a genuinely safe parallel-environment template.** `vm-rebuild.md` closes by naming, as still-outstanding work, standing up a parallel VM with its own identity and "almost certainly a copy" of the database, and executing the runbook against it end to end. That is the only thing that converts the runbook from a careful reconstruction into a verified procedure. A deployable data-layer template is the half of that work expressible as IaC, so it serves real named work rather than being tidy for its own sake.

**What changed:**

- **`baseName` has no default and is now required.** This is the load-bearing safety property: the header's old command (`--parameters postgresAdminPassword=...`) can no longer run at all — it fails on the missing parameter instead of deploying into production's resource group. Verified against the compiled ARM: `baseName` and `postgresAdminPassword` are the only parameters without a `defaultValue`. It is capped at 12 characters so derived names stay inside Azure's 24-character limits, and the header's example uses `luxauto-test` into `luxauto-test-rg`.
- **A `locationAbbreviation` parameter**, used in the VNet and DNS zone names, fixing mismatch 2. Deliberately a parameter rather than a lookup table: Azure publishes no canonical abbreviation list, and a table would silently produce a wrong name for any region missing from it.
- **The app subnet is defined**, fixing gap 3, so a parallel VM has somewhere to attach. **No VM, and no NSG** — adding subnets is this file's existing territory; adding compute is not.
- **Subnets are referenced by `resourceId()` rather than `subnets[0].id`**, so adding or reordering a subnet cannot silently repoint the Postgres delegation at the wrong one — a bug the previous single-subnet form could not have, and the new two-subnet form could.
- **Storage and Key Vault name construction was corrected for Azure's rules**, which the old form violated for any `baseName` containing a hyphen: storage account names are alphanumeric-only, so hyphens are stripped, and both suffixes are truncated so a 12-character `baseName` still fits under 24.
- **The header comment was rewritten** to state plainly what the file is, what it is not, that it cannot describe or adopt production, and that it has never been deployed. `infra/bicep/README.md` was rewritten to match.

## What is still unproven, stated plainly

**This template has never been deployed, and I could not deploy it.** The host it was written on has no `az` CLI installed, no Azure credentials, and its managed identity is scoped to `Key Vault Secrets User` only — a `PUT` for a new resource group returns `AuthorizationFailed` on `Microsoft.Resources/subscriptions/resourcegroups/write` (attempted; the group was not created). The same limitation would have blocked verifying the rejected `existing`-reference option, since a what-if needs ARM read the identity also lacks. So the choice between the two was made on value, not on which could be tested.

What *was* verified, which is real but is not deployment:

| Check | Result |
|---|---|
| `bicep build` (compile + type check) | clean, exit 0 |
| `bicep lint` | clean, exit 0 |
| `baseName` genuinely required | confirmed in compiled ARM — no `defaultValue` |
| Region abbreviation reaches both names | confirmed in compiled ARM expressions |
| App subnet present, undelegated; pg subnet still delegated | confirmed in compiled ARM |
| Postgres references the subnet by `resourceId`, not index | confirmed in compiled ARM |
| Derived names obey Azure length/charset rules at the 12-char boundary | checked against storage (≤24, alphanumeric, letter-initial), Key Vault (≤24) and Postgres server rules |

**The remaining step, and it is the one that matters:** deploy into a new disposable resource group, confirm it comes up with no collisions and outputs that resolve, then delete the group and confirm from `az group list` that it is gone. Until someone with Contributor on the subscription runs that, this is an untested template — better-reasoned than the one it replaces, and unproven in exactly the same way. The commands are in `infra/bicep/README.md`; note the Key Vault has soft-delete enabled, so a full teardown needs `az keyvault purge` as well as the group delete.

**This does not make the VM reproducible.** The data layer is now expressible as IaC; the VM, its NIC, its public IP, its NSG, the managed identity and the Key Vault role assignment are not, and remain prose in `vm-rebuild.md`. That gap is unchanged by this addendum and should not be read as narrowed by it.

---

# Addendum: the template is now deployed and torn down, closing the open item above (2026-08-17)

**Status:** Verified. This closes the "What is still unproven" section of the 2026-08-16 addendum, whose "remaining step" was exactly this deploy-and-teardown. That section is left standing as the accurate record of what was true on 2026-08-16; this addendum supersedes its "not deployed" status rather than editing it away.

The 2026-08-16 addendum ended by naming the one thing it could not do — deploy the template into a disposable resource group, confirm it, then tear it down with no residue — and explained why (the host had no `az` CLI and its managed identity had no ARM write). That was run on 2026-08-17 from `joshua@broedel.net`'s account, confirmed **Owner at subscription scope** via `az role assignment list` before starting.

**Rehearsed before deploying.** `az deployment group validate` and `az deployment group what-if` were both run first and came back clean; the what-if showed **exactly 9 resources, all Create, nothing else touched** — so production was confirmed outside the blast radius before anything was created.

**Deployed.** `az deployment group create` into a fresh, disposable `luxauto-test-rg` with `baseName='luxauto-test'`: provisioning state **Succeeded**, 12m57s, all 9 resources created (VNet with both subnets, private DNS zone + link, Postgres flexible server + extensions config, storage account + blob service + `documents` container, Key Vault).

**The two naming fixes were confirmed in a real deploy, not just in compiled output** — which is the thing the 2026-08-16 verification explicitly could not reach:

- **Region abbreviation (`eastus2` → `eus2`):** the `privateDnsZoneName` and `vnetName` outputs both showed the abbreviated form (`luxauto-test-eus2…`).
- **Hyphen-stripping for a hyphenated `baseName`:** the `storageAccountName` output was `luxautotestsaq2h2upfo` — hyphen gone, inside the 24-char limit.

**Live checks against the running resources, not just deployment output:**

| Check | Result |
|---|---|
| Postgres network privacy | `publicNetworkAccess: Disabled`, state `Ready`, correct delegated subnet and DNS-zone link |
| `azure.extensions` actually applied | server parameter reads `UUID-OSSP,BTREE_GIST` (Deviation 2's fix, live) |
| Both subnets present | `10.20.1.0/24` (pg) and `10.20.3.0/24` (app) with correct prefixes |
| Storage lockdown | `allowBlobPublicAccess: false`, `minimumTlsVersion: TLS1_2` |

**Torn down completely, verified rather than assumed.** `az group delete --yes`, then `az group exists` returning **false** (not trusted from the delete's exit code). The Key Vault's soft-delete was handled separately: confirmed present via `az keyvault list-deleted`, purged via `az keyvault purge`, confirmed gone via a second `list-deleted` returning empty. Final sweep: `az group list` showed only `luxauto-rg` remaining, and `az resource list` filtered for `test` in the name returned nothing anywhere.

**What this proves, and what it does not.** It proves the template deploys cleanly and tears down completely under the parameters actually used — `baseName='luxauto-test'`, default region and SKU. It does **not** prove every parameter combination works, and nothing here should be read as broader coverage than that single run. The template needed **no code changes** — it deployed exactly as written; this is a status update, not a fix.

**Still unchanged:** the VM layer remains outside IaC, exactly as the 2026-08-16 addendum's closing paragraph states. A working data-layer template does not narrow that gap.
