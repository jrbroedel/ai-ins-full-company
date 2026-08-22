# ADR 0037: Referral engine — seven more rules (VV-03, VV-04, DH-03, DH-04, AL-02, CP-01, PC-01)

**Status:** Decided; implemented
**Date:** 2026-08-22
**Follows from:** ADR 0026 (the referral engine pattern and orchestrator this extends), ADR 0028 (EL-01, the fifth rule), ADR 0031 (`submit_application()` and the referral gate — reordered here), ADR 0035 (`onboard_state()` / `agreed_value_rules`, which VV-03 reads live), ADR 0036 (the last rule-logic change; the one-row-per-rule invariant this preserves), the referral matrix `referral-matrices/luxury_auto_referral_matrix.json` (bumped to v1.3 here)

## Scope

Implements seven of the eleven still-unbuilt matrix rules — the seven that read **only fields already present** in the schema. The orchestrator `evaluate_application_referrals()` goes from five rules to **twelve**, one `decision_log` row per rule per call (the invariant the read views' latest-per-rule dedup and every count assertion depend on — unchanged). Same pattern as every prior rule: `SECURITY DEFINER`, existence check, one INSERT, `GREATEST` composition.

**Deliberately NOT in this ADR** (need external data sources that do not exist yet): VV-01 (VIN decode), VV-02 (title history), DH-02 (household driver check), PC-02 (sanctions/OFAC — its own decision, not merely unbuilt), PC-04 (producer verification). Left unimplemented in the matrix JSON; not stubbed.

## The seven rules

| Rule | Action | Fires when |
|---|---|---|
| **VV-04** | `MANUAL_REVIEW_REQUIRED` | a vehicle has a non-blank `modifications` value but `vehicle_category` is still `production_luxury` |
| **DH-03** | `MANUAL_REVIEW_SENIOR` | applicant or any additional driver `license_status` is `suspended` or `revoked` (`expired` does not count) |
| **AL-02** | `MANUAL_REVIEW_REQUIRED` | `prior_insurance.any_nonrenewal_or_cancellation_history` is true (a missing row is not a trigger) |
| **VV-03** | `INFORMATION_REQUEST` | see below |
| **DH-04** | `INFORMATION_REQUEST` | see below |
| **CP-01** | `MANUAL_REVIEW_REQUIRED` | see below |
| **PC-01** | `MANUAL_REVIEW_REQUIRED` | see below |

### VV-03 — currency limb only; the 115% limb is deferred

The matrix's VV-03 has two limbs: (a) agreed value > 115% of appraised value, and (b) appraisal missing/stale. **Limb (a) is not implemented** — there is **no requested agreed-value amount field** anywhere in the schema (only the boolean `vehicles.agreed_value_requested` and `current_appraised_value`; in this data model the agreed value *is* the appraised value). It is deferred pending a `requested_agreed_value` field and its data source, and the matrix JSON records this.

Limb (b) is fully implemented: fire when a vehicle has `agreed_value_requested = true` and `appraisal_date` is null or older than the reappraisal interval. **The interval is read live** from `state_rating_table_versions.agreed_value_rules->>'reappraisal_interval_years'` for the garaging state, **falling back to a 3-year national default** when the state is not onboarded or the value is null/`"TBD"`/non-numeric. Real per-state intervals are expected imminently, so nothing is hardcoded per state; the reference date is `COALESCE(submitted_at, now())`.

### DH-04 — completeness gate, and the `submit_application()` reorder

Fire `INFORMATION_REQUEST` on a **submitted (not draft)** application missing a risk-critical field: applicant `date_of_birth` / `license_status` / `years_licensed`, or any vehicle's `vin` / `garaging_street` (the representative "address provided" check, since `garaging_state` is `NOT NULL` and never absent). A no-vehicle application is out of the vehicle-field limb's scope.

**`submit_application()` was reordered** (ADR 0031's evaluate-then-update → set-status-then-evaluate): it now stamps `status='submitted'`/`submitted_at` **before** calling the orchestrator, so a first submission is evaluated as `submitted` and DH-04 actually gates it — otherwise DH-04 could only ever fire on a re-submission. Safe: no rule other than DH-04 reads status, and the end-state and error/rollback behaviour are identical within the one transaction.

### CP-01 — concrete business-use heuristic

Fire `MANUAL_REVIEW_REQUIRED` on **either** signal: (1) a `pleasure`/`commute` vehicle with `annual_mileage >= 20000` (a business-territory figure); or (2) a commercial-driving occupation keyword (`rideshare/ride-share/uber/lyft/livery/taxi/chauffeur/courier/delivery/real estate/realtor`) **with a single pleasure vehicle** (the matrix's "only vehicle on the policy" qualifier, which cuts false positives). The 20 000 threshold and the keyword list are tunable knobs; the action is human review, not decline, so a false positive is a check, not a harm.

### PC-01 — mismatch, and the `territory_rating_basis` hook

Fire `MANUAL_REVIEW_REQUIRED` when `applications.garaging_state <> applicants.mailing_state` (null mailing_state → not fired — no comparison possible). The `territory_rating_basis` state_override_hook is **descriptive metadata** (e.g. "ZIP+4 mapped to filed territory codes"), not rule logic — a state-vs-state mismatch is coarser than any territory basis, so it does not gate the rule. The matrix's "documented reason" exception (seasonal residence, storage) is not yet representable; the human reviewer weighs it.

## Blast radius — the fixture enrichment (bigger than 0036's 4→5)

Adding two `INFORMATION_REQUEST` rules that read applicant/vehicle completeness had a wide reach: **no existing fixture set `license_status` or `years_licensed`**, and the shared `mk`/`mk_app` helpers inserted applicants with only names and vehicles with no `vin`/`garaging_street`. So before enrichment, DH-04 fired on virtually every submitted-app fixture, flipping "clean → `AUTO_PROCEED`" and blocking every gate-pass/`create_quote` assertion. Confirmed empirically: 9 of 18 suites went red on the bare rule addition.

The fix was to **enrich the fixture helpers** in the ten orchestrator-calling suites (0026–0035 that submit/evaluate) so a fixture meant to be complete populates `date_of_birth`, `license_status='valid'`, `years_licensed`, vehicle `vin` and `garaging_street` — reserving incompleteness for DH-04's own cases in tests/0037. `renewal` (0033) needed only the source fixture enriched: `copy_application_for_renewal` reuses the applicant and copies `vin`/`garaging_street`, so the renewal inherits completeness. `0034`'s APP-0001 additionally needed a current `appraisal_date` (it requests agreed value, so VV-03 would otherwise fire) and `license_status`/`years_licensed`/`garaging_street`. Suites that never call the engine (0007/0017/0018/0021/0023/0024/0025) were untouched.

Row-count assertions bumped **5 → 12** (and 10 → 24 for the two-run case in 0031-T5) in 0026, 0027, 0028, 0029, 0031, 0033. `0029`-T4 Part B is hand-written synthetic rows testing the view's dedup — it stays 5 by construction and was left alone; Part A (real orchestrator) went to 12 with 3 fired unchanged (the enriched fixture keeps the fired set to EL-01/DH-01/PC-03). The read-side view computes `rule_count` as `count(*)` — it adapted with no schema change.

## Testing

`tests/0037_referral_rules_batch2.sql` (8 cases): VV-03 (missing/stale/fresh, agreed-value gate, **live interval vs 3y fallback** — a 2-year-old appraisal fires under a live state interval of 1 but clears under the default), VV-04 (modified/re-categorised/unmodified/blank), DH-03 (suspended/revoked/valid/expired, applicant and additional driver), DH-04 (each missing field, complete, **draft not gated**), AL-02 (true/false/absent), CP-01 (mileage boundary at 20000, occupation+single-vehicle, two-vehicle suppression, clean), PC-01 (mismatch/match/null), and an orchestrator-integration case (twelve rows; clean → AUTO_PROCEED/0 fired; DH-03 trip → MANUAL_REVIEW_SENIOR/1 fired). Ten existing suites updated for the count change and fixture enrichment. `scripts/run-tests.sh`: all 19 suites pass against luxauto-pg.

## Consequences

- The referral engine now covers twelve of sixteen matrix rules; the taxonomy is exercised end-to-end except `HARD_DECLINE_COMPLIANCE` (PC-02, unbuilt). `INFORMATION_REQUEST` now has real producers (VV-03, DH-04) and sits above the `AUTO_PROCEED_WITH_FLAG` gate boundary, so a stale-appraisal or incomplete application is held before auto-quote — intended.
- `submit_application()` now transitions status before evaluating (ADR 0031 → 0037); a re-read of that function should note the DH-04 dependency.
- `verify_schema.py` baseline: **functions 61 → 68** (+7 `evaluate_<rule>()`); no new tables/types/triggers/views.
- Matrix JSON is at **v1.3**: the seven rules carry an `implementation` note; VV-03's deferred limb, CP-01's thresholds, PC-01's hook clarification, and DH-04's submit-reorder are recorded; the five external-data rules remain unimplemented.
