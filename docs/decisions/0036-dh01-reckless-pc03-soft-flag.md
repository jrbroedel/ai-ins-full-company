# ADR 0036: Referral matrix rule adjustments — DH-01 reckless driving; PC-03 soft-flag

**Status:** Decided; implemented
**Date:** 2026-08-22
**Follows from:** ADR 0026 (the referral engine and the DH-01/PC-03 rule bodies this edits), ADR 0028 (EL-01, which co-fires with these rules and still dominates the combined disposition), ADR 0031 (the referral gate whose block boundary PC-03's new action sits below), ADR 0035 (`onboard_state()` — the front door a state must go through before it can be rated, which is what PC-03's change does *not* substitute for), the referral matrix `referral-matrices/luxury_auto_referral_matrix.json` (bumped to v1.2 here)

## Scope

Two independent, already-decided business-rule changes to the referral matrix's rule-evaluation layer, shipped together because they touch the same two functions, the same single test suite (`tests/0026`), and the same matrix JSON — but they come from **different sources** and are kept separate below so neither is buried.

Both are edits to existing rule bodies (`CREATE OR REPLACE`, same signatures). No new functions, triggers, tables, enums, or grants — the `verify_schema.py` baseline is unchanged.

---

## Change 1 — DH-01: fold reckless driving into the DUI look-back

**Source:** the insurance-domain colleague, by email: *"Same five year look to keep it simple."*

### Decision

DH-01 previously fired `MANUAL_REVIEW_SENIOR` only on a **DUI** conviction within a 5-year look-back (national default), across the applicant and every additional driver. It now **also** fires on a **reckless-driving** conviction — the *same* 5-year look-back, the *same* `MANUAL_REVIEW_SENIOR` severity, the *same* conviction requirement. No separate threshold, per the colleague's "keep it simple." This brings the executable rule in line with the matrix's DH-01 trigger prose, which already read "DUI **or reckless-driving** conviction."

`reckless_driving` was already a first-class value of the `violation_type_t` enum (`DUI`, `reckless_driving`, `speeding`, `other_moving_violation`), so this is a predicate broadening — `violation_type IN ('DUI','reckless_driving')` — not a schema change. The 5-year window remains a hardcoded national default; DH-01 does **not** read the per-state `dui_lookback_years` override (a pre-existing gap, still tracked as an open item in the matrix JSON, deliberately out of scope here).

### Reason-code shape: distinct sibling code, one row (the invariant that forced this)

`decision_log`, `current_referral_action()`, and `luxauto_application_referral_view` all assume **exactly one row per `rule_id`** (`DISTINCT ON (rule_id) … ORDER BY created_at DESC`), and multiple suites hard-assert "5 decision_log rows per orchestrator call." A second `'DH-01'` row for reckless would break the latest-per-rule dedup and every row-count assertion. So DH-01 stays **one row**, and the distinction is carried in the `reason_code`, not in a second row:

- a DUI conviction in-window → `DH01_DUI_WITHIN_LOOKBACK`
- a reckless-driving conviction in-window (no DUI) → `DH01_RECKLESS_WITHIN_LOOKBACK`
- **both** present → `DH01_DUI_WITHIN_LOOKBACK` (DUI takes precedence — it is the more serious, SR-22/FR-44-implicating conviction)
- the non-firing audit row keeps the rule's canonical `DH01_DUI_WITHIN_LOOKBACK`

The matched type(s) are recorded in the row's `notes` (`matched_types=[…]`) regardless. This keeps the audited artifact — the `reason_code`, which rule 4 and the matrix `design_note` lean on for adverse-action and market-conduct answerability — **honest**: a reckless-only referral is never labeled "DUI." The read-side views key on `rule_id`, not `reason_code`, so a varying code is invisible to the gate and the dedup.

We considered but rejected reusing `DH01_DUI_WITHIN_LOOKBACK` for both (simpler, but mislabels a reckless-only referral) and a separate second row per type (breaks the one-row-per-rule invariant three ways).

---

## Change 2 — PC-03: out-of-territory becomes a soft-flag

**Source:** founder (Dash) directive, reframed here around the platform's actual v1 scope.

### Decision

PC-03 fires when the application's garaging state has no active `state_rating_table_versions` record. It previously routed to `MANUAL_REVIEW_REQUIRED`; it now routes to **`AUTO_PROCEED_WITH_FLAG`**. The rule still **fires**, and still writes its `PC03_OUT_OF_LICENSED_TERRITORY` reason_code to the decision log unredacted (matrix rule 4) — the change is only the *action*, from "route to a human before proceeding" to "attach the flag to the file for later review, don't block."

### Framing — this is the right interim disposition, not a demo-only carve-out

The platform's **v1 scope is all 50 US states**. CT was a proof-of-concept onboarding (ADR 0034/0035), not the intended limit. During the rollout there will legitimately be many states that have not yet been onboarded, and for those states "no active `state_rating_table_versions` record" is the **expected interim condition**, not evidence the MGA is unlicensed. Routing every such application to a senior-of-a-human review before it can even proceed is the wrong default at this stage — it makes the pipeline's most common early-rollout state look like a red flag. `AUTO_PROCEED_WITH_FLAG` records the fact for audit and moves on, which is the correct disposition for a licensing gap that is a rollout-progress artifact. This **resolves** the matrix's standing `open_items_for_underwriting_leadership` question ("PC-03 … hard-block or soft-warn during early build-out") in favor of **soft-warn**.

### Consequence — this does NOT make an un-onboarded state quotable (explicit)

PC-03's new action lowers it *below* the ADR 0031 referral-gate block boundary (`> AUTO_PROCEED_WITH_FLAG`), so an application in an un-onboarded state with no other trigger now passes the *gate*. **It still cannot be quoted.** `create_quote()` requires a real rating record and a territory factor, and fails with `TERRITORY_FACTOR_NOT_CONFIGURED` for any state that has not gone through `onboard_state()` (ADR 0035). PC-03 firing ⇔ no rating data ⇔ that same `create_quote()` failure downstream. So the practical effect of this change is on the **disposition a flagged application displays** (proceed-with-flag instead of manual-review-required), not on whether a not-yet-onboarded state can produce a quote. The full 50-state rollout — actually onboarding those states' rating data — is tracked as its **own separate initiative**, not part of this ADR.

`AUTO_PROCEED_WITH_FLAG` with `fired = true` is a `(action, fired)` combination no rule emitted before this ADR; there is no CHECK constraint tying the two, so it is structurally valid, and `tests/0026` T4 now asserts it explicitly rather than leaving it implied.

---

## Testing

`tests/0026_referral_engine_al01_cp02_dh01_pc03.sql` was the only suite asserting the changed behavior (every other real-orchestrator suite either onboards its garaging state so PC-03 stays dormant, or is dominated by EL-01/DH-01 in the `GREATEST()`, so neither change moves its asserted outcome — verified across all 18 suites during investigation):

- **T3 (DH-01)** — case (c) inverted: a reckless-only conviction now fires `MANUAL_REVIEW_SENIOR` with reason_code `DH01_RECKLESS_WITHIN_LOOKBACK`. Added: (c2) DUI+reckless both present → fires, reason_code `DH01_DUI_WITHIN_LOOKBACK` (DUI precedence); (d2) non-convicted reckless does not fire; (e2) reckless 5-year boundary is inclusive at exactly 5 years and excludes one day earlier — mirroring the DUI boundary. The DUI firing path now also asserts its reason_code.
- **T4 (PC-03)** — expected action updated to `AUTO_PROCEED_WITH_FLAG`, with an explicit row-level assertion that the fired row is `fired = true` **and** `action_taken = AUTO_PROCEED_WITH_FLAG` **and** carries `PC03_OUT_OF_LICENSED_TERRITORY` (the new fired+proceed-with-flag combination, asserted not implied). The clear-once-onboarded half is unchanged.
- **T5 (orchestrator)** — combo-1's stale "PC-03 → REQUIRED" comment corrected to "→ WITH_FLAG"; the assertion is unchanged and still passes because DH-01's `MANUAL_REVIEW_SENIOR` still dominates the combined disposition.

## Consequences

- DH-01 now covers both serious conviction types on one look-back, with a type-honest reason_code and no change to the one-row-per-rule contract.
- PC-03 is a soft-warn: un-onboarded states no longer block at the referral gate, but remain un-quotable until `onboard_state()` loads their rating data. The `renewal-risk-data-not-refreshed` and other referral-adjacent memories are unaffected.
- Matrix JSON is at **v1.2** (DH-01 trigger/threshold/reason_code, PC-03 action/rationale, the resolved open item, and a changelog entry recording both changes and their distinct sources).
- `verify_schema.py` baseline unchanged (both functions were `CREATE OR REPLACE`d in place; no new objects).
