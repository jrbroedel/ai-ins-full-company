# ADR 0018: Return premium and cancellation

**Status:** Decided; implemented
**Date:** 2026-08-13
**Follows from:** ADR 0013 (deferred return-premium/cancellation adjustment), ADR 0014 (`policy_endorsements`, the `(program_id, amount, as_of)` waterfall core, `correct_policy_endorsement()`), ADR 0012 (`cancel_policy()`, `SECURITY DEFINER` pattern), ADR 0016/0017 (temporal + append-only discipline, correction-function mechanics), ADR 0010 (`policies.status`, atomic write discipline)
**Not in scope:** natural expiry and nonrenewal (ADR 0010's separate open item - an expired policy is not a cancelled one), the commission formula (ADR 0007), and ADR 0017's deferred items. Reinstatement is named as deferred in section 6.

## What this ADR decides

ADR 0013 deferred "return premium / cancellation adjustment" and nothing since has picked it up. This ADR covers both halves the deferral named: a mid-term coverage reduction (money back, policy continues) and a full cancellation (money back, policy ends). It decides five things: that the first half needs no new schema, where a cancellation's status lives, where its return premium lives, how the refund is computed, and how a cancellation entered in error is corrected. It also draws a hard line around short-rate factors, which are filed numbers this project does not get to invent.

## 1. Mid-term coverage reduction: nothing to build, and that was checked rather than assumed

**Decision: a mid-term reduction is an endorsement with a negative `premium_delta`. No new schema, no new function, no special-casing.**

ADR 0014 section 5 predicted this - "a negative `premium_delta` (return premium) needs no special-casing... the formula is linear in `amount`" - but predicted it in prose. There is no committed test suite in this repo, and nothing in ADR 0014's own record shows a negative delta was ever actually run through. Before building anything, it was:

- `calculate_premium_waterfall(program_id, -6000, as_of)` returns `gross_share`/`commission_amount`/`net_due` negative and exactly proportional (-3600.00/-360.00/-3240.00 at a 60% share with 10% commission), the mirror image of the same call with +6000.
- `endorse_policy(...)` accepts a negative `premium_delta`, and `calculate_endorsement_waterfall()` splits it correctly: the per-participant `gross_share` sums to exactly the delta, and commission + net reconstructs it.
- No `CHECK` constraint anywhere in the schema constrains `premium_amount` or `premium_delta` to be positive - checked against `pg_constraint`, not from memory. `ROUND()` is symmetric on negatives.
- `correct_policy_endorsement()` works on a negative-delta endorsement, including when its id is resolved by a subquery scanning `policy_endorsements` (the ADR 0016 addendum 2 trap, fixed in `e4bc625`).

So the first half of this ADR is a confirmation, not a build. That is worth stating plainly rather than quietly shipping code that looks like work: the ADR 0014 design was right, and it is now verified instead of asserted.

## 2. Cancellation status: `policies.status` already exists, so nothing new is invented for it

**Decision: cancellation status stays exactly where ADR 0010 put it - `policies.status policy_status_t NOT NULL DEFAULT 'active'`, set to `'cancelled'`. No status column is added, no `policy_terminations` table is created, and cancellation is not encoded as a typed `policy_endorsements` row.**

The task offered those three options; the schema had already answered. `policy_status_t` is `('active', 'cancelled', 'expired', 'nonrenewed')`, `policies.status` is indexed, and ADR 0012's `cancel_policy()` already set it. Cancellation status was never inferable-only, so the problem this decision was meant to solve did not exist. Adding a second place that records the same fact would have created the ambiguity it was supposed to prevent.

What ADR 0012's `cancel_policy()` genuinely lacked is everything else: it computed no return premium, left the policy's vehicle and driver snapshots running to the original term end, and had nowhere to record who initiated the cancellation or why. That is what sections 3-5 add.

## 3. `policy_cancellations`, not a `policy_endorsements` row

**Decision: a new table, append-only and versioned like every other temporal table here, holding one row per cancellation: `effective_range`, `cancellation_type`, `reason_code`, `refund_method`, `short_rate_factor`/`short_rate_basis`, `unearned_premium`, `return_premium`, `notes`, `performed_by`.**

Carrying the refund as an endorsement row was the obvious-looking alternative and it does not survive contact with `policy_endorsements`' own constraint. That table's exclusion constraint is scoped **per policy** - at most one endorsement in force at a time (ADR 0014 section 3). A cancellation's unearned period runs from the cancellation date to the original term end, which is exactly the window a mid-term endorsement typically occupies, so writing the cancellation there would force superseding whatever endorsement was in force purely to satisfy a constraint that was never about cancellations. The endorsement was not wrong and did not stop applying early; the policy stopped.

The cancellation-specific fields settle it independently: `cancellation_type`, `reason_code`, `refund_method` and the short-rate provenance have no home in `policy_endorsements`, and growing that table four columns that are null for every endorsement is the shape of a table doing two jobs.

`effective_range` is `[cancelled_at, the policy's original term end)` - the unearned period the refund covers. That choice does double duty: it is the honest description of the row, and it preserves the original term after `policies.effective_range` has been truncated, which is what a later correction needs to recompute against (section 6).

**The refund reaches participants exactly the way an endorsement's does.** `calculate_cancellation_waterfall(cancellation_id)` resolves a cancellation to `(program_id, return_premium, cancelled_at)` and delegates to the shared `calculate_premium_waterfall(program_id, amount, as_of)` core - a third thin entrypoint over one arithmetic implementation, precisely the composition ADR 0014 section 5 established and for the same reason. The amount is negative, so every participant's share comes back negative in proportion. `as_of` is the cancellation date: the panel in force when coverage ended is the panel that owes the money.

## 4. One function, one transaction

**Decision: `cancel_policy(policy_id, cancellation_type, reason_code, refund_method, cancelled_at, notes, performed_by)` does all of it in a single call - validate, compute the refund, close out the vehicle and driver snapshots, truncate the policy's coverage, write the cancellation row, log the event.**

A cancellation that adjusted premium but left three vehicles in force, or truncated coverage without recording a refund, is exactly the partial state ADR 0010's write discipline exists to prevent - and unlike a bind, a cancellation touches four tables. Making it one function rather than a documented sequence means no caller can complete half of it. Tested by injecting a failure at the last write and confirming that status, term, snapshot ranges, cancellation rows and events were all bit-identical to before the call.

**The snapshot closeout is its own function, not a reuse of `correct_policy_vehicle()`/`correct_policy_driver()`.** Those exist to fix a *mistaken* snapshot: they insert a replacement row and log `policy_vehicle_corrected`. A cancellation produces no successor row - the coverage ends - and logging it as a correction would assert the snapshot had been wrong when it was right up until the policy stopped. What the two paths do share is the underlying mutation, and the append-only trigger already permits exactly it: close the upper bound, lower bound and every other column unchanged (ADR 0016 addendum 2). `close_policy_coverage()` therefore needs no new escape hatch and no trigger change - it reuses the one already there, which is the strongest evidence that mechanism was drawn at the right boundary.

A row starting after the cancellation date (a future-dated correction) closes to its own start - an empty range - rather than to an impossible one with `upper < lower`.

## 5. Pro-rata is implemented; short-rate is a mechanism with the numbers left out on purpose

**Decision: pro-rata is fully implemented and is the default. Short-rate is implemented as a lookup against a `short_rate_factors` table that ships empty, and selecting it with no filed table loaded raises `SHORT_RATE_TABLE_NOT_CONFIGURED` rather than falling back to anything.**

**Pro-rata** needs no filing - it is arithmetic - so it is built completely. Every premium amount is earned evenly across *its own* effective period: the quote's written premium over the policy term, plus each endorsement's `premium_delta` over that endorsement's own range. A mid-term increase that ran for two months of a twelve-month policy is not unearned the way the original premium is, and a superseded endorsement carries a closed range so it contributes exactly the period it was actually in force and nothing more. Verified against an independent recomputation of the same instant: function and hand calculation agree to the cent.

**Short-rate is where this project stops.** Short-rate percentages are filed, state-regulated numbers: several states restrict short-rate to insured-initiated cancellations, cap it, or prohibit it for company-initiated ones, and the applicable table is part of a rate filing. This is the same category of risk `state_rating_table_schema.json` handles by storing compliance metadata as explicitly unverified rather than inventing authoritative-looking values, and it gets the same treatment here:

> **Short-rate factors must be sourced from actual filed cancellation/short-rate tables and current DOI bulletins for each state before this is usable for a real insured-initiated cancellation in production.** Every row in `short_rate_factors` must trace back to a real source document - a filed rate manual page, a DOI bulletin - or it is a data gap waiting to surface at the worst time. The table ships with no rows, and nothing in this repo invents one.

The table carries what a real filing needs to be applied correctly rather than just a number: `state`, optional `program_id` (a program-specific row wins over a statewide one), the elapsed-term band the factor applies to, `applies_to` (so a state permitting short-rate only on insured-initiated cancellations can say so in data), an effective range, and `serff_filing_tracking_number`/`rate_manual_reference` for provenance.

It also carries `basis`, and that column is the part most likely to be skipped by someone in a hurry. Filed tables express short-rate in at least two different ways - a multiplier on unearned premium, and a percentage of annual premium returned - and the two produce different refunds from the same policy. Which one a given filing means is a fact about that filing, so `short_rate_basis_t` makes whoever loads the table declare it, and the calculation switches on it. Guessing would have been the easy path and the wrong one.

**`cancellation_type` is the input that decides which method may apply**, which is why it is required (section 7) rather than defaulted.

## 6. Correcting a cancellation supersedes it entirely, unlike every other correction here

**Decision: `correct_policy_cancellation()` follows the established close-old-row-then-insert shape, except that the old row's range is emptied rather than closed at the new row's start. The refund is recomputed against the original term, and the policy's coverage end plus any snapshot row closed by the original cancellation both move to the corrected date.**

The difference is not cosmetic and it took a failed test to see clearly. `correct_policy_endorsement()` and `correct_policy_vehicle()` correct a *period fact*: an endorsement really was in force from its start until the correction took over, so splitting its range at that point is true. A cancellation is a *point event* whose range describes the unearned window one refund was computed over. Closing a cancellation dated 9 February at 30 April would assert that a refund covering February-to-term-end actually covered February-to-April - a number nobody computed. "This cancellation applied for zero time; here is the one that replaced it" is the only accurate statement, and it keeps the exclusion constraint meaning exactly "at most one cancellation in force", since empty ranges overlap nothing. It is also the only shape that works when correcting to an *earlier* date, where no closed range exists at all (`upper < lower` is not a range).

This required the one difference in this table's append-only trigger: it permits emptying the range rather than closing the upper bound, because Postgres normalises an empty range to `empty` and the "lower bound unchanged" test the other tables use cannot hold.

Both ADR 0016 addendum 2 traps were applied from the start rather than rediscovered: no `ALTER TABLE ... DISABLE TRIGGER` anywhere in this ADR's code, and the correction was tested with its target id resolved by a subquery scanning `policy_cancellations` in the same statement.

**Not a reinstatement.** "This cancellation should never have happened" puts a policy back in force, which is a different business event with its own questions - does coverage apply to the gap, is a new policy issued, what happens to the refund already paid. Named as deferred rather than approximated.

## 7. ADR 0012's `cancel_policy(policy, performed_by, notes)` now refuses

**Decision: the original three-argument signature stays callable and raises `CANCELLATION_TYPE_REQUIRED`, pointing at the new one. It is not silently forwarded to the new function under assumed arguments.**

It has nowhere to record who initiated the cancellation, and that is the input deciding whether a filed short-rate table may apply. Forwarding it would mean choosing, on the caller's behalf, the exact thing this ADR exists to make explicit - and recording a guess about the initiator in an audit trail is worse than an error, because it looks like a fact. Same reasoning as `SHORT_RATE_TABLE_NOT_CONFIGURED`: a loud failure beats a plausible default on a number someone gets paid. The overload is the composition ADR 0014 used for `calculate_premium_waterfall`, not a replacement.

The only caller in the repo, the Odoo cancel wizard, is updated in the same commit: it gains a required initiator, a required coded reason, and a refund-method selection defaulting to pro-rata. The initiator field has no default on purpose - an unconsidered click should not record the insured as having requested a cancellation the company initiated.

## Consequences

- ADR 0013's deferred return-premium item is closed. A cancellation's refund now reaches `program_participants` through the same waterfall core as premium and endorsements, at the panel in force on the cancellation date.
- Four new callable functions (`cancel_policy` 7-arg, `correct_policy_cancellation`, `calculate_cancellation_waterfall`, `policy_unearned_premium`) are granted to `odoo`; `policy_unearned_premium` is read-only and grantable so a UI can show a refund before committing to it.
- The ADR 0015 baseline moves: +2 tables, +3 enum types, +7 functions, +2 triggers.
- `short_rate_factors` is empty and every short-rate cancellation fails until it is loaded from filed sources. That is the intended state, not an incomplete build.
- ~~`luxauto_settlement_view` and `luxauto_premium_waterfall_view` are unchanged, so a cancellation's return premium does not yet appear in the settlement report - exactly the position ADR 0014 left `calculate_endorsement_waterfall()` in, and the same follow-on (a settlement-report extension that consumes both) still owns it. Flagged rather than quietly widened here.~~ **Closed by ADR 0013's addendum**, which added both the endorsement and return-premium legs to that view.
- There is no Odoo read-side model or view over `policy_cancellations`. The wizard writes; nothing reads it back in the UI yet. Same deliberate split ADR 0016 made when it added correction functions without a correction UI.
- **Adjacent limitation found and left alone:** `correct_policy_vehicle()`/`correct_policy_driver()`/`correct_policy_endorsement()`/`correct_program_participant()` all fail with a raw `range lower bound must be less than or equal to range upper bound` if asked to correct a row to a start *earlier* than the row being superseded - confirmed live, not inferred. This ADR's own correction is immune (it empties instead), and fixing the other four is outside this ADR's scope, but it is a real gap in four shipped functions and should not be discovered a second time by accident.
- ~~Endorsements whose `effective_range` extends past a cancellation are not closed out - only vehicles and drivers are, which is what this ADR's scope named. A settlement report reading endorsements `as_of` a date after cancellation would still see one in force. Named here as an open item rather than fixed by extending scope mid-build.~~ **Investigated and closed as not-a-defect** - see the addendum below. The stale range is descriptive only, and truncating it would break the refund recompute a cancellation correction performs.
- Reinstatement, natural expiry and nonrenewal all remain unbuilt and unclaimed.

---

# Addendum: endorsements are deliberately not closed out at cancellation (2026-08-13)

**Status:** Decided; investigated and deliberately not changed
**Amends:** the consequence that read "Endorsements whose `effective_range` extends past a cancellation are not closed out... Named here as an open item rather than fixed by extending scope mid-build."
**Companion:** ADR 0013's addendum, which closed the other half of that pair.

## What was actually wrong: nothing computational

Reproduced live before deciding anything. A policy written at 36,500 with a +7,300 endorsement effective from day 30 to term end, cancelled at day 90:

- `policies.effective_range` is truncated to day 90 and `status` becomes `cancelled`; `policy_vehicles` and `policy_drivers` are closed to day 90.
- The endorsement row still reads day 30 → day 365, ~9 months past the day coverage stopped. Descriptively stale, exactly as flagged.
- **The refund is already correct.** Unearned came to 33,492.50, which is 27,499.97 of base premium plus 5,992.53 of the endorsement's own unearned portion - hand-recomputed to the cent. The endorsement's remaining premium was refunded *because* `policy_unearned_premium()` prorates each amount over its own effective period.
- `calculate_endorsement_waterfall()` returns identical numbers before and after cancellation: its `as_of` is the endorsement's own start, which cancellation does not move.
- With the ADR 0013 addendum, the settlement view dates endorsements by `created_at`, so a stale range cannot affect what is reported there either.

So this was **stale-but-harmless**, not a bug. No computed result anywhere is wrong because of it.

## Why the obvious tidy-up is not applied

The natural fix - close the endorsement's range at the cancellation date, exactly as vehicles and drivers are closed - was tested before being adopted, and it **introduces a real money error**.

`correct_policy_cancellation()` recomputes the refund against each endorsement's own range when a cancellation's date is corrected. Truncating the range destroys the denominator that recompute needs. Measured, on the case above, correcting the cancellation from day 90 back to day 60:

| | endorsement's unearned share | total refund |
|---|---|---|
| endorsement left intact (current behaviour) | 6,646.26 | **37,146.24** |
| endorsement closed out at day 90 | 3,649.98 | 34,149.96 |

A 2,996.28 error in a number somebody gets paid, produced by a change made purely for tidiness. The correction path was then run for real and returned 37,146.24 - the correct figure, and the one the settlement view reports.

**Decision: leave endorsement ranges intact at cancellation.** The distinction this rests on is worth stating, because it also explains why vehicles and drivers *are* closed out: `policy_vehicles`/`policy_drivers` are a coverage register - what is insured, when - and a row claiming coverage past the cancellation is wrong on its face. `policy_endorsements` is a premium ledger: its range is the period a premium amount is *earned over*, which is precisely the input the refund arithmetic needs preserved. `policies.effective_range` and `policies.status` remain the authoritative statement of what is covered, and neither is ambiguous after a cancellation.

Closing endorsements safely would mean preserving each row's original earning period somewhere the correction path could read it back - a new column or a restore-then-recompute step in `correct_policy_cancellation()`. That is real machinery in exchange for a cosmetic gain, and it is not built here.

## Consequences

- An endorsement row on a cancelled policy still shows a range extending past the policy's coverage end. That is expected, and the policy row is where coverage is read from.
- The refund arithmetic keeps working through corrections in both directions, which is the property that would have been lost.
- The open item this addendum replaces is closed as **investigated, not a defect**. If a future consumer ever needs "which endorsements were in force at instant T", it should intersect the endorsement range with the policy's own `effective_range` rather than trusting the endorsement range alone - one line at the point of use, and no data destroyed.
