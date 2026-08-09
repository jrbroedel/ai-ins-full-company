# ADR 0002: Cloud provider = Azure (not AWS or GCP)

**Status:** Decided (design phase — not yet implemented)
**Date:** 2026-08-09
**Supersedes:** the object-storage portion of ADR 0001, which named "S3-compatible object storage (S3 or self-hosted MinIO)" before this decision was made.

## Decision

Standardize infrastructure on Microsoft Azure. Amazon (AWS) and Google (GCP) are explicitly out of scope for this project - not evaluated on technical merit, this is a standing preference, not a cost/feature tradeoff.

Concretely, this replaces/resolves the open pieces of ADR 0001 as follows:

| Component | ADR 0001 said | Now |
|---|---|---|
| Database hosting | PostgreSQL (unspecified host) | **Azure Database for PostgreSQL - Flexible Server** |
| Document/object storage | "S3-compatible object storage (S3 or self-hosted MinIO)" | **Azure Blob Storage** |
| Odoo hosting | Not specified | **Azure VM or Azure App Service (Linux containers)** - to be decided when we get to actual deployment, not blocking now |
| Secrets (API keys, DB credentials, the PAT this project already uses for git) | Not specified | **Azure Key Vault**, once there's a running environment to wire it into - not applicable to this local git workflow today |

## Important technical implication: this is not a drop-in swap

ADR 0001 described object storage generically as "S3-compatible" specifically because that's a widely-supported protocol - MinIO, Wasabi, Backblaze, and AWS S3 itself all speak the same API, so code written against it is portable. **Azure Blob Storage does not speak the S3 API.** It has its own REST API and its own SDKs (`azure-storage-blob` for Python, etc.). This means:

- Any future code (Odoo customization, pipeline document-handling logic) needs to be written against Azure's Blob SDK, not a generic S3 client - there's no "just change the endpoint" option here.
- If a future third-party tool or library assumes S3 compatibility (some do, as a de facto standard), it may need an adapter or may not support Azure Blob directly - check this per-tool as they get selected, don't assume compatibility.
- Odoo itself does not have official first-party Azure Blob Storage support for its filestore - community modules exist for this but haven't been evaluated yet. This is new scoping work, not previously covered by the "custom quota-share module" estimate in ADR 0001.

## Consequences

- The database recommendation from ADR 0001 (PostgreSQL) is unaffected and reinforced - Azure Database for PostgreSQL is a first-party managed Postgres offering, no compatibility concern there.
- New, not-yet-scoped work: evaluating/selecting an Odoo-Azure Blob Storage integration approach (community module vs. custom filestore backend).
- Anywhere earlier documentation or code references "S3" or assumes S3 API compatibility, it should be read as superseded by this ADR - flag and correct on sight rather than treating as still-accurate.

## Alternatives considered and rejected

- **AWS (RDS for PostgreSQL + S3)** — rejected per standing preference, not evaluated on merits.
- **GCP (Cloud SQL for PostgreSQL + Cloud Storage)** — rejected per standing preference, not evaluated on merits.
- **Self-hosted MinIO on Azure VMs** (S3-compatible storage running on Azure compute rather than using Azure's native Blob Storage) — would preserve S3 compatibility while staying off AWS/GCP, but adds a service to operate and patch ourselves for no clear benefit over Azure's own managed Blob Storage. Worth revisiting only if a specific future tool turns out to hard-require the S3 API and lack an Azure-native alternative.
