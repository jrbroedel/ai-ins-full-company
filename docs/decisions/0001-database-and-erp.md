# ADR 0001: Data layer = PostgreSQL, ERP/front-end = Odoo Community

**Status:** Decided (design phase — not yet implemented)
**Date:** 2026-08-08

## Decision

- **Data layer:** PostgreSQL, with object storage for documents (PDFs, appraisals, loss runs, engineering reports) — only pointers/metadata for documents live in Postgres, not the files themselves. **Cloud provider and specific object storage service decided separately in ADR 0002** (Azure Database for PostgreSQL + Azure Blob Storage) — this ADR's PostgreSQL rationale below is unaffected by that choice.
- **ERP / front-end:** Odoo Community Edition (AGPL, self-hosted, free).

These two decisions were made together because they're coupled, not independently.

## Why together, not separately

Odoo Community requires PostgreSQL. ERPNext (the other open-source candidate) runs on MariaDB. Picking the database first without considering the front-end risked locking in a choice that would either force running two databases in production or silently rule out one of the ERP options. Choosing both at once avoids that trap.

## Why PostgreSQL for the data layer

- The schemas already built (application intake, state rating table registry, referral matrix) are semi-structured: some fields need real relational integrity (policy IDs, driver-to-vehicle links, commission math), others are inherently variable (state-specific rating variables). Postgres `JSONB` columns give schema flexibility exactly where needed, without giving up relational integrity everywhere else — avoids running a document DB and a relational DB in parallel and syncing them.
- The state rating table registry's versioning (`effective_date` / `superseded_by`, never re-rating an in-flight quote against a newer version) maps directly onto Postgres range types with exclusion constraints — the database can enforce non-overlapping active periods per state, rather than that being application logic that can silently break.
- The AI governance decision log (required in substance by NY DFS Circular Letter 2024-7 and Colorado C.R.S. §10-3-1104.9) is a natural append-only table. Postgres handles high-volume insert-only audit logs well and gives transactional guarantees that a decision-log write and the quote/bind action succeed or fail together.
- Mature, boring, well-understood technology for a workload where financial correctness matters more than raw scale.

## Why Odoo over ERPNext

| | Odoo Community | ERPNext |
|---|---|---|
| License cost | $0, self-hosted | $0, self-hosted |
| Database | PostgreSQL | MariaDB |
| Insurance starting point | Some (third-party commission apps exist as a base) | Closer to a blank slate |
| Quota share (premium/risk/commission split across carriers) | Not native — custom module required | Not native — custom Doctypes required |
| Customization language | Python/XML | Python (Frappe) |
| Ecosystem for hired help | Larger | Smaller |

Quota share is genuinely MGA-specific and isn't supported out of the box by any open-source option researched — that cost is the same either way. The deciding factor was the database match: building on Postgres from day one lets the ERP's data model and the pipeline's data model live in the same database, which matters for an underwriting system where the front-end needs to read live pipeline decisions (referral status, computed flags) without a sync layer between two different databases.

## Alternatives considered and rejected

- **ERPNext** — rejected on the database mismatch above, not on capability. Would be a reasonable choice if Postgres weren't already the pick.
- **BindHQ / AIM / mPACS** (purpose-built MGA platforms) — support quota share natively, which is their real advantage, but run $4,200–$6,900+/month with a 10+ user minimum, demo-only with no trial or self-hosted option. Rejected primarily on cost relative to a platform where the differentiated value is meant to live in the AI pipeline, not the ERP layer. Worth revisiting only if the custom quota-share build in Odoo proves substantially harder than estimated.
- **Custom-built lightweight system** (e.g. Django/Node + Postgres from scratch) — would give the most control over quota-share modeling but means building document management, invoicing, and general ERP functionality from zero. Rejected in favor of not reinventing what Odoo already provides for free.

## Known cost not yet fully scoped

Quota-share modeling and the invoice/commission extension in Odoo were estimated in prior research as a few weeks of focused development for someone familiar with the framework — real work, not configuration. This has not been re-scoped against the actual referral matrix and state rating registry built in this project; treat the estimate as directional.

## Consequences

- Hosting (Postgres + Odoo + object storage) becomes real infrastructure to stand up and maintain — not covered by this ADR.
- The workflow pipeline (schemas, referral matrix, rating logic) was deliberately built database-agnostic and UI-agnostic up to this point specifically so this decision could be made independently of it. No pipeline artifact currently assumes Postgres or Odoo; integration work is still ahead.
- Odoo customization work (quota share, insurance-specific Policy/Insured/Premium objects, Excel import mapping) is a new build stream not yet started.
