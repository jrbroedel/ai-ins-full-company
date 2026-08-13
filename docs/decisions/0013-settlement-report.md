# ADR 0013: Capacity-provider settlement report

**Status:** Decided; not yet implemented (SQL view and Odoo module are follow-on work)
**Date:** 2026-08-12
**Follows from:** ADR 0007 (named this report as an open item, scoped the waterfall shape), ADR 0010 (`policies`, `policy_events`, `calculate_premium_waterfall()`)

## What this ADR decides

ADR 0007 named "a capacity-provider settlement report - the bordereau-equivalent artifact... built from `quotes` joined to `program_participants` for a given period" as scoped-but-unbuilt. ADR 0010 then built the pieces that report needs (`policies`, `policy_events`, `calculate_premium_waterfall()`) without placing the report itself. This ADR decides three things: what "period" means for this report, what's in scope for a first version versus deferred, and what the report actually is as a build artifact. It doesn't write the SQL view or Odoo module - that's the next task.

## 1. Period definition: bind date, not `effective_range`

**Decision: the settlement period filters on the `policy_events` row where `event_type = 'bound'` (its `created_at`), not on `policies.effective_range`.**

These answer different questions. `effective_range` answers "is this policy currently in force" - the question a Policy view or an underwriter checking coverage status needs answered. A settlement report answers a different question: "how much premium did this program write in this period, and what's owed to each participant on it." That's when the transaction happened, not when coverage happens to be active. The Energy manual's premium bordereau (ADR 0007's own reference point) is a writing-period ledger for exactly this reason - a policy bound March 15th with a March 1st effective date settles in March's bordereau because that's when it was written, not backdated to when its coverage technically started.

Practically, this also keeps the report simple to reason about: `effective_range` is a range that can be later modified by cancellation (ADR 0010's cancel action closes its upper bound), so filtering on it would make a policy's presence in a past settlement period retroactively dependent on something that happens after that period closes. The bind event's timestamp is set once, by `bind_policy()`, and never changes - a stable anchor for "which period does this belong to."

## 2. Scope: all policies bound in the period, cancellation status aside

**Decision: the report includes every policy whose bind event falls in the period, regardless of what its current status is - including policies since cancelled. Return-premium and cancellation adjustments are explicitly out of scope, deferred to a follow-on decision.**

This is the same move ADR 0010 made for endorsements: name the gap on purpose instead of quietly under-building past it. A policy bound on day 5 of a period and cancelled on day 20 of that same period (or later) still counts as written premium for settlement purposes in the period it was bound - but this report, as decided here, does not net out or reverse anything for that cancellation. The net-due figures it reports are `calculate_premium_waterfall()`'s numbers computed from `quotes.premium_amount`, which doesn't change when a policy is cancelled - there's no return-premium calculation anywhere in the schema yet. A capacity provider reading this report for a period with mid-period cancellations would see gross figures that overstate what's actually still owed, once return premium is accounted for.

Not solving that here, for the same reason ADR 0010 didn't solve endorsement versioning inline: return-premium calculation (pro-rata? short-rate? does the MGA's own commission get clawed back proportionally?) is a business/actuarial decision this project hasn't made, not a technical one waiting on schema. Building a plausible-looking adjustment now would risk it passing as more resolved than it is. The report's `policy_status` column (see below) at least makes a cancelled policy's presence visible to whoever's reading the report, rather than silently indistinguishable from an active one.

## 3. Output: `luxauto.settlement`, a filtered list view - no bespoke PDF/QWeb report

**Decision: a new `_auto = False` Odoo model, `luxauto.settlement`, backed by a new SQL view (`luxauto_settlement_view`) joining `policies` to its bind event in `policy_events` and to `calculate_premium_waterfall(quote_id)` - same `CROSS JOIN LATERAL` pattern `luxauto_premium_waterfall_view` already uses, same reason (one waterfall calculation, read by every consumer, never reimplemented). The Odoo list view exposes a bind-date field with a period filter, using Odoo's native search/filter UI. No custom PDF or QWeb report template.**

This is a new view, not a reuse of `luxauto_premium_waterfall_view`: that view is keyed off every quote with a program, bound or not, and has no notion of a bind date to filter on. This one is specifically scoped to bound policies, joined through their bind event - a different question needs a different view, the same reasoning ADR 0010 used to keep the Insured/Policy/Waterfall views as three views instead of one overloaded one. The `id` column follows the same composite-hash convention `luxauto_premium_waterfall_view` uses (this view also fans out to one row per participant per policy), hashed from `policy_id` + `participant_id`.

The period filter itself lives entirely in Odoo's UI layer, not baked into the SQL view: the view returns every bound policy's settlement row across all time, and a `bind_date` field on the model - included in the list's search view - gets Odoo's standard date-filter widgets for free (period presets, custom ranges) once it's declared as a filterable field. No custom filtering logic needs to be written; this is exactly what a Date/Datetime field in a `<search>` view already does.

**Why no bespoke report template:** a bordereau, in the Energy manual's own usage and in market practice generally, is a structured data extract - rows a capacity provider imports into their own settlement/accounting process - not a branded, formatted document meant to be read and filed like a policy declarations page. Odoo's native list-view export (CSV/XLSX) already produces exactly that shape, and it does it for free: every column the view exposes is exportable without a second place having to maintain a matching column list. A QWeb PDF template would be exactly that second place - the same "two copies of the truth" problem ADR 0010 avoided for the waterfall math itself, just recurring one layer up, in the report's presentation instead of its arithmetic. If a real requirement for a formatted, presentation-quality document ever shows up (a specific DOI filing format, something a capacity provider's contract requires look a certain way), that's a concrete, separable decision to make then - not something to build speculatively now against a requirement that doesn't exist yet.

## Consequences

- `luxauto_settlement_view` becomes the fourth Odoo-facing view (after `luxauto_insured_view`, `luxauto_policy_view`, `luxauto_premium_waterfall_view`) and the second to depend on `calculate_premium_waterfall()` rather than just projecting columns - reinforcing that function as the shared source of truth ADR 0010 designed it to be, now serving two different consumers exactly as ADR 0010 anticipated.
- Return-premium/cancellation adjustment is now a named, tracked gap - like ADR 0010's endorsements and ADR 0007's temporal-overlap gap, it needs its own follow-on decision before this report is safe to treat as a final settlement figure rather than a gross-written ledger.
- No new write path is introduced - this is a read-only report over data `bind_policy()`/`cancel_policy()` already produce. Nothing about ADR 0010's write discipline changes.
- Not yet decided, left for the implementation task: the exact `luxauto_settlement_view` column list beyond what's implied above, and whether `luxauto.settlement`'s access rights follow the same `base.group_user` read-only pattern as the other three models or need a narrower group (settlement data is arguably more sensitive than a policy list) - worth a deliberate look during implementation, not assumed here.

---

# Addendum: endorsements and return premium in the settlement view (2026-08-13)

**Status:** Decided; implemented
**Amends:** section 2's deferral ("return-premium and cancellation adjustments are explicitly out of scope") and section 1's period definition, which now applies per transaction rather than per policy.
**Companion:** ADR 0018's addendum, which answers the other half of the pair this work closed - whether endorsements need closing out at cancellation.

## What the view actually showed before this

Checked against the deployed SQL rather than the ADR text: `luxauto_settlement_view` was `policies` joined to its `bound` event, `CROSS JOIN LATERAL calculate_premium_waterfall(p.quote_id)`. One row per policy per participant, amounts derived entirely from `quotes.premium_amount`.

So the gap was **two-part, not one**. Section 2 named the cancellation half and tracked it. The endorsement half was never named here at all - ADR 0014 built `calculate_endorsement_waterfall()` and left it in exactly the unintegrated position ADR 0013 had left return premium in, and nothing since connected it. A capacity provider reading this report saw neither a mid-term premium increase they were owed a share of, nor a refund they owed a share of.

## The fix

**Decision: the view is a union of three transaction legs - `premium`, `endorsement`, `return_premium` - each carrying `transaction_type` and `transaction_date`, one row per participant per transaction.**

Each leg delegates to the waterfall entrypoint that already exists for it (`calculate_premium_waterfall(quote_id)`, `calculate_endorsement_waterfall(endorsement_id)`, `calculate_cancellation_waterfall(cancellation_id)`), so the per-participant arithmetic is still written exactly once, in the shared `(program_id, amount, as_of)` core. This view adds no math.

**Decision on the filter basis: each transaction is dated by its own recording timestamp - the `bound` event for premium, `policy_endorsements.created_at` for an endorsement, `policy_cancellations.created_at` for a refund - not by the bind date of the policy they belong to, and not by their own effective dates.**

This is section 1's reasoning applied to transaction types that did not exist when it was written. Section 1 chose the bind event over `effective_range` for two reasons: settle a transaction in the period it *happened*, and anchor on a timestamp that is set once and never moves. Both point the same way here. A refund recorded in November belongs in November's settlement, because November is when the carrier actually owed it - dating it to the policy's original bind date would post a refund into a period that closed months earlier, and dating it to the cancellation's *effective* date would let a later correction move it between periods, which is exactly the retroactive instability section 1 rejected `effective_range` for.

`bind_date` stays on every row - it still says which policy the transaction belongs to and when that policy was written - but it is no longer what the period filter runs on. The Odoo model gains `transaction_type` and `transaction_date`, the search view's period filter moves to `transaction_date`, and Bind Month survives as a grouping.

**Superseded records are excluded from both new legs.** An emptied endorsement or cancellation applied for zero time (ADR 0016 addendum 3, ADR 0018 section 6), so it was never owed to anybody. The consequence, stated rather than hidden: correcting a cancellation **restates** the period its corrected record falls in rather than posting a reversing entry in the current one. That is what a correction is for in this schema - the corrected record replaces the original outright - but it does mean a closed settlement period's totals can change if someone corrects a transaction inside it. A reversing-entry ledger is a bigger accounting decision than this addendum makes.

A pure `term_change` endorsement carries no `premium_delta` and contributes no settlement row - the same condition ADR 0014 section 5 already documented for when `calculate_endorsement_waterfall()` is meaningful.

## Consequences

- The report is no longer a gross-written ledger; it is a net position per participant per period. Section 2's warning that "a capacity provider reading this report for a period with mid-period cancellations would see gross figures that overstate what's actually still owed" no longer applies.
- The `id` hash now includes the source transaction's own UUID and its type, since a policy/participant pair can now legitimately appear on three rows. Same composite-hash convention, wider input.
- New columns are appended after the original ones rather than placed where they read best: `CREATE OR REPLACE VIEW` cannot reorder or rename existing columns, and dropping the view to tidy the order would drop its grants on every apply.
- No new database objects - the view count, function count and every other ADR 0015 baseline number are unchanged.
- Still out of scope and still deferred: an Odoo read-side view over `policy_cancellations`, reinstatement, and the reversing-entry question above.
