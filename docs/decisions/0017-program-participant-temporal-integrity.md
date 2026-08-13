# ADR 0017: Temporal integrity for `program_participants`

**Status:** Decided; implemented
**Date:** 2026-08-13
**Follows from:** ADR 0007 (created `program_participants` and flagged this gap), ADR 0010 (built the waterfall that reads it point-in-time), ADR 0014 (reused the exclusion-constraint pattern and named this table's gap as still open), ADR 0016 + addendum (closed the same category of gap on the policy side; its addendum explicitly left this instance open)
**Not in scope:** return premium on cancellation, `expired`/`nonrenewed` transitions, the `profit_commission_formula` computation - all still open, all still elsewhere. Nothing in ADR 0016 or its addendum is touched.

## What this ADR decides

ADR 0007 shipped `program_participants` with a temporal column and a non-temporal integrity check, and said so out loud: "a simplified, non-temporal version of the check... a program whose participant panel changes over time needs a more rigorous version before this is production-safe." ADR 0014 reused the pattern that would fix it and named the gap as still open. ADR 0016's addendum name-checked it again while closing the policy-side instance. This ADR closes it.

It decides four things: that this is a bug and not a feature request, how the 100%-sum rule is defined once time is real, what the overlap constraint is keyed on, and how a participant row gets superseded on a table that - unlike its policy-side siblings - cannot use their correction mechanism.

## 1. This is a missing constraint, not a missing feature

**Decision: `program_participants` already has a temporal model, and the code that reads it already depends on that model being sound. What's missing is enforcement, which makes this a bug fix.**

This was the question worth answering before writing anything, because the answer decides whether the work is legitimate at all. The evidence:

- `effective_range TSTZRANGE NOT NULL` has been on the table since ADR 0005/0007. It is not an optional or vestigial column.
- The read path is already point-in-time: `calculate_premium_waterfall(program_id, amount, as_of)` filters `pp.effective_range @> p_as_of`. Every consumer - the premium waterfall view, the settlement report (ADR 0013), endorsement waterfalls (ADR 0014) - reaches participants through it.
- ADR 0014 reasoned explicitly about panel changes over time when it chose an endorsement's `as_of`: "`program_participants` changes over time; the panel active when a policy was originally quoted may not be the panel active when a later endorsement takes effect."

So a panel that changes over time is a designed-for property of this schema, not a new capability being introduced here. Three behaviours were then confirmed against the live database before any code was written:

1. **A legitimate supersession was rejected.** Closing a reinsurer's row at 2026-07-01 and inserting its replacement made the old check sum 60 + 40 + 40 = 140% and fail - even though the panel totals exactly 100% at every actual instant. The non-temporal check did not merely fail to catch bad data; it actively blocked correct data, which is why no panel change had ever been possible.
2. **Two identical concurrent rows for one participant were accepted**, and `calculate_premium_waterfall` then paid that participant twice (2 x 50,000 on a 100,000 premium). This is precisely ADR 0016's bug shape - two active identity rows where the constraint keyed on that identity doesn't exist - on a different table.
3. **A gap was accepted.** A panel ending 2026-06-01 inside a program running to 2027-01-01 passed the check, and a quote written during the gap allocated 0 of 100,000 premium to anybody, silently.

None of these needs a business decision the way ADR 0016's null-identity question arguably did. "The risk on a program is 100% placed, and each participant appears once" is not a policy choice; it is what a quota-share program *is*.

**What is deliberately NOT built here:** a mechanism for *restructuring* a panel - adding a participant who wasn't there or removing one entirely. `correct_program_participant()` (section 4) supersedes an existing participant's row, the same scope `correct_policy_vehicle()` has. Adding or removing a participant mid-term is the direct analogue of the mid-term structural endorsement ADR 0016 deferred, and it is deferred here for the same reason: it needs its own decision about what happens to the shares of everyone else, which is a business question. The constraints added here will refuse an attempt, with a message that says why - which is the correct behaviour for something not yet designed, rather than silently allowing a half-built version of it.

## 2. The 100% rule, once time is real

**Decision: risk-bearing shares (`capacity_provider` + `reinsurer`) must total 100% at every instant of the program's own term. Not summed across all history, and not merely checked at version boundaries.**

The trickiest part of this ADR, and the reasoning matters more than the code:

**"At every instant" and "at each version boundary" turn out to be the same rule.** Shares are piecewise-constant in time - the set of active participants can only change where some row's range begins or ends. Between two adjacent boundaries the total is constant, so verifying every boundary point verifies every instant, using finitely many probes. There is no third option where they differ; the distinction the task raised dissolves once you notice the step-function shape.

The probe set is therefore: every `lower(effective_range)`, every `upper(effective_range)`, **plus the program term's own lower bound**. That last one is not decoration - without it, a panel that starts a month after the program does would never be probed during the uncovered month, and the gap would pass. Probes outside the program term are discarded (`term @> t`), which with `[)` semantics correctly excludes the term's own upper bound.

Two consequences follow from defining it this way:

- **Under 100% at a probe is a gap** - an instant where part of the risk is unplaced. The old check could not see this at all, because summing every row regardless of date hid it (finding 3 above).
- **Over 100% at a probe is the overlap case** - almost always an old row that wasn't closed when its replacement was added.

Both raise `PROGRAM_SHARES_NOT_100_AT_INSTANT` naming the instant and the total, because "this program is broken" without a timestamp is not actionable on a table whose whole point is that the answer varies by date.

**Corollary decision: a participant's `effective_range` must be contained in its program's `effective_range`** (`PROGRAM_PARTICIPANT_OUTSIDE_TERM`). This is what makes "every instant of the term" well-defined from both ends - without it, participation could extend past the program and the rule would have nothing to say about it, while the waterfall would happily pay out. A participant cannot bear risk when the program is not in force.

**The zero-participant escape is kept, in temporal form.** A program with no risk-bearing participants at all is not checked, so a program can be created before its panel is negotiated - the same allowance the original check's `total_share != 0` clause provided, and necessary for bootstrapping. What is no longer allowed is a program that has *some* panel with holes in it.

**The trigger stays `DEFERRABLE INITIALLY DEFERRED`, and this is load-bearing.** A real panel change is several statements - drop one participant to 25%, raise another to 75% - and is only coherent as a unit. Deferral is what lets the program sit at 85% mid-transaction and be judged once, at commit.

## 3. The overlap constraint is keyed on (program, participant name, role)

**Decision: `EXCLUDE USING gist (program_id WITH =, participant_name WITH =, participant_type WITH =, effective_range WITH &&)`.**

Scoped per participant, not per program - the same reason `policy_vehicles` is scoped per VIN rather than per policy (ADR 0016 section 3): multiple participants are legitimately concurrent on one program, and a per-program scope would reject the second reinsurer outright.

**Note on the surrogate key:** the obvious-looking scope, per `(program_id, participant_id)`, would do nothing at all. `participant_id` is this table's `UUID PRIMARY KEY` - unique per *row*, not per participant - so such a constraint could never fire. The identity of a participation is who they are and in what role, which is `(participant_name, participant_type)`. This is the same distinction ADR 0016 drew between a `policy_vehicle_id` and a VIN.

**Role is part of the key on purpose.** The same legal entity may hold two roles on one program - a fronting carrier that also takes a reinsurance share is a real structure, and the `mga_retention` row for the MGA's own economics coexists with everything else by design. What can never legitimately happen is the same entity holding the *same* role twice at once, which is a duplicate the waterfall pays twice. Both identity columns are already `NOT NULL` (from ADR 0007), so this constraint has no null hole - the failure mode ADR 0016's addendum had to fix on its tables does not exist here. The `SET NOT NULL` statements are re-asserted idempotently anyway, so the ADR 0015 verifier checks them rather than the file assuming them.

## 4. Superseding a row: same shape as the policy side, different escape hatch - because the established one is impossible here

**Decision: `correct_program_participant()` follows `correct_policy_endorsement()`/`correct_policy_vehicle()` exactly in shape - close the old row's range at the new row's start, insert the new row, never mutate in place - but it grants itself the closing `UPDATE` through a transaction-local flag the append-only trigger recognises, not through `ALTER TABLE ... DISABLE TRIGGER`.**

The established mechanism cannot work on this table, which was discovered by writing it that way first and watching it fail:

> `ERROR: cannot ALTER TABLE "program_participants" because it has pending trigger events`

`program_participants` carries a `DEFERRABLE` constraint trigger (the share-sum check). Any `UPDATE` queues a pending trigger event, and Postgres refuses `ALTER TABLE ... ENABLE TRIGGER` while a table has pending trigger events - so the re-enable fails and the whole supersession aborts. The policy-side tables have no deferred triggers, which is the only reason `DISABLE TRIGGER` works there. There is no ordering that avoids this: the events stay pending until commit, and *not* re-enabling would leave a production table's append-only protection silently off.

(A related sharp edge, hit first and worth recording: `ALTER TABLE ... DISABLE TRIGGER` also fails with "because it is being used by active queries in this session" if the caller's own statement is scanning the table - e.g. `SELECT correct_...((SELECT participant_id FROM program_participants WHERE ...), ...)`. The policy-side correction functions share this trap. The flag-based mechanism here is immune to it; retrofitting the three policy-side functions is out of scope for this ADR but worth doing. **Since done** - `correct_policy_vehicle()`, `correct_policy_driver()` and `correct_policy_endorsement()` were checked against both traps: the deferred-events one does not apply to them, the active-queries one reproduced on all three, and all three now use this mechanism. See ADR 0016 addendum 2 and ADR 0014's addendum.)

The replacement is **narrower than what it replaces**, which is the argument for it beyond mere necessity. `DISABLE TRIGGER` turns the append-only rule off entirely for the duration and for everyone. The trigger here instead permits exactly one mutation - closing a row's upper bound, with `participant_id`, `program_id`, name, role, share, commission, formula and the range's *lower* bound all unchanged - and only while `luxauto.superseding_participant` is set, which `correct_program_participant()` sets transaction-locally and clears immediately after its `UPDATE`. An `UPDATE` that changes a share while the flag is on is still rejected (tested).

This is not a privilege boundary and isn't presented as one: `odoo` has no `UPDATE` grant on this table at all, and anyone who could set the flag could equally drop the trigger. It is a guard against the escape hatch being reachable by accident from an ordinary write.

**No audit-log row, unlike its policy-side siblings.** `correct_policy_vehicle()` writes to `policy_events`; that table is foreign-keyed to a policy, and there is no program-level event table. The append-only row history records what changed and when, but not who or why. Inventing a `program_events` table inside this ADR would be exactly the scope creep this project avoids elsewhere - named here as an open item instead.

**No grant to `odoo`.** The policy-side correction functions are granted because Odoo models exist for those tables. There is no Odoo model over `program_participants` (the waterfall view exposes participant columns read-only, computed), so a grant would widen access with no consumer.

## Consequences

- The panel can now change over the life of a program - which it could not before, in either direction: the old check blocked the legitimate change and permitted the illegitimate ones. This is the first ADR in this project where the flagged "simplification" turned out to be actively wrong rather than merely incomplete.
- `check_program_shares_sum_to_100()` is rewritten, not extended. Its rule is strictly stronger; any data that satisfied the old check and not the new one was wrong under ADR 0007's own stated intent.
- The rule lives in one place, `first_program_share_gap()`, used by both the trigger and the migration guard - the same single-source-of-truth reasoning ADR 0010 gave for the waterfall math.
- The migration refuses rather than repairs, like the ADR 0016 addendum's: it counts overlapping pairs and non-conforming programs first and raises with counts and a `HINT` pointing at a diagnostic query. `luxauto` had zero rows in this table (checked); both guards were tested against deliberately introduced violations anyway.
- ADR 0015's verifier baseline moves: +3 functions, +2 triggers, +3 `SET NOT NULL` columns.
- **Adding or removing a participant mid-term remains deferred**, as does a `program_events`-style audit trail for who changed a panel. ~~And retrofitting the flag-based escape hatch onto the three policy-side correction functions.~~ That retrofit is **done** (same day): the deferred-events trap turned out not to apply to `policy_vehicles`/`policy_drivers`/`policy_endorsements` - none has a deferrable constraint trigger, verified against `pg_trigger`/`pg_constraint` and by attempting the failure - but the active-queries trap reproduced on all three, so all three moved to this mechanism. ADR 0016 addendum 2 and ADR 0014's addendum record it. No `ALTER TABLE ... DISABLE TRIGGER` remains in the schema.
- `insurance_programs.effective_range` itself is not protected: shortening a program's term after its panel exists could strand participation outside the term, because the check trigger is on `program_participants` and does not fire on writes to `insurance_programs`. Named, not fixed - it is a different table, and giving `insurance_programs` its own temporal discipline is its own decision.
- ADR 0007's flagged gap is closed. ADR 0016's addendum closed one instance of this category; with this ADR, the category has no known open instances left in the schema.

---

# Addendum: `correct_program_participant()` and earlier-start corrections (2026-08-13)

**Status:** Decided; implemented
**Full reasoning:** ADR 0016 addendum 3, which owns the writeup for the identical fix across all four correction functions.

`correct_program_participant()` shared the supersession statement the policy-side correction functions use, and therefore shared its bug: correcting a participant row to a start earlier than the row it replaces produced `range lower bound must be less than or equal to range upper bound`. Reproduced here before being changed. The old row is now emptied instead, and this table's append-only trigger permits that shape.

Two things specific to this table were verified rather than assumed. Emptying is compatible with section 2's temporal 100% rule: an empty range contains no instant, so it contributes nothing to the panel sum at any probe, and `empty <@ term` satisfies the containment check - the timeline is computed from the surviving rows, which is what it should be. And the reachable earlier-date corrections here are narrower than on the policy side: a risk-bearing participant's row can only be preceded by another version of itself (the exclusion constraint refuses the overlap, correctly, since moving a changeover earlier is a two-row change) or by a panel gap the 100% rule already forbids. Corrections with no live predecessor - a first version, or a non-risk-bearing `mga_retention` row entered with the wrong start - now work, verified with the panel still totalling 100% at every instant afterwards.

Section 4's trigger listed the permitted columns explicitly where the policy-side triggers compare `to_jsonb(NEW) - 'effective_range'`. That list is now folded into the same comparison: identical in effect, minus the one column it omitted (`created_at`), and a column added to this table later is covered without anyone remembering to extend it.
