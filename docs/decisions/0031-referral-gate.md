# ADR 0031: Referral gate — wiring the referral engine into the flow

**Status:** Decided; DB-side implemented
**Date:** 2026-08-19
**Follows from:** ADR 0026/0028 (the referral engine and its five rules this calls), ADR 0030 (`create_quote()`, which this guards), ADR 0029 (the latest-per-rule derivation `current_referral_action()` mirrors)

## The gap

`evaluate_application_referrals()` and its five rules (AL-01, CP-02, DH-01, PC-03, EL-01) were built and tested but **called nowhere in a real flow** — only test fixtures ran them. Investigation also found `applications.status` has a full lifecycle enum (`draft → submitted → … → declined`) that **no function ever transitions** — the same defined-but-unwired shape quotes had before ADR 0030. So ADR 0030's `create_quote()` produced a real, bindable premium with **no referral check at all**: an application with an active DUI conviction or a below-floor value could sail straight to a final quote.

## What was built

Two functions plus a guard. Neither touches the rules or the orchestrator — they only call and read.

**`submit_application(application_id, performed_by) RETURNS referral_action_t`** — the first applications-lifecycle transition. Moves a `draft` (or already-`submitted`) application to `submitted`, stamps `submitted_at` (kept from the first submission via `COALESCE`), calls `evaluate_application_referrals()` (writing the `decision_log` rows), and returns the most-severe action. Re-runnable: a later call re-evaluates the current data — the re-evaluation path for when a document resolves a flagged item. Refuses from any other status (`SUBMIT_APPLICATION_INVALID_STATE`).

**`current_referral_action(application_id) RETURNS referral_action_t`** — the read helper, deriving the current disposition from `decision_log` exactly as `luxauto_application_referral_view` does (ADR 0029): the latest row per rule (`DISTINCT ON … created_at DESC`), then `max()` over the enum's ascending severity order. Returns `NULL` when the application has never been evaluated, which the caller treats as distinct from any real disposition. `SECURITY DEFINER` so a guard in another function reads the disposition without a direct `decision_log` grant.

**The guard, inside `create_quote()`.** Before rating, it reads `current_referral_action()` and refuses unless the disposition is `<= 'AUTO_PROCEED_WITH_FLAG'`:
- never evaluated (`NULL`) → `QUOTE_APPLICATION_NOT_EVALUATED` (submit first);
- flagged (worse than the threshold) → `QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE`, naming the disposition and pointing at `decision_log`.

## The decisions

- **Threshold: `AUTO_PROCEED` or `AUTO_PROCEED_WITH_FLAG`.** The matrix's `action_taxonomy` makes both explicitly non-blocking ("rating runs normally" / "not blocking"); `INFORMATION_REQUEST` and up route to a human "before any quote is issued." The enum's ascending severity order makes this a single comparison. (None of the five current rules emit `AUTO_PROCEED_WITH_FLAG` yet, so today it effectively means "only `AUTO_PROCEED`" — but the guard is written for the flag so a future flag-emitting rule needs no change here.)
- **`decision_log` is the sole source of truth for the gate — never `applications.status`.** `decision_log` already holds the authoritative referral disposition and survives re-evaluation; gating on `status` would create a second source of truth for the same fact.
- **Minimal status wiring.** `submit_application()` only ever sets `status = 'submitted'`. The richer disposition→status mapping is a deliberate follow-up (see below).
- **The gate reflects the latest evaluation, not necessarily current data.** If an application's data changes without re-submission, the guard uses the last disposition; re-submission is the process norm. No change-detection is built.
- **A below-floor risk is now caught at the referral gate** (EL-01 → `DECLINE_RECOMMENDED`) before rating runs, so it never reaches `compute_indicative_premium()`'s own `RATING_BELOW_AGREED_VALUE_FLOOR` guard — which remains a backstop (exercised directly in `tests/0028`). `tests/0030`-T5 was updated to expect the referral block.

## Contract change to `create_quote()` (ADR 0030)

`create_quote()` now requires a cleared referral evaluation, so every `tests/0030` fixture was updated to `submit_application()` before quoting. This is the intended tightening — a quote can no longer be produced for an application the referral engine has never cleared.

## Not built (confirmed out of scope)

- **Richer disposition→status mapping.** Mapping the referral action onto `applications.status` (`INFORMATION_REQUEST → information_requested`, `MANUAL_REVIEW_* → in_review`, and — with the nuance that `DECLINE_RECOMMENDED` is *recommended, a human confirms* — only `HARD_DECLINE_COMPLIANCE → declined`) would give the lifecycle enum real meaning. A real follow-up, not this pass. `decision_log` remains the gate regardless.
- **Underwriter override / manual release.** When the gate blocks, `create_quote()` fails loud, full stop — there is **no path for a `MANUAL_REVIEW_*` application to ever be quoted**, because no underwriter-facing supervised-release mechanism exists yet. This is a genuine near-term need (a flagged application is currently a dead end), flagged explicitly rather than buried.
- No Odoo submission wizard (`submit_application` is granted to `odoo` for a later one, like bind/cancel/reinstate).

## Testing

`tests/0031_referral_gate.sql` (7 cases): clean submission (`AUTO_PROCEED`, draft→submitted, `submitted_at`, 5 rows, `current_referral_action` agrees); end-to-end quote after clearance; a DUI application blocked (`MANUAL_REVIEW_SENIOR` → `QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE`); never-evaluated blocked (`QUOTE_APPLICATION_NOT_EVALUATED`); re-submission re-evaluating current data (both runs retained); the gate reading the *latest* per-rule run (staged at explicit timestamps — newer-flagged blocks, newer-clean quotes — proving it is "latest", not "ever flagged"); and `submit_application` refusing a non-draft/submitted state. `tests/0030` fixtures updated for the contract change. `scripts/run-tests.sh` runs all suites; all pass.

## Consequences

- The referral engine now actually fires in a real flow, and a flagged application can no longer reach an automatic bindable quote.
- `verify_schema.py` baseline: +2 functions (`submit_application`, `current_referral_action`); `create_quote` gains a guard but is the same object. No new table/type/view/trigger/SET NOT NULL column.
- Next work: the richer status mapping and — more pressingly — the underwriter supervised-release path, without which a `MANUAL_REVIEW_*` application has nowhere to go.
