# ADR 0010: Policy, insured, and premium/waterfall model

**Status:** Decided; not yet implemented (DDL and Odoo module are follow-on work)
**Date:** 2026-08-12
**Follows from:** ADR 0006 (Odoo read/write pattern), ADR 0007 (`insurance_programs` / `program_participants` and the commission waterfall shape)

## What this ADR decides

`quotes` can already reach `status = 'bound'`, but nothing downstream of that exists yet: there's no table representing the bound policy itself, no Odoo-visible "insured" or "policy" concept, and no defined home for the waterfall math ADR 0007 scoped but didn't place. This ADR decides four things: the shape of a new `policies` table, the three Odoo read-side views needed to expose insureds/policies/premium waterfalls per the ADR 0006 pattern, where the waterfall calculation itself lives, and which policy-lifecycle actions require explicit Odoo server actions rather than default ORM save. It does not decide endorsements (see below) and does not write DDL or Odoo module code - that's the next task.

## The `policies` table

A new table, added conceptually to the same section of `schemas/db/postgresql_schema.sql` as `quotes`:

- `policy_id` - UUID PK, same convention as every other table in the schema.
- `quote_id` - UUID, `NOT NULL UNIQUE REFERENCES quotes(quote_id)`. A policy is always the result of binding exactly one quote, and the `UNIQUE` constraint enforces that one-to-one relationship at the database level, not just by convention.
- `policy_number` - TEXT. The carrier-assigned/admitted-market policy number. Numbering scheme (sequential, carrier-prefixed, etc.) is a business decision outside this ADR's scope, same pattern ADR 0007 used for deferring the profit-commission formula.
- `effective_range` - TSTZRANGE, matching the convention already established by `insurance_programs.effective_range` and `program_participants.effective_range`. Consistency here matters because the waterfall view (below) joins across all three.
- `status` - enum: `active`, `cancelled`, `expired`, `nonrenewed`. Matches the lifecycle states a bound policy actually goes through; deliberately does not include a `bound` state - that transition happens on the *quote* (`quotes.status = 'bound'`), and the policy row's existence is what "bound" means downstream.
- `created_at` / `updated_at` - TIMESTAMPTZ, `set_updated_at()` trigger, same as every other table.

### Endorsements are explicitly out of scope

This table models the policy as issued. It does not attempt to represent mid-term changes (added vehicles, coverage changes, premium adjustments effective mid-term) - that's an endorsement, and endorsements need their own ADR. The reason to call this out now rather than let it surface later: an endorsement almost certainly needs the same kind of temporal discipline `program_participants` currently lacks (ADR 0007's flagged gap - no overlap-aware validation), except applied to a policy's own effective-dated fields, and possibly needs to decide whether an endorsement is a new row (versioned history) or a mutation of the existing policy row with an audit trail elsewhere. Deciding that now, as an afterthought inside this ADR, would be the same mistake ADR 0007 avoided by flagging its temporal gap explicitly instead of quietly under-building it. A follow-on ADR should own that decision.

## Odoo read-side views (ADR 0006 pattern)

Three `_auto = False` Odoo models, each backed by a SQL `VIEW`, each deriving its display-only `id` via the hashed-md5-to-32-bit-int trick ADR 0006 established. None of these are writable through Odoo's default form save - see the server-actions section below for the paths that do write.

1. **Insured view** - joins `applicants` + `applications`. Gives underwriters/brokers a single insured-facing record (who they are, their current application(s)) without duplicating applicant data into Odoo's own tables.
2. **Policy view** - joins `policies` + `quotes` + `applications`. Surfaces policy number, status, effective range, and the premium/rating context that produced it. Deliberately a three-table join, not four - it does not also join `applicants` for a display name, since a user can navigate from the policy to its application and from there to the insured view. Reaching for the applicant name directly here would duplicate a join path the Insured view already owns; if that turns out to be a real usability gap, it belongs in Odoo view/UX design, not a wider database view.
3. **Premium/Waterfall view** - joins `quotes` + `program_participants`, with a per-participant net-due figure. This is the one view that requires computed logic rather than a plain join, which is exactly the case ADR 0006 didn't cover and this ADR resolves in the next section.

## Where the waterfall math lives: a SQL function, not an Odoo computed field

**Decision: the gross-to-net waterfall calculation is a SQL function in `schemas/db/postgresql_schema.sql`, alongside the existing `check_program_shares_sum_to_100()` function in the quota-share section ADR 0007 added. The Premium/Waterfall Odoo view selects from this function; it does not reimplement the arithmetic itself.**

Concretely: something in the shape of a function taking a `quote_id` (or `program_id` + gross premium) and returning one row per `program_participant` with its net-due amount, computed from `quotes.premium_amount`, `program_participants.share_percentage`, and `program_participants.commission_rate`.

The reason this can't live as an Odoo computed field, the way Odoo would normally do it: ADR 0007 already named a second consumer of this exact calculation - "a capacity-provider settlement report - the bordereau-equivalent artifact." If the math lives in Odoo Python (a computed field or report method), the bordereau report either duplicates that logic or has to round-trip through Odoo to get it, which reintroduces the "two copies of the truth" problem ADR 0006 rejected for the read-side views generally. Putting it in the database means the Odoo view and any future bordereau report - Odoo-based or not - read the same function and can never disagree about a net-due figure.

### What this function does and doesn't resolve

It computes net-due from the fields the schema currently has: `share_percentage` and a single flat `commission_rate` per participant. It does **not** resolve the layered retail-broker / wholesale-broker / MGA-commission waterfall the Energy manual's Ch.10 diagram shows (quoted in ADR 0007) - the current schema doesn't yet break commission into those tiers, and `profit_commission_formula` remains the free-text placeholder ADR 0007 already flagged as pending underwriting/finance sign-off. This ADR doesn't re-litigate that open item; it just decides where the calculation goes once those inputs are real. The function should be written so that plugging in a real profit-commission formula later is a change to the function body, not a new place the math has to be re-homed.

## Server actions: binding and cancelling

Per ADR 0006, any state change that matters is an explicit Odoo server action calling into controlled write logic - not a field a user edits and Odoo auto-saves. Two actions are in scope here, and both need an audit trail entry - which raises the question flagged (not resolved) in the first draft of this ADR: does that entry go in `decision_log`?

### Audit trail: a new `policy_events` table, not a widened `decision_log`

**Decision: policy lifecycle events get their own append-only table, `policy_events`, rather than extending `decision_log` to cover them.**

- `event_id` - UUID PK.
- `policy_id` - UUID, `NOT NULL REFERENCES policies(policy_id)`.
- `event_type` - TEXT (e.g. `'bound'`, `'cancelled'`).
- `performed_by` - TEXT, same convention as `decision_log.decided_by` - `'system'` or a specific user identifier.
- `notes` - TEXT, optional.
- `created_at` - TIMESTAMPTZ NOT NULL DEFAULT now().

Same append-only discipline as `decision_log`: a `BEFORE UPDATE OR DELETE` trigger rejecting both operations, so a policy's event history can only be added to, never rewritten - a mistaken entry gets corrected with a new row referencing the old one in `notes`, exactly the pattern `decision_log` already established.

**Why a new table instead of widening `decision_log`:** `decision_log` is shaped around one specific thing - a referral rule firing (or not) against an *application*, recorded with `rule_id` and `action_taken` against `referral_action_t`. A bind or cancel isn't a rule firing and doesn't have a `rule_id`; forcing it into that shape would mean either inventing fake rule IDs for non-rule events or making `rule_id`/`action_taken` nullable and conditionally meaningful, which weakens the one column (`action_taken`) that table's own append-only guarantee is built to protect. It also mixes two different audiences and lifecycles - underwriting referral history belongs to an application from intake through decisioning; policy lifecycle history belongs to a policy from bind through cancellation/expiry, and will eventually need to log endorsement events too once that follow-on ADR lands. Keeping them separate means the endorsement ADR extends `policy_events`, not `decision_log`'s already-settled shape. Both tables can and should follow the same append-only trigger pattern without being the same table.

### Bind (quote → policy)
Triggered from the Policy/Quote view, not a form save. Effects, as a single transaction:
1. Insert a `policies` row (`quote_id`, `policy_number`, `effective_range`, `status = 'active'`).
2. Update the source `quotes` row to `status = 'bound'`.
3. Insert a `policy_events` row (`policy_id` of the row just created, `event_type = 'bound'`, `performed_by`).

This can't be a default ORM save because it isn't an edit to one record - it's the creation of a new `policies` row coupled to a status transition on a different table and an audit event, and all three must succeed or none do. A stray edit to a quote's status field alone (without the corresponding policy row and event) would leave the tables inconsistent in exactly the way ADR 0006's write discipline exists to prevent.

### Cancel (policy)
Triggered from the Policy view, not a status-field edit. Effects, as a single transaction:
1. Update the `policies` row to `status = 'cancelled'`.
2. Close the upper bound of `effective_range` at the cancellation date, so the policy's active period reflects reality rather than the originally-issued term.
3. Insert a `policy_events` row (`policy_id`, `event_type = 'cancelled'`, `performed_by`, and typically `notes` for the cancellation reason).

A direct field edit could set `status = 'cancelled'` without touching `effective_range` or leaving any record of who cancelled it or why - silently wrong for anything downstream that reads `effective_range` (the waterfall view among them), and unaudited besides. The server action is what keeps `policies` and `policy_events` consistent as one atomic change.

`expired` and `nonrenewed` are not given actions here - those are expected to be system-driven transitions (a scheduled process, or the outcome of a renewal decision made elsewhere), not something a user triggers from this view. Out of scope for this ADR; noted so the state isn't mistaken for orphaned. When those transitions are designed, they should write `policy_events` rows too, for the same reason bind and cancel do.

## Consequences

- `policies` becomes the third table-design addition since ADR 0005, after ADR 0006 (Odoo integration) and ADR 0007 (quota share) - same living-document treatment for `postgresql_schema.sql` applies.
- Two more Odoo views to build against the ADR 0006 pattern, plus a third (the waterfall view) that's more than a plain join - the first case in this project where a read-side view depends on a SQL function rather than just projecting columns.
- The waterfall function becomes a second piece of shared logic (after `check_program_shares_sum_to_100()`) that both Odoo and any future non-Odoo consumer (the bordereau report) depend on - reinforcing `postgresql_schema.sql` as the actual source of business logic, not just table shapes.
- Endorsements are explicitly deferred to a follow-on ADR, not silently dropped - the same discipline ADR 0007 used for its temporal-overlap gap; that follow-on ADR should extend `policy_events` for endorsement audit events, not `decision_log`.
- A fourth table, `policy_events`, joins `policies` as part of this ADR - a second append-only, no-update/no-delete table alongside `decision_log`, deliberately kept separate rather than widening `decision_log`'s referral-specific shape.
- Not yet decided, and intentionally left for the DDL/implementation task or later: the exact function signature for the waterfall calculation and `policy_number` numbering scheme.
