# Infrastructure — Bicep

Deploys a **parallel copy** of this project's data layer into a fresh resource group. Read
[`docs/decisions/0008-azure-infra-provisioned.md`](../../docs/decisions/0008-azure-infra-provisioned.md)
and **its 2026-08-16 addendum** first — the ADR explains two real deviations this template
accounts for, and the addendum explains why this template cannot describe the running
production environment.

## What this is for

The follow-up [`docs/runbooks/vm-rebuild.md`](../../docs/runbooks/vm-rebuild.md) names and does
not do: stand up a parallel environment and execute that runbook against it end to end, so the
rebuild procedure stops being a reconstruction nobody has run. This template is the data-layer
half of that.

## What this is NOT

**It does not describe the live environment, and deploying it can never adopt, import or
update those resources.** The live resources were created by hand and their names do not match
what this template generates — most decisively, `luxautosa91a2e1` and `luxauto-kv-90a311` have
different random suffixes, while every name here derives from a single `uniqueString()` call
that by definition produces the same suffix for both. No parameter value makes this template
reproduce them.

Until 2026-08-16 this README and the template's header both told you to deploy into
`luxauto-rg` with default parameters. That would have **succeeded**, silently creating a
second disconnected set of resources beside the real ones. `baseName` now has no default
precisely so that command fails instead of running.

## Deploy

Into a **new, empty resource group** — never `luxauto-rg`:

```bash
az group create --name luxauto-test-rg --location eastus2

az deployment group create \
  --resource-group luxauto-test-rg \
  --template-file main.bicep \
  --parameters baseName='luxauto-test' \
               postgresAdminPassword='<generate one - do not commit it, do not reuse ADR 0008's>'
```

A new resource group is not just tidiness: the storage account and Key Vault names derive from
`uniqueString(resourceGroup().id)`, so a distinct group is what keeps those globally-unique
names from colliding with anything existing.

Tear down with `az group delete --name luxauto-test-rg --yes`, then confirm with
`az group list -o table` rather than trusting the command's exit code. Note the Key Vault has
soft-delete enabled, so the name stays reserved until purged (`az keyvault purge`).

## What this deploys

- VNet + **two** subnets: the Postgres-delegated subnet and an application subnet (where a VM
  would attach — no VM is created)
- Private DNS zone, linked to the VNet
- PostgreSQL Flexible Server (private/VNet-injected, no public endpoint) with the extension
  allow-list pre-configured
- Storage Account + `documents` blob container
- Key Vault (RBAC-authorized, empty — no secrets)

## What this deliberately does NOT deploy

- **Any compute.** ADR 0009 settled VM-over-App-Service, but the VM layer has never been
  expressed as IaC in any form — no VM, NIC, public IP or NSG. The app subnet is somewhere for
  one to attach; it is not one. `vm-rebuild.md` step 2 remains the only description of the VM,
  and it is prose.
- **NSG rules.** Out of scope here, and a parallel environment needs its own reviewed against
  runbook step 4 before anything is exposed.
- **Role assignments** granting a compute identity access to the Key Vault — a parallel
  environment needs its own, per runbook step 3.
- **Key Vault secret values.** Populate out of band (see ADR 0008). Never in a template or a
  committed parameters file.
- **The `infra-artifacts` container.** The live account has one holding the pinned Odoo `.deb`
  (ADR 0009's Deviation 1 addendum). A parallel environment should install from that real
  artifact rather than get an empty container of its own.

## Status: deployed clean and torn down completely (2026-08-17)

`bicep build` and `bicep lint` pass, the required-parameter behaviour was verified against the
compiled ARM, and the derived names were checked against Azure's length and character rules at
the `maxLength` boundary — and, as of 2026-08-17, **this template has been deployed against the
live subscription and torn down again, with zero residue and zero production impact.**

`az deployment group validate` and `what-if` were run first (what-if showed exactly 9 resources,
all Create, nothing else touched), then `az deployment group create` into a fresh
`luxauto-test-rg` with `baseName='luxauto-test'`: provisioning state Succeeded, all 9 resources
created. Live checks against the running resources — not just deployment output — confirmed
Postgres `publicNetworkAccess: Disabled` with the correct delegated subnet and DNS-zone link,
`azure.extensions` actually reading `UUID-OSSP,BTREE_GIST` on the server, both subnets present
at `10.20.1.0/24` and `10.20.3.0/24`, and the storage account with `allowBlobPublicAccess: false`
and `minimumTlsVersion: TLS1_2`. The outputs showed the abbreviated region form
(`luxauto-test-eus2…`) and the hyphen-stripped storage name (`luxautotestsaq2h2upfo`), confirming
those two naming fixes in a real deploy rather than only in compiled output. Teardown was
`az group delete` confirmed by `az group exists` returning false, plus `az keyvault purge` for
the soft-deleted vault confirmed gone by a follow-up `list-deleted`; a final `az group list` left
only production. See ADR 0008's 2026-08-17 addendum.

This proves the template under the parameters actually used — `baseName='luxauto-test'`, default
region and SKU. It does not separately exercise every parameter combination.

## Known constraints baked into the defaults

- `location` defaults to `eastus2`, not `eastus` — the subscription this was built against has
  `eastus` restricted for PostgreSQL Flexible Server. Check
  `az postgres flexible-server list-skus --location <region>` before assuming a different region
  works.
- `locationAbbreviation` is a **separate parameter** and must correspond to `location`. Azure
  publishes no canonical abbreviation list, and the live environment uses `eus2` for `eastus2`.
  An earlier version interpolated the raw location and would have produced
  `luxauto-eastus2.postgres.database.azure.com` where the real zone is `luxauto-eus2...`.
- `baseName` is capped at 12 characters so the derived storage account and Key Vault names stay
  inside Azure's 24-character limits. Bicep cannot regex-validate a parameter, so a pathological
  value (e.g. one ending in a hyphen) will fail loudly at deploy time rather than being rejected
  up front.
- Postgres network mode (private VNet vs. public with firewall) is fixed at creation — there is
  no post-deploy toggle. This template always deploys private/VNet-injected, matching ADR 0002's
  intent.
