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
