# ADR 0028: Rating engine v1 — minimal core (base rate × territory factor → indicative premium)

**Status:** Decided; DB-side implemented
**Date:** 2026-08-18
**Follows from:** ADR 0005 (application intake, `vehicles.current_appraised_value`), ADR 0007 addendum (the 30% acquisition-commission structure this gross-up uses), ADR 0025 (short-rate seeding — the fail-loud pattern territory factors follow), ADR 0026 (the referral engine EL-01 plugs into), ADR 0027 (the vehicle-category enum this maps from)

## v1 scope, and what is deliberately deferred

v1 computes an **indicative premium** = `base rate (rating class × agreed-value band) × per-state territory factor / 0.53 gross-up`, with a **$100,000 agreed-value eligibility floor** below which a risk is declined rather than rated. For a clean risk the number is final and bindable unless a referral rule fires.

**Deliberately deferred, and this is v1 scope not an oversight** (the source workbook's full algorithm has 28 factors): driver/claims factors, deductible factors, cat-zone load, ALAE/ULAE, risk margin, liability loss cost, and the underwriter-judgment adjustment — everything in the workbook's steps 2–9 and 11. **Multi-vehicle aggregation is also out of v1** — the function rates one vehicle. This is stated plainly so a future reader does not mistake v1 for the full technical premium the source material describes.

**Naming: `indicative_premium`, not "technical premium."** In the source material "technical premium" means the full multi-factor calculation (step 10 of a 28-factor algorithm). v1 is a deliberate simplification, so calling its output "technical premium" would overload a term that means something more specific. The function, its variables, and the stored `rating_basis.model` all say `indicative_premium`.

## The gross-up: 30% acquisition (0.53 divisor), overriding the workbook's 27.5%

`indicative_premium = loss_cost / 0.53`, where `0.53 = 1 − (target profit 10% + reinsurance 5% + admin 2% + acquisition commission 30%)`. The workbook's specimen used **27.5%** acquisition (a 0.555 divisor); this uses **30%**, because ADR 0007's addendum makes broker + MGA commission sum to **exactly 30% by schema construction** (`mga_commission_rate GENERATED ALWAYS AS (30 − broker_commission_rate)`). Using the platform's own confirmed commission cap — not the workbook's illustrative example figure — keeps the rating gross-up consistent with what the system actually charges in acquisition commission.

## Reference data — illustrative benchmarks, not filed rates

Every loaded rate number carries a `source_reference`: *"Illustrative underwriting benchmark, not actuarially certified — see workbook README disclaimer,"* matching the source material's own repeated disclaimer and the treatment every other illustrative dataset here gets. These are not filed rates.

## Schema

### `rating_base_rates` — keyed by a 12-class taxonomy, independent of the enum

Base rate per $100 of agreed value, keyed by `rating_vehicle_class` (1–12) × value band `[lower, upper)`. The 84-row benchmark table (12 classes × 7 bands) is loaded from the confirmed figures. It is keyed **independently of the 6-value `vehicle_category` enum** because the workbook's 12 classes are finer than the enum and don't align 1:1 — keying on the enum could neither hold all 12 nor future-proof for classes not yet in the enum. An `EXCLUDE` constraint forbids overlapping bands per class per effective period.

### `vehicle_category_rating_class` — the enum → class mapping (5 of 6)

A data-driven mapping (no `CASE` — the anti-pattern ADR 0027 flagged), so a new enum value is a new row and an unmapped category fails loud. Five categories map; **`modified_performance` deliberately has no row** (confirmed: not worth a rate class in v1):

| category | rating class |
|---|---|
| `production_luxury` | 01 Luxury Sedan/SUV |
| `exotic` | 03 Supercar |
| `classic_collector` | 07 Post-War Classic (1946–1972) |
| `pre_war_vintage` | 06 Vintage Pre-War |
| `restomod_coachbuilt` | 11 Restomod/Coachbuilt |
| `modified_performance` | **(none — not auto-rateable in v1)** |

`modified_performance` **stays a valid intake category** — it is not removed from the enum; it just can't be auto-rated, and `compute_indicative_premium()` raises `RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY` rather than guessing or silently substituting a class. The other 6 rate classes (finer classes with no current enum value) sit loaded-and-ready for when those categories are added — the future-proofing the 84-row load buys.

### `territory_factors` — manual load, fail-loud, one placeholder

Per-state PD territory factor `(state, pd_territory_factor)`. **Loaded manually per state as part of onboarding — NOT auto-seeded** like the short-rate factor. The short-rate seed works because 10% is a flat default that is the same everywhere; territory factors are real, per-state, proprietary rate content with no sensible universal default, so a neutral 1.00 auto-seed would silently mis-price real business (the "looks more capable than it is" trap). Instead the lookup **fails loud** (`TERRITORY_FACTOR_NOT_CONFIGURED`) for any state with no row — same philosophy as `short_rate_factor()`, opposite mechanism (no trigger). v1 ships exactly one row: test state **`T0`**, factor **1.00** (neutral, so v1 numbers hand-check cleanly). `T0` contains a digit, so it structurally cannot collide with a real USPS state code.

## The eligibility floor — enforced twice

The $100,000 floor is both a hard gate and an auditable decision, so it lives in **two** places:

1. **A hard guard in `compute_indicative_premium()`** — below $100,000 it raises `RATING_BELOW_AGREED_VALUE_FLOOR`; an ineligible risk can never be rated ("declined rather than rated," the source's own language).
2. **An audited referral rule, `EL-01`** (`EL01_BELOW_AGREED_VALUE_FLOOR` → `DECLINE_RECOMMENDED`), wired into `evaluate_application_referrals()` as a fifth rule alongside AL-01/CP-02/DH-01/PC-03. It fires when any vehicle's agreed value is below the floor, writing a `decision_log` row like every other rule — so the decline is in the audit trail, not just an error. `DECLINE_RECOMMENDED` (not a pure auto-decline) keeps a human accountable, matching the matrix's "no auto-decline except sanctions" philosophy; and since it is the most severe action any current rule emits, it dominates the orchestrator's `GREATEST` when it fires. A NULL/unknown agreed value is *not* a floor violation (that is a missing-data question, not this rule's).

This is the only change to a prior-ADR function in this work — the orchestrator gains the EL-01 call, confirmed in scope. CP-02 is untouched.

## The computation

```
indicative_premium = ROUND( (agreed_value / 100) × base_rate(class, band) × territory_factor(state) / 0.53 , 2 )
```
`compute_indicative_premium(vehicle_category, agreed_value, state, as_of)` returns the premium, the resolved class, the base rate and territory factor used, and a JSONB `breakdown` (every component plus the "indicative v1, not technical premium" and "illustrative benchmark" notes) for storage in the existing `quotes.rating_basis`. The premium itself lands in the existing `quotes.premium_amount` — no new premium column. **Worked example:** `exotic` (→ class 03) @ $600,000 in `T0` → band `$500k–1M`, rate 0.95 → `600000/100 × 0.95 × 1.00 / 0.53 = $10,754.72`.

## Not built (confirmed out of scope)

- Any factor beyond base × territory (no ALAE/ULAE/cat/risk-margin/liability/underwriter-judgment).
- Multi-vehicle aggregation (v1 rates one vehicle).
- **No $2,000,000 single-vehicle auto-bind rule** — confirmed dropped entirely. CP-02's aggregate-value-across-vehicles cap (ADR 0026) is untouched and remains the only $2M-related rule in the system; the two were never the same rule.
- The 5× composite rating-factor cap — noted for the future; irrelevant to v1, which has no composite factor chain.
- No territory factors for any state beyond the `T0` placeholder; no Odoo view (deferred to the batched read-side pass).

## Testing

`tests/0028_rating_engine_v1.sql`: the worked example asserted against the formula rebuilt from the function's own returned components (10754.72); the floor boundary ($100,000 rates, $99,999.99 declines from the rating function); EL-01 firing through `evaluate_application_referrals()` (DECLINE_RECOMMENDED, logged, five rows now) and not firing above the floor; `modified_performance` raising `RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY` while staying a valid intake enum value; an unconfigured state raising `TERRITORY_FACTOR_NOT_CONFIGURED`; and all 84 base-rate rows loaded with a spot-check across classes/bands and the disclaimer present. `scripts/run-tests.sh` runs all suites; all pass.

## Consequences

- The system computes an indicative, bindable premium for the five mapped categories in a configured territory; it fails loud (never guesses) for an unmapped category, an unconfigured state, or a below-floor risk.
- `verify_schema.py` baseline: +3 tables, +2 functions; no new type/view/trigger/SET NOT NULL column.
- The obvious next work is the deferred factors (turning indicative into technical premium), multi-vehicle aggregation, real per-state territory loading during onboarding, and the batched Odoo read-side. Each is called out above as deferred, not forgotten.
