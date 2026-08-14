# ADR 0021: Mid-term participant removal, program-term protection, and bundled reallocation

**Status:** Decided; implemented
**Date:** 2026-08-14
**Follows from:** ADR 0017 (made `program_participants` temporal and deferred exactly these three items), ADR 0016 addendum 3 (the `GREATEST()` fix this reuses), ADR 0007 (created the table and the 100% rule), ADR 0010 (the point-in-time waterfall that reads the panel)
**Not in scope:** a `program_events` audit trail, an Odoo model over any of this, renewal, and the `profit_commission_formula` computation - all still open, all still elsewhere. Nothing on the policy side is touched.

## What this ADR decides

ADR 0017 closed the temporal-integrity gap on `program_participants` and named three things it would not do: removing a participant mid-term with no replacement, protecting `insurance_programs.effective_range` from being shortened out from under an existing panel, and bundling "add a participant and adjust everyone else" into one call. Its section 1 was explicit that the first of these "needs its own decision about what happens to the shares of everyone else, which is a business question." This ADR makes that decision and closes all three.

Five things are decided: what an under-placed panel is allowed to be, why the share probe had to become two functions, when a gap may be declared closed, what happens to a program term that no longer contains its panel, and how a reallocation gets its numbers.

Each failure mode below was reproduced against `luxauto-pg` before the code that addresses it was written, and `program_participants` was confirmed to have zero rows first - the same precondition ADR 0017's own migration checked. Every test ran inside a transaction that was rolled back: this is production, and the table is append-only, so a committed test row could not have been deleted afterwards. Both tables and `program_coverage_gaps` still hold zero rows.

## 1. Removal is allowed to leave a hole, but only a tracked one

**Decision: an under-100% panel is permitted if and only if an unresolved `program_coverage_gaps` row exists for that program. Over-100% remains an unconditional hard block, always, and nothing in this feature weakens it.**

The asymmetry is the whole design, and it is not arbitrary. The two directions are different kinds of wrong:

- **Under 100% is a commercial reality.** A reinsurer walks at the end of a quarter and the replacement is not signed yet. The program is genuinely under-placed for a stretch, and a schema that refuses to represent that is a schema that will be worked around - by back-dating the replacement, or by leaving the departed reinsurer's row open, which is worse than the hole because it is a lie the waterfall will act on.
- **Over 100% is always a data error.** It means two rows claim the same risk at the same instant, and ADR 0017 section 1 finding 2 recorded what that does: `calculate_premium_waterfall` pays that share twice. There is no commercial situation this represents. It stays a hard block.

So removal does not relax the rule; it adds a way to record that someone has accepted a specific hole, and makes that record the only thing that suppresses the error.

**The suppression is per-program and deliberately coarse.** An open gap row silences the under-100% branch anywhere in that program's timeline, not only across the window the removal actually stranded. Matching a gap to its exact interval was considered and rejected: it would be a second temporal model layered over the first, and it would have to stay correct as the panel moved underneath it - the panel being a thing that changes, which is the entire premise of ADR 0017. The cost is real and is stated rather than hidden: while any gap is open on a program, a *different* hole elsewhere in that program's term will not raise either. The mitigations are that opening a gap requires a non-empty reason, closing one re-checks the whole timeline (section 3), and the suppression is not silent.

**Suppressed is not silent.** A suppressed under-100% raises a `NOTICE` naming the program, the total and the instant. The gap table records that a human accepted an under-placed panel; the NOTICE records that the database acted on that acceptance, and puts it in the Postgres log where a later "why did this program pay out short?" has something to find. The alternative - suppressing into complete silence - makes the most consequential state this schema can be in the only one that leaves no trace. One log line per suppressed write is a cheap price.

The honest cost of that choice: the share check is a `FOR EACH ROW` constraint trigger, so a statement touching three rows emits the same NOTICE three times (observed - a three-row panel write produced three identical lines). That per-row re-evaluation predates this ADR and is noted as an open item rather than fixed here.

## 2. The probe function had to become two, and a LIMIT 1 is why

**Decision: `program_share_gaps()` returns every bad instant with a `direction` of `'under'` or `'over'`; `first_program_share_gap()` survives as the `LIMIT 1` wrapper ADR 0017's callers already use, now carrying the same third column. The probe logic is still written exactly once.**

The obvious implementation - keep the single-row function, add a `direction` column, branch on it - is wrong, and the reason is the most interesting finding in this ADR.

`first_program_share_gap()` returns the *earliest* bad instant. Suppose a panel is under-placed from March (tracked, suppressed) and has an overlap from September (never suppressible). The earliest bad instant is March. A trigger that asks one question, gets the March row, sees `'under'`, finds an open gap and suppresses it **has already discarded the September overlap** - the query returned one row and that row was not it. The 110% window would commit, and the waterfall would pay someone twice.

This was not reasoned about in the abstract; it was built as a test and run:

```
--- probes, in time order. Note the UNDER comes first:
      bad_instant       | total_share | direction
------------------------+-------------+-----------
 2026-03-01 00:00:00+00 |       60.00 | under
 2026-09-01 00:00:00+00 |      110.00 | over

--- what a LIMIT-1 probe would have returned (and suppressed):
 2026-03-01 00:00:00+00 |       60.00 | under
```

The trigger therefore asks the two directions as two separate questions, over-100% first and on its own, each ordered earliest-first within its direction. Over-100% is never reached by any suppression path because it is never asked in a way that a gap row can answer.

ADR 0017 insisted the rule live in one place, and it still does: `program_share_gaps()` holds the probe set, the containment semantics and the tolerance band, and the wrapper is three lines that call it. Changing the return type needs a `DROP` before the `CREATE OR REPLACE`, which the file does explicitly.

Two smaller things were fixed in passing, both in code this ADR was already rewriting. The per-probe total was being computed twice per row (once in the select list, once in the `WHERE`); it is computed once now, which also gives `direction` a single source it cannot disagree with. And the error message's percent sign was on the wrong side of its number - `RAISE` scans its format left to right, so the old `'%%%'` resolved as a literal `%` followed by a placeholder and printed `%60.00`. No ordering of those three characters yields `60.00%`, so the wording carries the unit instead.

## 3. A gap may not be declared closed while the hole is still there

**Decision: `resolve_program_coverage_gap()` re-runs the share math and refuses if any under-100% instant remains for that program. It does not care whether other gap rows are still open.**

Without the check, `resolved` would be a boolean anyone could set on a still-broken program, and the consequence would land on whoever made the *next* unrelated write to that panel: they would get `PROGRAM_SHARES_NOT_100_AT_INSTANT` for a hole somebody else left, with nothing connecting it to the removal that caused it. Raising here puts the failure in front of the person holding the context, which is the same argument ADR 0018 made for validating a cancellation at the point of cancellation.

Only the share math is checked, not whether this is the program's last open gap. Two removals can be recorded separately and closed by a single panel rebuild, and the second `resolve` call should not fail merely because the first row is still open. Over-100% is deliberately not checked here either - an overlap is already a hard block on every write to the panel, and it is not this gap's business to re-report it.

## 4. `insurance_programs.effective_range`: hard block, no repair

**Decision: a `BEFORE UPDATE` trigger on `insurance_programs`, firing only when `effective_range` actually changes, rejects any change that would leave an existing `program_participants` row outside the new term. No auto-close, no auto-truncate.**

ADR 0017 named this and left it: the share check lives on `program_participants` and never fires for a write to `insurance_programs`, so shortening a program's term silently stranded its whole panel. Reproduced before the trigger was written - narrowing a 2026 program to end in June left both participants with ranges running to 2027 and `contained = f`, accepted without complaint.

Repair was rejected on the same grounds ADR 0017's migration refused to fix bad panels: truncating participant rows to fit would be the schema editing capacity agreements so that a statement can succeed, and auto-closing them would invent a removal date nobody chose. The caller closes or adjusts participation first - `remove_program_participant()` for a departure, `correct_program_participant()` for a shortened participation - and then moves the term. The error names every offending participant and its range.

**Widening passes with no special-casing, and that was verified rather than assumed** - containment against a superset is satisfied by every row that satisfied the subset, so a widen finds nothing to complain about.

**But widening has a consequence on the *other* rule, and this ADR does not close it.** Extending a term stretches the window over which the panel must total 100%, and the share check does not fire on writes to `insurance_programs`. Widening a 2026 program to span 2025-2028 was accepted and left two untracked under-100% instants with zero open gap rows - a hole the gap mechanism never heard about. It is latent rather than permanently invisible: the next write of any kind to that program's participants raises on it, which was confirmed by making one. Named as an open item below. Closing it means either running the share check from this trigger too, or accepting that a term change is a panel change and routing it through a function - both bigger decisions than the containment rule this ADR was asked to add.

## 5. Reallocation takes explicit numbers, and only explicit numbers

**Decision: `add_program_participant_with_reallocation()` takes the incoming participant's fields plus parallel arrays of `(participant_id, new_share_percentage)` for every existing row being adjusted. Every target share is an input. There is no proportional scaling, no equal split, and no residual-to-the-largest rule.**

This follows the project's standing treatment of undecided business formulas, and it is a rule with a track record here: ADR 0007 shipped `profit_commission_formula` as free text pending underwriting sign-off rather than guessing a computation, and ADR 0018 shipped short-rate cancellation as a factor table that starts empty and raises rather than assuming a curve. How a panel dilutes to make room for a new reinsurer is a negotiated commercial outcome. A schema that computed it would be inventing the terms of a capacity agreement.

Bundling exists because the deferred check should judge the finished panel once. The alternative - the caller issuing a correction per participant and then an insert - works only if every intermediate state is tolerated, and the point of `DEFERRABLE INITIALLY DEFERRED` (ADR 0017 section 2) is that they need not be.

Three implementation choices worth recording:

**`correct_program_participant()` is reused rather than joined by a share-only sibling.** Its signature genuinely is awkward for a share change - a direct caller must resupply type, name, commission and formula or silently null them, and it rejects a null name or type outright. That was the argument for a narrower variant, and it loses: this function has already read the outgoing row to find its end date, so forwarding those four columns costs nothing here, while a second supersession path would be a second place for the append-only discipline to drift out of step. The awkwardness is real but it is the *direct* caller's problem, and this ADR does not add a direct caller.

**Parallel arrays, not a composite type.** Every `CREATE TYPE` in this schema is an enum; one row shape used by one function is a thin reason to introduce the project's first composite. The lengths are checked, which is the only thing a composite would have bought. (`array_length` of an empty array is `NULL` rather than `0`, so both sides are coalesced before comparison - a detail that would have made an empty adjustment list look like a length mismatch.)

**Adjusted rows change share at the incoming participant's start and keep their existing end date.** That is a mechanism choice rather than an invented number: "add a participant and adjust the others" has exactly one coherent changeover instant, and moving anyone's end date would be a second, unrequested decision. A participant whose row already ends at or before that instant is rejected by name, because the alternative is an inverted-range error naming nobody.

## 6. Reuse of the two known traps, and which actually applied

ADR 0016 addendum 2 and ADR 0017 section 4 record two traps for anything that supersedes a row on these tables. Both were tested against every new function here rather than reasoned about:

- **The deferred-pending-trigger-events trap** (`ALTER TABLE ... ENABLE TRIGGER` fails while a table has pending deferred events) **does not apply**, because no function added here uses `DISABLE TRIGGER`. `remove_program_participant()` uses the transaction-local `luxauto.superseding_participant` flag, the mechanism ADR 0017 built precisely because this table's deferred trigger makes the `ALTER TABLE` route impossible. No `ALTER TABLE ... DISABLE TRIGGER` remains anywhere in the schema, and none was added.
- **The same-table-subquery-in-caller trap** (`SELECT correct_...((SELECT participant_id FROM program_participants WHERE ...), ...)`) **does not apply either**, for the same reason - the flag mechanism is immune to it, as ADR 0017 predicted. Both `remove_program_participant()` and `add_program_participant_with_reallocation()` were called that way deliberately and both succeeded.

`remove_program_participant()` reuses ADR 0016 addendum 3's `GREATEST()`-based bound rather than re-deriving one. Writing the obvious `tstzrange(lower(v_old_range), p_removal_date)` would reintroduce exactly the bug that addendum closed: a removal dated at or before the row's own start would ask for an inverted range. Tested - such a removal empties the row instead, and an empty range contains no instant, so it contributes nothing to any probe.

## Consequences

- A participant can now leave mid-term without a replacement, which was impossible before: the panel simply could not be written down in that state. ADR 0017's largest deferred item is closed.
- Under-100% is no longer unconditionally an error, which is a genuine weakening of ADR 0017's rule and is why it required a table rather than a flag. Over-100% is unchanged and unchangeable by this mechanism, proven against the case that would have broken it.
- `first_program_share_gap()` gains a column and keeps its name and its callers; `program_share_gaps()` is where the probe logic now lives. The ADR 0017 migration guard reads the wrapper unchanged.
- Shortening a program term is now a hard error when it would strand a panel, rather than a silent corruption. Programs whose panels have not been created yet are unaffected - the trigger finds no rows to complain about, which preserves ADR 0017's bootstrapping escape.
- No `GRANT` on `program_coverage_gaps` or on any function added here, matching ADR 0017's treatment of `program_participants`: there is still no Odoo model over any of it, and a grant with no consumer is only extra reachable surface.
- ADR 0015's verifier baseline moves: +1 table, +5 functions, +1 trigger, no new types, views or `SET NOT NULL` columns. `first_program_share_gap()` is not a sixth function - its return type changes, which needs a `DROP` before the `CREATE OR REPLACE`, but it is the same object the baseline already counted. Re-applying the file twice is clean.

## Open items

- **No Odoo model over `program_coverage_gaps`.** Gaps are opened and resolved through `psql` by whoever is doing the panel work, exactly as participant corrections are today. Someone has to remember to resolve them.
- **No alerting on a stale open gap.** Nothing reminds anyone that a program has been under-placed for six months. The NOTICE fires on writes to the panel, which is precisely when nobody is ignoring it; the case that needs attention is the program nobody has touched. A periodic check would fit the systemd-timer pattern ADR 0019 established for `expire_policies()`, and is not built here.
- **Widening a program term can create an untracked under-100% stretch** (section 4). Latent, not silent - the next participant write raises - but the widen itself is accepted.
- **Gap suppression is per-program, not per-window** (section 1). An open gap on a program masks unrelated under-100% holes elsewhere in that program's term.
- **The share check re-evaluates the whole timeline per changed row**, being a `FOR EACH ROW` constraint trigger, which also multiplies the suppression NOTICE. Predates this ADR; unaddressed.
- **Still no `program_events` audit trail.** `program_coverage_gaps` records why a hole was opened and how it was closed, which is more than existed before, but it covers only this one kind of panel change. Who changed a share, and why, is still unrecorded - ADR 0017's open item, narrowed rather than closed.
