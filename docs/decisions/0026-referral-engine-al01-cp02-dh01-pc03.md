# ADR 0026: Referral engine — first four rules (AL-01, CP-02, DH-01, PC-03)

**Status:** Decided; implemented — **superseded in part by [ADR 0036](0036-dh01-reckless-pc03-soft-flag.md)**
**Superseded in part by:** ADR 0036 changed two rule dispositions recorded here: DH-01 now also fires on reckless-driving convictions (this ADR's "DUI-only for now, reckless excluded pending confirmation" is resolved), and PC-03 now routes to `AUTO_PROCEED_WITH_FLAG` rather than `MANUAL_REVIEW_REQUIRED`. AL-01, CP-02, the engine/orchestrator structure, and everything else here still stand. The specific statements below about DH-01's DUI-only scope and PC-03's action are historical as of this ADR's date; see ADR 0036 for current behavior.
**Date:** 2026-08-18
**Follows from:** ADR 0005 (the application-intake schema, `decision_log`, and the `referral_action_t` taxonomy this builds on), the referral matrix `referral-matrices/luxury_auto_referral_matrix.json`, ADR 0025 (PC-03's licensed-state source of truth is `state_rating_table_versions`, which the seed trigger populates on onboarding)

## Scope

The first referral-engine evaluation logic in the project, covering exactly the four confirmed-and-queued rules: **AL-01** (adverse loss history), **CP-02** (aggregate TIV authority cap), **DH-01** (DUI look-back), **PC-03** (out-of-territory). The other 11 rules in the matrix (VV-01…04, DH-02…04, AL-02, CP-01/CP-03, PC-01/02/04) are **out of scope and are future work, not forgotten** — each will be added as its own `evaluate_<rule>()` called from the same orchestrator.

**Almost nothing new was needed structurally.** The application-intake tables (`applications`, `vehicles`, `claims_history`, `person_violations`, …), the append-only `decision_log`, and the `referral_action_t` enum all already existed (ADR 0005). Only the evaluation functions were missing — this ADR is five functions, one contained matrix-JSON correction, and tests.

## The four rules and their sources

| Rule | Condition | Reads | Action when fired | reason_code |
|---|---|---|---|---|
| AL-01 | 2+ at-fault claims in the 5 years before the application date, **or** a single claim's `paid_amount` ≥ 30% of the priciest vehicle's value | `claims_history`, `vehicles.current_appraised_value` | `MANUAL_REVIEW_REQUIRED` | `AL01_ADVERSE_LOSS_HISTORY` |
| CP-02 | Combined appraised value across all vehicles **strictly over** $2,000,000 | `vehicles.current_appraised_value` | `MANUAL_REVIEW_SENIOR` | `CP02_AUTHORITY_LIMIT_EXCEEDED` |
| DH-01 | DUI **conviction** within 5 years, applicant or any additional driver | `person_violations` | `MANUAL_REVIEW_SENIOR` | `DH01_DUI_WITHIN_LOOKBACK` |
| PC-03 | Garaging state has no `state_rating_table_versions` record active at evaluation time | `applications.garaging_state`, `state_rating_table_versions` | `MANUAL_REVIEW_REQUIRED` | `PC03_OUT_OF_LICENSED_TERRITORY` |

## Documented assumptions (business-decision inputs, made visible)

1. **"Agreed value" == `current_appraised_value` throughout the referral engine.** There is no distinct agreed-value dollar column in the schema today (`vehicles` has `current_appraised_value` plus a boolean `agreed_value_requested`), so both AL-01's severity limb and CP-02's aggregate cap use `current_appraised_value` as the dollar figure. This is the confirmed basis for now; if a distinct negotiated agreed-value amount is ever captured, both rules revisit which column they read. AL-01's fallback ("use `current_appraised_value` when agreed value wasn't requested") is Dash's proposed default, treated as confirmed for build — the one inferred piece, recorded as such.
2. **CP-02's $2,000,000 cap is a working default, not final.** Build against $2M now; revisit against the actual delegated binding-authority agreements when they're cross-checked. It is a named literal in `evaluate_cp02()`, easy to change; a future move to a per-program/authority-driven value is possible without reshaping the rule. CP-02's other matrix sub-trigger (umbrella limit) is **not** built here — no confirmed threshold — and remains part of the rule's broader future definition.
3. **AL-01 per-claim denominator = `MAX(current_appraised_value)` across the application's vehicles.** `claims_history` has no vehicle link, so "30% of *the vehicle's* agreed value" is resolved against the priciest vehicle on the application — the conservative choice (largest denominator ⇒ easiest to trip, so it errs toward referral, not away). Claims with a NULL `paid_amount` are skipped in the severity limb (nothing to compare) but still counted in the frequency limb when at-fault.
4. **DH-01 is DUI-only for now — reckless driving deliberately excluded, pending confirmation.** The matrix *trigger* text reads "DUI or reckless-driving conviction," but the confirmed scope and the `reason_code` (`DH01_DUI_WITHIN_LOOKBACK`) are DUI-only, so `evaluate_dh01()` fires on `violation_type = 'DUI'` convictions only and a reckless-driving-only record must not fire (asserted in tests/0026 T3). If the business decides reckless driving belongs here, that is a **follow-up addendum to this ADR**, not a guess made now.

## PC-03: the matrix correction and its current real-world behavior

The matrix JSON had PC-03 routing to `DECLINE_RECOMMENDED`; the confirmed decision is `MANUAL_REVIEW_REQUIRED`. The rule's `action` and `rationale` in `luxury_auto_referral_matrix.json` were corrected to match — a contained two-line edit to that one rule; the other 14 rules and the file's taxonomy/design notes were left untouched. The corrected reasoning: a missing active `state_rating_table_versions` record usually means the compliance data for that state hasn't been built out yet, not that the MGA is actually unlicensed there, so a human confirms the licensing position rather than the pipeline recommending a turn-away.

**Current behavior, stated plainly (expected, not a bug):** `state_rating_table_versions` has zero rows on live, so by PC-03's own definition it **fires on every application, for every state**, until states are onboarded (onboarding also seeds the state's short-rate factor, ADR 0025). Because the confirmed action is `MANUAL_REVIEW_REQUIRED`, those all route to a human rather than a decline — which is the entire point of the corrected action during build-out.

## Evaluation design

**One small function per rule, plus a thin orchestrator** — the project's consistent idiom (small, single-responsibility, individually testable; the same shape as `reinstate_policy` / `link_reinstated_policy` / `cancel_policy`), not a monolithic rule-set evaluator.

- `evaluate_al01/cp02/dh01/pc03(p_application_id, p_decided_by DEFAULT 'system') RETURNS referral_action_t` — each computes its own condition, writes **exactly one** `decision_log` row, and returns its action. `p_decided_by` defaults to `'system'` so a rule is callable as `evaluate_xx(id)` while still satisfying `decision_log.decided_by` (NOT NULL); the pipeline or an underwriter can override it.
- `evaluate_application_referrals(p_application_id, p_decided_by DEFAULT 'system') RETURNS referral_action_t` — calls the four in one transaction and returns the single most-severe action.

**Reason-code / decision-log writing.** Every rule writes a `decision_log` row on **every** evaluation, fired or not — `fired = true` + the rule's action when it matches, `fired = false` + `AUTO_PROCEED` otherwise, with `reason_code` always set. This is the unredacted-audit requirement already baked into `decision_log`'s schema comment (NY DFS Circular Letter 2024-7 / Colorado C.R.S. 10-3-1104.9): "every rule that fires must write a reason_code… even if the ultimate outcome is 'proceed.'" Writing a row even when a rule does *not* fire makes "we checked AL-01 and it didn't trigger" answerable later. Writes happen in the caller's transaction; `decision_log` is append-only (existing triggers), which tests/0026 T6 confirms holds under this new write path. Re-evaluating an application **appends** a fresh set of rows (append-only, latest-by-`created_at` is the current decision), the same discipline `policy_events` uses.

**Severity ordering.** `referral_action_t` is **defined in ascending severity order** — `AUTO_PROCEED` < `AUTO_PROCEED_WITH_FLAG` < `INFORMATION_REQUEST` < `MANUAL_REVIEW_REQUIRED` < `MANUAL_REVIEW_SENIOR` < `DECLINE_RECOMMENDED` < `HARD_DECLINE_COMPLIANCE`. So the orchestrator returns `GREATEST(v_al, v_cp, v_dh, v_pc)`: the most-severe action, and since a non-firing rule returns `AUTO_PROCEED` (the floor), this reduces to "the most severe rule that fired, else `AUTO_PROCEED`." `GREATEST` already handles the full enum, including the four values none of these rules produce (`INFORMATION_REQUEST`, `AUTO_PROCEED_WITH_FLAG`, `DECLINE_RECOMMENDED`, `HARD_DECLINE_COMPLIANCE`), for when later rules are added. This ordering is an **invariant of the enum's definition**; if someone reorders the enum, routing would silently break — so tests/0026 T7 asserts the ordering, turning a reorder into a failing test rather than a mis-route. This severity order matches the taxonomy's intent: "proceed" variants are least interventionist, the two review tiers escalate, and the two decline tiers are the most severe, with the compliance hard-decline (sanctions) at the top.

**The enum ordering was checked against the live type, not assumed.** `referral_action_t` was created by ADR 0005 (a single `CREATE TYPE`, never `ALTER TYPE`d since), and Postgres enums compare by definition order — which this ADR's `GREATEST` depends on but did not establish. The live `pg_enum.enumsortorder` was read and confirmed to be exactly `AUTO_PROCEED(1), AUTO_PROCEED_WITH_FLAG(2), INFORMATION_REQUEST(3), MANUAL_REVIEW_REQUIRED(4), MANUAL_REVIEW_SENIOR(5), DECLINE_RECOMMENDED(6), HARD_DECLINE_COMPLIANCE(7)` — the ascending-severity order documented above, position for position. Today's four rules only ever emit three of the seven values (`AUTO_PROCEED`, `MANUAL_REVIEW_REQUIRED`, `MANUAL_REVIEW_SENIOR`), so tests/0026 T7 additionally exercises `GREATEST` directly across the four **not-yet-produced** values (`HARD_DECLINE_COMPLIANCE`, `DECLINE_RECOMMENDED`, `INFORMATION_REQUEST`, `AUTO_PROCEED_WITH_FLAG`), so the full-enum routing is verified now rather than when a future rule first produces one of them.

## Testing

`tests/0026_referral_engine_al01_cp02_dh01_pc03.sql`, following the BEGIN…ROLLBACK / self-unwinding-DO-block / `IS DISTINCT FROM` conventions. `now()` is the transaction start and constant across the suite, so look-back boundaries are deterministic to the day.

- **T1 AL-01:** frequency limb (2 at-fault claims) fires; severity limb at exactly 30% of the max vehicle value fires; just under 30% with a lone claim clears (boundary mutation); a NULL `paid_amount` claim is skipped in the severity limb without erroring.
- **T2 CP-02:** aggregate just over $2M fires `MANUAL_REVIEW_SENIOR`; exactly $2M clears (strictly-over boundary).
- **T3 DH-01:** applicant DUI conviction fires; an additional driver's DUI conviction fires (spans all drivers); a reckless-driving-only record does **not** fire (narrow scope); a non-convicted DUI does not fire; look-back boundary exact at 5 years (5y fires, 5y+1d clears).
- **T4 PC-03:** fires with no active rating-table record for the garaging state; clears once an active record exists.
- **T5 orchestrator:** exactly four `decision_log` rows per call with the expected fired flags, and the most-severe action wins across two combinations (SENIOR beats REQUIRED; a clean licensed application is `AUTO_PROCEED`).
- **T6:** referral `decision_log` rows are append-only (UPDATE and DELETE both rejected).
- **T7:** the `referral_action_t` ascending-severity invariant and `GREATEST` selection.

`scripts/run-tests.sh` runs all suites; all pass.

## Consequences

- The four confirmed rules evaluate against real application data and write an unredacted, append-only audit trail, with the aggregate routing action returned to the caller.
- The matrix file and the code now agree on PC-03 (`MANUAL_REVIEW_REQUIRED`).
- The other 11 matrix rules are the obvious next work; the orchestrator is the single place each new `evaluate_<rule>()` plugs into.
- Open items explicitly parked: DH-01 reckless-driving inclusion (pending business answer → addendum), CP-02's $2M value and its umbrella-limit sub-trigger, and a distinct agreed-value column should the business ever want one. Translating the returned action into an `applications.status` transition or setting `underwriting_flags.referral_required` is left to the caller/pipeline, deliberately out of this ADR's scope.
- `verify_schema.py`'s baseline moves by +5 functions; no new table, type, view, trigger, or SET NOT NULL column.
