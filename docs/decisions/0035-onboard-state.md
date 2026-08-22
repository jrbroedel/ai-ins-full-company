# ADR 0035: `onboard_state()` — the sole sanctioned path for state rating data

**Status:** Decided; implemented
**Date:** 2026-08-19
**Follows from:** ADR 0034 (the trigger-ordering footgun this closes, and the CT seed it migrates), ADR 0025 (the short-rate seed trigger onboarding relies on and asserts), ADR 0028 (territory factors are a manual load), ADR 0016 (the transaction-local escape-flag idiom the guard reuses)

## The footgun this closes

ADR 0034 surfaced it: a raw `INSERT INTO state_rating_table_versions` placed *before* the ADR 0025 `state_rating_versions_seed_short_rate` trigger in the schema file **silently skips the short-rate seed, with zero error** — and it's trivially reintroduced by any future schema edit that reorders things. `onboard_state()` makes that impossible for the sanctioned path and loud for any other.

## What was built

- **`onboard_state(...)`** (SECURITY DEFINER) — one atomic operation that loads the compliance record (`state_rating_table_versions`, which fires the ADR 0025 seed) **and** its PD territory factor together, then **asserts the short-rate seed exists** (its exact signature: `factor 0.90`, `basis 'unearned_premium_multiplier'`, `serff = 'internally set - not filed'`) before returning the `record_id`. Any failure at any step aborts the whole transaction — no partial state. Loading both tables together also closes ADR 0034's secondary "uncoupled loads" gap (a state with a rating version but no territory factor would pass PC-03 then fail `create_quote`) for anyone going through the front door. Territory data is a **single PD scalar per state** (confirmed: `territory_factors` is one row per state/period, no array, no FK). `p_ai_governance` defaults to the **NY DFS Circular Letter 2024-7 documentation baseline**, operationalizing the project principle that every state is a subset of NY's bar.
- **A `BEFORE INSERT` guard trigger** (`state_rating_versions_onboard_guard` → `reject_unonboarded_state_rating_insert()`) on `state_rating_table_versions` that rejects any insert unless `current_setting('luxauto.onboarding_state', true) = 'on'` — the same transaction-local escape-flag idiom the six `luxauto.superseding_*` correction guards already use. `onboard_state()` sets the flag around its insert and clears it; a direct insert by anyone (the owner included) without the flag gets `STATE_RATING_TABLE_DIRECT_INSERT_FORBIDDEN`.

## Why the guard, not GRANT/REVOKE (the investigation's finding)

GRANT/REVOKE **cannot** close this footgun: no non-owner role has any privilege on `state_rating_table_versions`/`territory_factors`/`short_rate_factors` (nothing to revoke from `odoo`), and the footgun is the **owner** (the schema author) direct-inserting — a table owner's rights can't be revoked, and `onboard_state()` runs SECURITY DEFINER *as* that same owner. The only mechanism that forces even the owner through the front door is a guard trigger keyed on the escape flag. The `REVOKE INSERT, UPDATE, DELETE … FROM PUBLIC` and `GRANT EXECUTE ON onboard_state … TO odoo` are included as explicit documentation of intent — **not** the real lock.

## Scope, and the accepted residual risk

The guard is on **`state_rating_table_versions` only** — the actual footgun table. `territory_factors` is deliberately not guarded, because the T0 test-state seed legitimately loads a territory factor with no paired rating version; `onboard_state()` still always loads both for the front door.

**Residual risk, stated plainly:** guarding only `state_rating_table_versions` means someone could still recreate the original uncoupled-load problem by deliberately setting the escape flag (`SET LOCAL luxauto.onboarding_state = 'on'`) and inserting directly instead of calling `onboard_state()` — but that is an accepted risk, because it requires a **conscious, visible act** rather than an accidental file-ordering mistake, unlike the original footgun.

## Migrations & fixtures

- **CT** (ADR 0034) now onboards through `onboard_state()` instead of a raw insert — the one example demonstrating the sanctioned path. Identical data (a clean swap of insertion path, not new data); idempotent, so on the live DB where CT already exists the call is skipped. Verified: CT's three rows are unchanged (`prior_approval`, territory `1.12`, short-rate `0.90/unearned_premium_multiplier`).
- **12 test fixtures** (0007/0018/0023/0024/0025/0026/0027/0029/0030/0031/0032/0033) that write `state_rating_table_versions` directly set the escape flag once at their rolled-back transaction top — the lighter, correct touch (they test other ADRs' behavior, not onboarding). They are not rewritten to call `onboard_state()`.

## Testing

`tests/0035_onboard_state.sql` (3 cases): `onboard_state` atomically loads all three rows and returns the `record_id`, defaulting `ai_governance` to the NY baseline; the guard rejects a raw insert without the flag (`STATE_RATING_TABLE_DIRECT_INSERT_FORBIDDEN`) and allows one with it (fixtures/escape hatch intact); and a state onboarded through `onboard_state` is quotable end to end (PC-03 clears, `create_quote` produces a real premium with the loaded factor). Also verified directly against the live DB: the guard rejects an unflagged insert, a flagged insert seeds correctly, and CT's rows are unchanged after the migration. `scripts/run-tests.sh`: all 18 suites pass.

## Consequences

- Onboarding a state is now a single atomic, ordering-independent operation; the ADR 0034 trigger-ordering footgun is structurally closed for the sanctioned path and loud for any accidental direct insert.
- `verify_schema.py` baseline: +2 functions (`onboard_state`, `reject_unonboarded_state_rating_insert`), +1 trigger (`state_rating_versions_onboard_guard`).
- The `state-onboarding-not-atomic` memory is resolved for the trigger-ordering half; the accepted residual (a deliberate flag-set bypass) is documented above.
