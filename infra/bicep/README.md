# Infrastructure — Bicep

Reproduces the Azure infrastructure documented in [`docs/decisions/0008-azure-infra-provisioned.md`](../../docs/decisions/0008-azure-infra-provisioned.md). Read that ADR first — it explains two real deviations from the ADR 0001/0002 plan (region restriction, extension allow-listing) that this template already accounts for.

## Deploy

Requires an existing resource group and an Azure identity with rights to create the resource types below.

```bash
az deployment group create \
  --resource-group luxauto-rg \
  --template-file main.bicep \
  --parameters postgresAdminPassword='<generate one - do not commit it, do not reuse the one from ADR 0008>'
```

All other parameters have defaults matching what's actually running (see the ADR). Override any of them with `--parameters key=value` as needed.

## What this deploys

- VNet + delegated subnet for Postgres Flexible Server
- Private DNS zone, linked to the VNet
- PostgreSQL Flexible Server (private/VNet-injected, no public endpoint) with the extension allow-list pre-configured
- Storage Account + `documents` blob container
- Key Vault (RBAC-authorized, empty — no secrets)

## What this deliberately does NOT deploy

- **Key Vault secret values.** Populate these out-of-band after deployment (see ADR 0008 for the Cloud Shell workaround this project needed, since Key Vault's data-plane API can't be reached from network-restricted environments like sandboxed CI). Never put real secret values in a template or a `.bicepparam`/parameters file that gets committed.
- **Any compute.** Odoo hosting (VM vs. App Service) is still an open decision — see the ADR's "Consequences / not yet done."
- **Role assignments** granting a compute identity access to the Key Vault — nothing to grant access to yet.

## Known constraints baked into the defaults

- `location` defaults to `eastus2`, not `eastus` — the subscription this was built against has `eastus` restricted for PostgreSQL Flexible Server. Check `az postgres flexible-server list-skus --location <region>` before assuming a different region works, and check `eastus` isn't restricted before assuming this default is overly conservative for you.
- Postgres network mode (private VNet vs. public with firewall) is fixed at creation — there's no post-deploy toggle. This template always deploys private/VNet-injected, matching ADR 0002's intent.
