# ADR 0014: Policy endorsements (premium/term adjustments)

**Status:** Decided; not yet implemented (DDL and Odoo module are follow-on work)
**Date:** 2026-08-12
**Follows from:** ADR 0007 (temporal-overlap gap on `program_participants`), ADR 0010 (deferred endorsements, `calculate_premium_waterfall()`), ADR 0013 (a second consumer of that same function)

## What this ADR decides

ADR 0010 modeled `policies` as issued and explicitly declined to model mid-term changes, flagging that an endorsement "almost certainly needs the same kind of temporal discipline `program_participants` currently lacks... except applied to a policy's own effective-dated fields." This ADR is that follow-on. It decides five things: the `policy_endorsements` table shape, what's in scope for v1 versus deferred, how to close ADR 0007's temporal-overlap gap for this new table rather than repeat it, how endorsements feed the audit trail, and how an endorsement's premium impact flows through the existing waterfall calculation. It does not write DDL or Odoo module code - that's the next task.

## 1. `policy_endorsements`: a new, versioned table

**Decision: endorsements are their own rows, not mutations of the `policies` row.** Consistent with every other temporal record in this schema (`state_rating_table_versions`, `program_participants`), a change is a new row with its own `effective_range`, not an edit to an existing one. This preserves the full history of what changed, when, and why - a mutated `policies` row would lose that the moment the next change overwrote it.

- `endorsement_id` - UUID PK, same convention as everywhere else.
- `policy_id` - UUID, `NOT NULL REFERENCES policies(policy_id)`. Unlike `policies.quote_id`, this is deliberately not `UNIQUE` - a policy can have many endorsements over its life.
- `effective_range` - TSTZRANGE NOT NULL. When this endorsement's terms apply.
- `endorsement_type` - a new enum, `endorsement_type_t`, declared alongside the schema's other enums: `('premium_adjustment', 'term_change')` for v1. Chosen as an enum rather than free text (the way `policy_events.event_type` deliberately is) because this field has a real, bounded, ADR-owned vocabulary from the start, the same reasoning behind `policy_status_t` and `participant_type_t` - not a growing audit log where new values get added informally. It will need extending when structural endorsements (section 2) are eventually built; that's expected, the same way every enum in this file is treated as living, not fixed.
- `premium_delta` - NUMERIC, nullable. Signed: positive for an additional-premium endorsement, negative for return premium. Nullable because a pure `term_change` endorsement may have no premium impact at all.
- `reason` - TEXT.
- `created_at` - TIMESTAMPTZ NOT NULL DEFAULT now().

No `updated_at` and no `set_updated_at()` trigger - an endorsement row, once written, doesn't get edited; a mistake gets corrected the way `decision_log` and `policy_events` already handle corrections, with a new row, not an update.

**Decision: `policy_endorsements` gets the same no-update/no-delete trigger pattern as `decision_log` and `policy_events` - a `BEFORE UPDATE OR DELETE` trigger rejecting both outright.** The exclusion constraint (section 3) and the append-only trigger guard against two different failure modes, not the same one: the exclusion constraint stops a *conflicting* write - a new or edited row whose `effective_range` overlaps another endorsement on the same policy. It does nothing to stop a silent `UPDATE policy_endorsements SET premium_delta = ... WHERE endorsement_id = ...` that changes an otherwise-valid row's `reason` or `premium_delta` in place, with no overlap and therefore nothing for the constraint to catch. That's a real gap the constraint alone leaves open, and it's exactly what `decision_log`'s and `policy_events`' triggers exist to close for their own tables. This table is audit-relevant in the same way those two are - it's the record of what changed on a policy and why - and the marginal cost of the trigger (one more controlled correction path instead of a direct `UPDATE`) is small next to the value of not being the one exception to a pattern this schema otherwise applies consistently. Section 3 names the correction mechanism this requires.

## 2. Scope: premium/term adjustments only. Structural endorsements are a named, deferred gap

**Decision: v1 handles `premium_adjustment` and `term_change` only. Structural endorsements - adding a vehicle, changing coverage - are explicitly out of scope, not attempted here.**

The reason this can't be a quick follow-on extension of the same table: `vehicles` and `coverage_requested` are currently scoped to `applications`, not `policies` (`schemas/db/postgresql_schema.sql`'s `applications` section - vehicles and coverage are part of what was applied for, referenced by `application_id`). A structural endorsement - add a car to an in-force policy - needs an answer to a question this project hasn't asked yet: does a bound policy get its own copy of vehicles/coverage (versioned the way this ADR versions endorsements), or does it keep pointing at the application's, with endorsements layered as diffs against that? That's a real schema-design decision, not a detail to settle inside this ADR as an afterthought - exactly the mistake ADR 0010 avoided by naming endorsements as a gap instead of quietly under-building them. Named here for the same reason, with the same discipline: a follow-on ADR should own it, once it's actually needed.

## 3. Closing ADR 0007's temporal-overlap gap now, not deferring it again

**Decision: an exclusion constraint on `policy_endorsements`, same `btree_gist` pattern as `state_rating_table_versions`:**

```
EXCLUDE USING gist (policy_id WITH =, effective_range WITH &&)
```

ADR 0007 shipped `program_participants`' 100%-sum check *without* this discipline and flagged it explicitly as a known, tracked gap - "a program whose participant panel changes over time... isn't yet protected against a gap or overlap." That gap is still open. This ADR doesn't fix ADR 0007's table, but it does refuse to introduce a second table with the identical shape of problem when the fix is a well-established, already-proven pattern in this exact file. Two endorsements on the same policy can never have overlapping `effective_range`s - enforced at the database level, not by application logic that could silently miss a case, the same rationale `state_rating_table_versions`' own constraint comment gives.

This table has no `superseded_by` column the way `state_rating_table_versions` does for closing out a version. Correcting a mistaken endorsement needs the same shape of fix that table uses - shrink the mistaken row's `effective_range` upper bound (a write, not a delete) before a corrected row's range can be inserted without tripping the exclusion constraint - but now that `policy_endorsements` is append-only (section 1), that shrink is itself an `UPDATE` the table's own trigger would reject.

**Decision: this correction path is a named function, `correct_policy_endorsement(p_endorsement_id UUID, p_new_effective_range TSTZRANGE, p_new_endorsement_type endorsement_type_t, p_new_premium_delta NUMERIC, p_new_reason TEXT, p_performed_by TEXT)`, not freeform SQL left for whoever implements this to invent.** Naming it as a real function - the same instinct behind `bind_policy()` and `cancel_policy()` rather than raw multi-statement SQL in a server action - makes the correction a controlled, single path every caller goes through, instead of each future caller re-deriving its own version of "how do I fix an endorsement" and risking a slightly different (or slightly wrong) sequence each time. Its shape, as a single transaction:

1. Temporarily disable `policy_endorsements`' `BEFORE UPDATE` trigger, close the original row's `effective_range` upper bound to the new endorsement's effective start, then re-enable the trigger - the same disable/act/re-enable pattern already used live (not just described) when cleaning up `policy_events` test data during this project's own testing sessions, now promoted from an ad hoc operational step to a real, reusable function.
2. Insert the corrected `policy_endorsements` row with the new values.
3. Insert a `policy_events` row, `event_type = 'endorsement_corrected'`, `performed_by`, with `notes` referencing both the original and corrected `endorsement_id`s - so the audit trail shows a correction happened and links the two rows, rather than the corrected row appearing to be an unrelated, unexplained new endorsement.

All three steps in one transaction, `SECURITY DEFINER` with a pinned `search_path`, same reasoning as `bind_policy()`/`cancel_policy()`: `odoo` has no direct grant on `policy_endorsements` or `policy_events`, only on the read-side views, and this function is the controlled gateway that lets it write without widening that grant.

## 4. Every endorsement writes a `policy_events` row

**Decision: inserting a `policy_endorsements` row and inserting a `policy_events` row (`event_type = 'endorsed'`) happen in the same transaction - same atomicity discipline as bind and cancel (ADR 0010 section 4).**

`policy_events` was built to be extended this way - ADR 0010 said as much ("will eventually need to log endorsement events too once that follow-on ADR lands... extends `policy_events`, not `decision_log`'s already-settled shape"). This is that extension. Whatever server action creates an endorsement is not a default ORM save, for the same reason bind and cancel aren't: it's two tables changing together, and a stray endorsement insert without its audit event would leave the same kind of inconsistency ADR 0010's write discipline exists to prevent.

## 5. How `premium_delta` flows through the waterfall: the core function gains an overload; a thin sibling function resolves an endorsement into a call to it

**Decision: `calculate_premium_waterfall` gains a second signature - `calculate_premium_waterfall(p_program_id UUID, p_amount NUMERIC, p_as_of TIMESTAMPTZ)` - containing the actual arithmetic. The existing `calculate_premium_waterfall(p_quote_id UUID)` is refactored into a thin wrapper that looks up a quote's `program_id`/`premium_amount`/`quoted_at` and delegates to the new overload. A new sibling function, `calculate_endorsement_waterfall(p_endorsement_id UUID)`, resolves an endorsement's policy → quote → `program_id`, and its own `premium_delta`/`effective_range` lower bound, then delegates to the same overload. The per-participant math itself is written exactly once.**

The task framed this as a choice between an overload and a sibling function; the answer is both, composed, and that composition is the point. The actual gross/commission/net arithmetic - `amount * share_percentage`, less `commission_rate` - has nothing to do with whether the amount came from a quote's `premium_amount` or an endorsement's `premium_delta`. Parameterizing the core function on a raw `(program_id, amount, as_of)` makes that explicit: it's the same calculation either way, so it's the same function body either way. `calculate_premium_waterfall(p_quote_id)` and `calculate_endorsement_waterfall(p_endorsement_id)` exist as two convenience entrypoints - each resolves a different kind of row into the three raw inputs the shared calculation actually needs - but neither reimplements the math. This is the direct continuation of ADR 0010's own principle ("Single source of truth... both read this function rather than each re-deriving the math") applied to a third caller, not a second, subtly different implementation living next to the first. A sibling function that independently joined `program_participants` and recomputed the same formula would be exactly the "two copies of the truth" problem ADR 0010 built this function to avoid in the first place - it would just be avoiding it for two callers and reintroducing it for a third.

Two design details worth naming as deliberate, not incidental:

- **The `as_of` date for an endorsement is its own `effective_range` lower bound, not the original quote's `quoted_at`.** `program_participants` changes over time; the panel active when a policy was originally quoted may not be the panel active when a later endorsement takes effect. Splitting an endorsement's premium delta among whoever was on the program *at endorsement time* is the correct read of "who's owed a share of this specific change," and it's a natural consequence of parameterizing on `as_of` rather than hardcoding `quoted_at` into the shared function.
- **A negative `premium_delta` (return premium) needs no special-casing.** The formula is linear in `amount`, so a negative amount produces proportionally negative `gross_share`/`commission_amount`/`net_due` for every participant automatically. This is a direct benefit of choosing "raw signed amount" as the shared function's parameter instead of something that assumes a positive premium.
- `calculate_endorsement_waterfall` is only meaningful when `premium_delta IS NOT NULL` - a pure `term_change` endorsement has nothing for it to compute. Whatever calls it (a future settlement-report extension, most likely) needs to skip endorsements with a null `premium_delta`, not call the function and expect a sensible empty result.

## Consequences

- `policy_endorsements` becomes the fifth table added since ADR 0005's original design, continuing the same living-document treatment of `postgresql_schema.sql`.
- `endorsement_type_t` is a new enum with a two-value v1 vocabulary that's known, in advance, to need extending - flagged here rather than presented as complete.
- The exclusion-constraint pattern this ADR reuses for `policy_endorsements` is now proven in two tables (`state_rating_table_versions`, and this one) - strengthens the case for eventually applying the same discipline to close ADR 0007's still-open gap on `program_participants`, though that remains a separate, not-yet-scheduled piece of work.
- `calculate_premium_waterfall`'s refactor into a wrapper-plus-overload is a signature change to an existing, already-shipped, already-consumed function - `luxauto_premium_waterfall_view` and `luxauto_settlement_view` (ADR 0010, ADR 0013) both call the one-argument form and need to keep working unchanged. **The implementation task must re-run both views' existing live tests after this refactor, not just test the new endorsement path** - this is a change to shared, load-bearing infrastructure, not a purely additive one.
- `policy_endorsements` is now append-only like `decision_log` and `policy_events`, and its one legitimate write path around that (`correct_policy_endorsement()`) is named and specified above rather than left to be invented ad hoc during implementation.
- Not yet decided, left for the implementation task: any Odoo-side view/model work (out of scope here the same way ADR 0010 kept DDL and Odoo module code out of its own first draft).

### Addendum: a function-ordering bug found (and fixed) while implementing this ADR

Implementing `calculate_endorsement_waterfall()` surfaced a real, pre-existing bug in the already-committed schema file, unrelated to this ADR's own design decisions but worth recording here since this is the work that found it. `LANGUAGE sql` functions are parsed and analyzed against the catalog at `CREATE FUNCTION` time - unlike `plpgsql`, which only checks syntax until a function is first called. `calculate_premium_waterfall`, `bind_policy`, and `cancel_policy` were positioned in the file *before* `quotes`, `policies`, and `policy_events` - the tables their bodies reference. That ordering had never actually been exercised against a genuinely empty database: every prior session tested it by applying incremental deltas to a `luxauto` database that already had those tables from an earlier full load, so the file's real, broken ordering was never caught.

This is the same category of risk ADR 0011 named - schema state that's silently assumed rather than verified - just surfacing on the "does this file even apply cleanly from scratch" axis instead of ADR 0011's "does the live database actually match what the file claims" axis. It doesn't introduce a new argument; it reinforces the one ADR 0011 already made for a repeatable, idempotent apply-and-verify script, which that ADR named as a known gap and explicitly left unbuilt.

Fixed by reordering: the waterfall/bind/cancel functions, and this ADR's own new functions, now live after `policy_events` instead of before `quotes`. Confirmed by actually doing what no prior session had done - applying the full schema file to a freshly created, genuinely empty database - and getting a clean apply, not by reasoning about it.
