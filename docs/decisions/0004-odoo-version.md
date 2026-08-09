# ADR 0004: Odoo version = 19.0

**Status:** Decided
**Date:** 2026-08-09

## Decision

Build against **Odoo Community 19.0**, the current stable branch.

## Rationale

| Version | Released | Support ends (approx.) | Fit for a new build starting now |
|---|---|---|---|
| 17.0 | 2023 | November 2026 | Rejected - support window closes in ~3 months from this decision. Starting a new project on a version about to lose bugfix/security support makes no sense. |
| 18.0 | October 2024 | ~October 2027 | Viable, but strictly less runway than 19.0 with no offsetting advantage for a greenfield build. |
| 19.0 | September 2025 | ~2027-2028 | **Selected.** Longest support runway of any stable branch, and it's the current stable release, not a bleeding-edge/master branch. |
| 20.0 | Not yet released (experimental/master only) | N/A | Rejected - not a stable release; building against a moving master branch is an unnecessary risk for a project with no urgency to be on the newest code. |

Odoo follows an annual release cycle (each version gets roughly 3 years of bugfix/security support). Because this project is a from-scratch build with no existing customizations to migrate, there's no cost to starting on the newest stable branch and every reason to - it maximizes time before a forced upgrade, without the instability of building against an unreleased/master version.

## Direct dependency this resolves

ADR 0003 (Odoo Azure Blob Storage integration) named "confirm `fs_attachment`/`fs_storage` version compatibility with whatever Odoo version we deploy" as an open verification item. That's now answerable: OCA's [storage](https://github.com/OCA/storage) project has an active `19.0` branch, so the recommended module in ADR 0003 has direct version support here - no compatibility gap between this decision and that one.

## Consequences

- Any future OCA or third-party module evaluated for this project should be checked for a `19.0` branch/release specifically, not assumed compatible from an older version's listing (the `attachment_azure` module ruled out in ADR 0003 is a cautionary example - stale at `9.0` with no newer release).
- Custom module development (quota-share, Policy/Insured/Premium objects, the Azure Blob integration) should target Odoo 19.0's API and ORM conventions.
- Revisit this decision only if a specific 19.0 blocker turns up during implementation - not on a fixed schedule.
