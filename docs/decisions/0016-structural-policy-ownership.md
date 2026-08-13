# ADR 0016: Structural policy ownership (vehicles and drivers)

**Status:** Decided; implemented
**Date:** 2026-08-13
**Follows from:** ADR 0014 (deferred structural endorsements pending this decision), ADR 0006 (Odoo read-side view pattern), ADR 0012 (`bind_policy()`, `SECURITY DEFINER` pattern), ADR 0015 (idempotent schema conventions, apply-and-verify script)

## What this ADR decides

ADR 0014 built premium/term endorsements and explicitly declined to handle structural changes - adding or removing a vehicle, adding or removing a driver - because that required deciding whether a bound policy owns its own vehicle/driver records or keeps pointing at the application's, which keeps changing (a new draft, a correction) after the policy is already in force. That decision is made here: **a bound policy owns its own snapshot.** This ADR decides five things: what counts as "structural" for this table (narrower than "everything that isn't premium/term"), how the snapshot gets created, the shape of the two new tables, how a mistaken snapshot row gets corrected, and where this leaves the Odoo side. It also documents what's still deliberately not built.

## 1. Scope: vehicles and drivers only - `coverage_requested` stays under ADR 0014

**Decision: "structural" means `vehicles` and `additional_drivers` - a change in *how many* things are insured. `coverage_requested` (limits, deductibles) is not structural and stays under ADR 0014's existing `premium_adjustment`/`term_change` endorsement machinery.**

The distinction is cardinality, not subject matter. `coverage_requested` is single-valued per application (one row) - raising a liability limit or changing a deductible is a change to an existing value, exactly the shape `endorse_policy()` already handles via `premium_delta` and `reason`. `vehicles` and `additional_drivers` are multi-valued (zero or more rows) - adding a vehicle isn't editing a value, it's a new row appearing where none was, and removing one is a row's coverage ending while others continue. That's a different problem: `policy_endorsements`' exclusion constraint is scoped *per policy* (at most one active endorsement at a time), which is correct for "the policy's premium right now" but would be wrong for vehicles - a policy legitimately has multiple concurrently-active vehicles, so a per-policy exclusion constraint would reject the second car outright. This ADR's tables are scoped differently for exactly this reason (section 3).

## 2. The snapshot happens in `bind_policy()`, not a new function

**Decision: `bind_policy()` (ADR 0012) is extended, not duplicated, to copy the application's `vehicles` and `additional_drivers` rows into the new policy-owned tables in the same transaction as everything else it already does.** Same reasoning ADR 0010 gave for keeping bind atomic in the first place: the policy, its quote status flip, its audit event, and now its vehicle/driver snapshot are one unit - a bind that created a policy with zero vehicles because the snapshot step lived in a separate, un-atomic call would be exactly the kind of partial state ADR 0010's write discipline exists to prevent. `bind_policy()`'s signature doesn't change; only its body grows.

**What this does and doesn't cover:** the snapshot happens once, at bind time. It does not give a bound policy a way to gain or lose a vehicle or driver *after* bind - that's a genuine structural endorsement action (the mid-term "customer added a car" case), and it's still deferred. What's decided here is *where a bound policy's vehicles and drivers live* and *how the initial set gets there*; a follow-on ADR still owns *how a bound policy's vehicle/driver set changes mid-term*. Naming this now rather than letting the scope quietly expand to cover it: `correct_policy_vehicle()`/`correct_policy_driver()` (section 4) fix a *mistaken snapshot*, they are not a general add/remove mechanism for a policy already in force.

## 3. `policy_vehicles` and `policy_drivers`: shaped like `policy_endorsements`, scoped differently

**Decision: two new tables, versioned rows with `effective_range`, an exclusion constraint, and an append-only trigger - the same three-part discipline `policy_endorsements` established. The exclusion constraint's equality scope is *not* per-policy, unlike `policy_endorsements` - it's per `(policy_id, vin)` for vehicles and per `(policy_id, name, date_of_birth)` for drivers, so that legitimately concurrent vehicles/drivers on the same policy don't conflict with each other.**

Both tables mirror their source table's columns (minus `application_id`, which becomes `policy_id` plus a `source_vehicle_id`/`source_driver_id` traceability reference back to the original `vehicles`/`additional_drivers` row this snapshot came from) rather than a curated subset - a policy's "own" vehicle record that's missing fields the application's had would be a worse record, not a simpler one, and there was no principled way to decide which fields don't matter without guessing at a future requirement.

`name`+`date_of_birth` as the driver natural key, per the option the task itself named: `additional_drivers` has no SSN or license-number column to key off instead (only `name`, `relationship_to_applicant`, `date_of_birth`, and driving-history fields), so this is what's actually available, not an arbitrary choice among several good options.

**A limitation flagged on purpose, not hidden - since closed, see the addendum below:** both `vin` (on `vehicles`) and `date_of_birth` (on `additional_drivers`) are nullable at the application-data-entry stage - a vehicle without a confirmed VIN yet, or a driver record entered without a birth date. Postgres exclusion constraints treat `NULL` as distinct from `NULL` (not equal), so two vehicles on the same policy that both have a null `vin` - or two drivers that both have a null `date_of_birth` - would **not** be caught as a conflict by these constraints; the protection is real when the identifying field is present and silently absent when it isn't. Same category of gap as ADR 0007's non-temporal 100%-sum check and the still-open `program_participants` overlap gap it flagged: real, worth naming, not worth blocking this ADR on solving (would need a business decision - require VIN/DOB before bind? treat null as its own bucket that still conflicts with itself? - this ADR doesn't make that call).

*The addendum makes that call: the snapshot tables' identity columns are `NOT NULL`. The business decision turned out to be one this project had already made and written down (referral rule DH-04) - see below.*

## 4. Corrections: `correct_policy_vehicle()` and `correct_policy_driver()`, mirroring `correct_policy_endorsement()` exactly

**Decision: both functions follow `correct_policy_endorsement()`'s pattern precisely - close the mistaken row's `effective_range` upper bound (disabling the table's append-only `UPDATE` trigger for that one statement, then re-enabling it immediately), insert a corrected row, log a `policy_events` row referencing both IDs. Never mutate a row in place.**

Both take every snapshot column as an explicit parameter (not a partial-update or JSONB-merge shape) - the same choice `correct_policy_endorsement()` made, for the same reason: a correction function that could only fix some fields would leave the others silently uncorrectable, and there's no principled subset to pick without guessing which fields will turn out to be the ones that were wrong.

## 5. Odoo: read-side views, not yet a correction UI

**Decision: `luxauto_policy_vehicle_view` and `luxauto_policy_driver_view` (ADR 0006 pattern - `_auto=False`, hashed-`md5` `id`), backed by `luxauto.policy.vehicle` and `luxauto.policy.driver` in the existing `luxauto_policy` module, read-only, same `base.group_user` access level as `luxauto.insured`/`luxauto.policy`** - not the narrower `luxauto_policy.group_settlement_viewer` group, since vehicle/driver data isn't the commission/financial information that group exists to gate.

Unlike `luxauto.policy`'s "Cancel Policy" button, these two views don't get a wizard wired to their correction functions in this ADR - that wasn't asked for here, and adding one without being asked would be scope creep the same shape this project has repeatedly avoided elsewhere. The functions exist and are callable (by a future wizard, or directly); the UI for triggering them is a separable follow-on, the same way ADR 0010 separated "the table exists" from "the server action exists" and both were still real, deliberate steps.

The `id` hash for both views is a simple single-column hash (`policy_vehicle_id`/`policy_driver_id` alone) rather than the composite hash `luxauto_premium_waterfall_view`/`luxauto_settlement_view` need - those views fan out to multiple rows per source key (one row per participant), these don't (one row per `policy_vehicles`/`policy_drivers` row, already a unique key on its own).

## Consequences

- `policy_vehicles` and `policy_drivers` are the sixth and seventh tables added since ADR 0005 (after `policies`, `policy_events`, `policy_endorsements`, and the two from ADR 0006/0007) - same living-document treatment of `postgresql_schema.sql` continues, now via the idempotent conventions ADR 0015 established rather than the ordering-hazard-prone style earlier tables were first written in.
- `bind_policy()`'s body grows to do more in one transaction; its signature and every existing caller are unchanged.
- Two more `SECURITY DEFINER` functions (`correct_policy_vehicle()`, `correct_policy_driver()`) follow the exact template `correct_policy_endorsement()`/ADR 0012 established - `odoo` gets `EXECUTE`, never a direct grant on the tables themselves.
- `scripts/apply-and-verify-schema.sh`'s baseline (ADR 0015 section 2) needs updating for the new tables/functions/views/triggers - the parser re-derives the object list from the file automatically, but the manually-verified acceptance-test counts are a fact about the file's current state and have to be updated by hand each time the file changes, the same maintenance ADR 0015 already implied every future schema change would carry.
- Mid-term structural changes (add/remove a vehicle or driver on an already-bound policy) remain explicitly deferred, same as ADR 0014 left endorsements before this ADR resolved the ownership question - this ADR resolves *where the data lives and how the initial snapshot happens*, not *how it changes after bind*. A follow-on ADR still owns that.
- ~~The `vin`/`date_of_birth` nullability gap in both exclusion constraints is a known, named limitation, not a hidden one - revisit if/when null identifying fields on policy-owned vehicles/drivers turn out to be a real operational problem, not before.~~ **Closed by the addendum below** (2026-08-13, same day): `policy_vehicles.vin`, `policy_drivers.name` and `policy_drivers.date_of_birth` are `NOT NULL`, and `bind_policy()` refuses an application carrying a null identity with a named condition. It didn't need the business decision this bullet was waiting on - that decision already existed as referral rule DH-04.

---

# Addendum: closing the null-identity gap (2026-08-13)

**Status:** Decided; implemented
**Amends:** section 3's named limitation and the last consequence above
**Scope:** identity columns on the two snapshot tables only. Return premium on cancellation, `expired`/`nonrenewed` transitions, and the commission formula are all still open, all still elsewhere.

## Why this is an addendum and not ADR 0017

Because no new architectural decision is being made. The rule "an application missing a VIN or a driver's identity fields cannot be rated or bound" already exists in this repo, in `referral-matrices/luxury_auto_referral_matrix.json`, as rule **DH-04** (`DH04_INSUFFICIENT_DATA_FOR_RISK_COMPUTATION`): a submitted application with a null `vin` or missing driver identity routes to `INFORMATION_REQUEST`. Section 3 above framed the null hole as needing a business decision that hadn't been made ("require VIN/DOB before bind?"). That framing was wrong on the facts: the decision had been made, written down, and given a reason code. What was missing was enforcement at the layer that depends on it.

The gap was therefore never "we don't know the rule." It was the same shape as the gaps ADR 0011 and ADR 0015 exist to close: a guarantee assumed to have happened upstream, trusted rather than checked, at exactly the point where being wrong is expensive. This project's pattern is to encode business rules as hard stops - `SECURITY DEFINER` functions the `odoo` role can only reach through, append-only triggers, exclusion constraints, a schema verifier that refuses to trust its own parser. A nullable identity column on a table whose *entire* protection is keyed on that column is a convention, not a hard stop.

## The fix, at two layers

**Layer 1 - `NOT NULL` on `policy_vehicles.vin`, `policy_drivers.name`, `policy_drivers.date_of_birth`.** This is the actual fix. It closes the exclusion constraints' null hole without special-casing the constraints themselves (a `NOT NULL` column can't be `NULL <> NULL`), and it holds for *any* writer to these tables - `bind_policy()` today, whatever mid-term structural-endorsement mechanism the deferred follow-on ADR eventually builds, and any hand-written correction run by an operator at 2am. `policy_drivers.name` was already `NOT NULL` from the original ADR; it's included in the migration for completeness, not because it changed.

The source tables (`vehicles.vin`, `additional_drivers.date_of_birth`) stay nullable, deliberately. A draft application *should* be able to exist without a VIN - that's the state DH-04 is written to detect. The constraint belongs on the policy-owned snapshot, where the data is no longer a draft.

**Layer 2 - named bind conditions.** `bind_policy()` checks the application's vehicles and drivers *before* the `policies` INSERT and raises `BIND_BLOCKED_MISSING_VEHICLE_VIN` or `BIND_BLOCKED_MISSING_DRIVER_IDENTITY`, each with a `HINT` naming DH-04 and what to fix. Layer 1 alone would reject the same bind with `null value in column "vin" of relation "policy_vehicles" violates not-null constraint` - correct, and useless to whoever hit it, since it describes a table the caller never mentioned and gives no hint that the fix is on the *application*. Same reasoning ADR 0012 gave for checking quote status explicitly even though the `UNIQUE` constraint on `policies.quote_id` would have caught a double-bind anyway: the constraint is the guarantee, the explicit check is the diagnosis. Reason-code style matches the referral matrix's so a human hitting one can grep for it.

The two correction functions get the same named check for the same reason - they're the other writer to these tables, and a correction that blanked a VIN would otherwise hit the raw `NOT NULL` *after* the old row's `effective_range` had already been closed inside the same transaction.

**Ordering note:** the check runs before anything is written, so a blocked bind leaves nothing behind - no policy, no `policy_events` row, no partial snapshot, and the quote stays `issued`. Verified, not assumed (see below).

## Migration

`postgresql_schema.sql` declares the columns `NOT NULL` in the `CREATE TABLE` bodies, but those are `CREATE TABLE IF NOT EXISTS` - on a database that already has the tables, the new constraint would be silently skipped. A guarded `DO` block does the real work: it counts existing null-identity rows first and, if it finds any, raises with the counts and a `HINT` rather than applying. It will not backfill a placeholder VIN or delete rows to make itself apply - these are insurance records, and a schema file that quietly edits them to satisfy its own constraint is a worse outcome than a failed apply. On a database with no violating rows (including a fresh one) the block is a no-op, `SET NOT NULL` being idempotent.

`luxauto` had zero rows in both tables when this was applied - checked, not assumed, and the guard was tested against a deliberately introduced null row anyway, since "there was no data this time" is not a property of the migration.

## Consequences

- `scripts/lib/verify_schema.py` grows a sixth verified category, `not_null_columns`: it parses the file's explicit `ALTER TABLE ... SET NOT NULL` statements and checks `information_schema.columns` for each. This extends ADR 0015 section 2's contract, which covered tables/types/functions/views/triggers - object *existence*. This addendum's whole deliverable is a column constraint applied by an `ALTER`, so "the table exists" verifies nothing about it, and an unverified constraint is exactly the "clean exit code assumed as proof" failure ADR 0015 exists to prevent. Inline `NOT NULL`s in `CREATE TABLE` bodies stay out of scope - covered by the table's own check, and parsing column definitions would be a real parser, not a regex.
- The baseline moves by one category only (`not_null_columns: 3`); no tables, types, functions, views or triggers were added.
- `bind_policy()`'s signature is still unchanged - three ADRs running.
- DH-04 now has enforcement at two layers with no coordination between them: the pipeline routes incomplete applications to `INFORMATION_REQUEST`, and the database refuses the bind regardless of whether that routing happened. That redundancy is the point.
- The `program_participants` overlap gap that section 3 name-checked as the same category of problem is **still open** - this addendum closes one instance, not the class.
