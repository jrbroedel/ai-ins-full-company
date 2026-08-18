# ADR 0025: Seed the short-rate factor automatically when a state is onboarded

**Status:** Decided; implemented
**Date:** 2026-08-18
**Follows from:** ADR 0018 (the `short_rate_factors` table and `short_rate_factor()` lookup, which shipped empty and fail-loud), the referral matrix's PC-03 rule (a state with no rating-table record is "not licensed"), ADR 0021 addendum / ADR 0023 (the overload-trap reasoning that steers this toward a trigger rather than a widened function)

## The confirmed business decision

The short-rate cancellation penalty is settled, from the insurance-domain sign-off:

- **A flat 10% admin holdback** off the pro-rata return: the insured gets **90%** of what a pure pro-rata cancellation would return (his own example: a $100 pro-rata return pays $90).
- **No variance** — same 10% in every licensed state, for both company-initiated and insured-initiated cancellations, and it **does not change with how much of the term has elapsed** (flat, not graduated).
- **Not a filed rate.** Internally chosen by the business ("short rates are chosen by us"), not sourced from a SERFF filing or rate manual.

In `short_rate_factors` terms that is **one row per state**: `factor = 0.90`, `basis = unearned_premium_multiplier`, a single `[0,1)` band, `program_id` and `applies_to` NULL (any program, both initiators), `effective_range` unbounded, and provenance set to the sentinel `'internally set - not filed'` (the column is `NOT NULL`, so it cannot be left NULL, and must not be made to look like a real filing).

### Polarity: 0.90, not 0.10 — verified against the refund math

`cancel_policy()` computes, for the `unearned_premium_multiplier` basis, `return = -ROUND(unearned × factor, 2)`. So the refund is `unearned × factor`. A 10% holdback means the insured keeps 90% → `factor = 0.90` (`$100 × 0.90 = $90`). `factor = 0.10` would refund `$10` — a 90% holdback, the inverse. `0.90` also satisfies the table's `factor ∈ [0,1]` CHECK.

## Why a trigger, not a load script, a wrapper, or a runbook

The obvious "load one row per licensed state" runs into two facts, both verified against the live schema before deciding:

1. **`short_rate_factors.state` is `NOT NULL` and matched exactly** (`WHERE f.state = p_state`, no `IS NULL OR` escape, no wildcard). A single universal/state-independent row is impossible — it is genuinely one row per state.
2. **The licensed-state source of truth is `state_rating_table_versions`** (referral rule PC-03: no rating-table record ⇒ not licensed), and it is currently empty — so a one-time "load per licensed state" script inserts **zero rows today** and silently stays empty unless something re-runs it as states are actually onboarded. A query nobody re-runs is worse than none: it creates the illusion of coverage.

So the load has to be wired to onboarding. The options considered:

- **A trigger on `state_rating_table_versions` insert (chosen).** State onboarding today is a **direct `INSERT`** into that table — there is no onboarding function or runbook to fold into. A trigger fires *however* the state row is created (direct SQL now, a future wrapper later), so "a licensed state has a short-rate factor" is enforced by the database, not left to a step someone must remember — the same discipline every exclusion constraint and append-only trigger in this schema already follows.
- **Fold into an onboarding wrapper function (rejected).** No such wrapper exists. Choosing it means *building* state-onboarding infrastructure and locking the table down so direct inserts cannot bypass it — designing the onboarding process itself, which is out of scope, and until that lockdown exists today's direct-insert onboarding would silently skip the seed.
- **A manual runbook step (rejected).** This project is entirely code-/DDL-driven; there is no runbook pattern, and every other per-state datum (rating variables, referral thresholds, state-specific fields) lives in columns inserted *with* the row. Inventing a manual process here would contradict that and is exactly the case the "don't invent a manual pattern if everything else is code-driven" guidance rules out.

## The override hatch — a guard, not a parameter

The trigger seeds only `IF NOT EXISTS (SELECT 1 FROM short_rate_factors WHERE state = NEW.state)`. That guard does double duty:

- **Idempotency:** a second rating-table *version* of an already-onboarded state (a rating refresh) does not insert a duplicate.
- **Override hatch:** a state that must one day differ can have its state-specific `short_rate_factors` row seeded deliberately *before* onboarding, and the trigger leaves it untouched. The flat `0.90` is the **default for a state that has not been given its own**, not a value forced on every state forever.

No variance is planned today, so **no parameterised `factor` argument is built** — there is no wrapper to carry one, and the guard already provides the divergence path. Building it would be overbuilding for a need that does not exist. This is the deliberate, visible tradeoff: a state can diverge later without a schema change (pre-seed its row), but the common path stays a plain hardcoded default.

## Consequence, recorded not hidden: `SHORT_RATE_TABLE_NOT_CONFIGURED` and tests/0018 T6

Auto-seeding makes **"licensed ⇒ has a short-rate factor"** an invariant — the whole point — with one ripple. The `SHORT_RATE_TABLE_NOT_CONFIGURED` refusal (ADR 0018 §5) is now **unreachable for a licensed state**: any state with a rating table has a factor. The refusal still guards a *genuinely unlicensed* state (no rating table, so the seed never fired), which is correct.

ADR 0018's `tests/0018` **T6** exercised the old "licensed state but `short_rate_factors` empty" combination, which no longer occurs. It was revised to exercise the refusal two faithful ways instead: (A) `short_rate_factor()` called directly for a genuinely unlicensed state, and (B) `cancel_policy()`'s refuse-loudly-and-write-nothing transactionality, by removing the auto-seeded row for a licensed state first so the factor is genuinely absent. This is called out here rather than left as a silent test edit.

## What this does not touch

`cancel_policy()`, `correct_policy_cancellation()`, and `short_rate_factor()` are unchanged — this is purely additive (a seed on onboarding), not a change to how a short-rate cancellation is computed. No `state_rating_table_versions` rows were created; states are still not onboarded, and that remains out of scope. The graduated-by-elapsed-term capability of `short_rate_factors` is left intact — nothing here forecloses a future state filing a real graduated schedule; it would simply pre-seed that state's bands and the trigger would step aside.

## Testing

- `tests/0025_short_rate_state_seeding.sql` (new): onboarding a state seeds exactly one `0.90 / unearned_premium_multiplier / [0,1)` row with the sentinel provenance and both universal keys NULL, and the lookup returns it (T1); a second rating-table version does not duplicate it (T2); a pre-seeded state-specific override is respected, not overwritten or duplicated (T3).
- `tests/0018` T6 revised as above.
- `scripts/run-tests.sh` runs all suites; all pass.

## Consequences

- Every state onboarded from now on automatically carries the flat 10% short-rate factor, enforced by the database at insert time — no separate load to remember, nothing to drift out of sync with the licensed-state registry.
- A future state-specific short-rate can diverge without a schema change (pre-seed its row); the seed is a respected default.
- The `SHORT_RATE_TABLE_NOT_CONFIGURED` safety remains for genuinely unlicensed states and is documented as unreachable for licensed ones.
- `verify_schema.py`'s baseline moves by +1 function (`seed_short_rate_factor_for_state`) and +1 trigger (`state_rating_versions_seed_short_rate`).
- The `'internally set - not filed'` provenance is deliberate and must not be mistaken for a filed rate; if the business ever files these numbers, that sentinel is the flag showing they were internally chosen until then.
