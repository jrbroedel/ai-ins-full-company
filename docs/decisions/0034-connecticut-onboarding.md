# ADR 0034: Connecticut — the first illustrative state, onboarded end to end

**Status:** Decided; implemented
**Date:** 2026-08-19
**Follows from:** ADR 0025 (the short-rate auto-seed trigger this fires for the first real state), ADR 0028 (territory factors are a manual load, and the rating maths), ADR 0026 (PC-03, the licensed-territory gate), ADR 0030 (a state is not ready for quoting until BOTH its rating-table version and its territory factor exist), ADR 0031 (the referral gate APP-0001 clears)

## ⚠️ Illustrative, not a filing

This is **directional/illustrative demo onboarding, not a real regulatory filing** — the same caveat status as every other illustrative dataset here (`sample-data/state_rating_tables_sample.json`'s 8-state skeleton, the rating workbook's base rates). No real vendor or compliance relationship exists; **nothing here traces to a filed CT rate manual.** Every field not grounded in this project's existing research is marked `TBD`/illustrative in the record itself. Confirmed with Dash: for demo purposes.

## Why CT

Chosen deliberately: the existing clean-risk sample **APP-0001 (Miriam Ostrander, Porsche 911 Turbo S, agreed value $215,000, garaged in Greenwich CT)** in `luxury_auto_sample_applications.json` is CT-garaged. Onboarding CT lets that real reference data flow through the actual pipeline — a concrete, demoable end-to-end proof — rather than a throwaway state connected to nothing.

## What was inserted (idempotent seeds in `postgresql_schema.sql`)

1. **`state_rating_table_versions` for CT** — the compliance-boundary record PC-03 checks. `regulator_name = 'Connecticut Insurance Department'`, `filing_status = 'prior_approval'` (a reasonable, illustrative default matching NY's pattern), `line_of_business_code = 'Private Passenger Auto'`, `serff`/`rate_manual` = `TBD-ILLUSTRATIVE`, an effective range covering now. `credit_based_insurance_score.permitted = true` (no CT credit-score ban is documented in this project's research — marked to-verify, not asserted). `approved`/`prohibited` variables left `[]` (no invented regulatory detail). `ai_governance` carries the **NY DFS Circular Letter 2024-7 documentation standard by default** (this project's baseline design principle: every state is a subset of NY's bar, not a special case), with CT-specific AI guidance marked not-yet-researched. Everything not researched is `TBD`, exactly like the skeleton states.
2. **`territory_factors` for CT — PD factor `1.12`**, from the Exotic/Collector rating workbook's Territory Factors sheet (illustrative). A manual load, per ADR 0028 (territory factors are never auto-seeded, unlike the flat short-rate default).

Both seeds are `INSERT … WHERE NOT EXISTS`, idempotent on re-apply. **Placement is load-bearing:** the CT `state_rating_table_versions` insert sits *after* the ADR 0025 seed trigger in the schema file on purpose — see the gap below.

## The auto-seed trigger fired for real (confirmed, not assumed)

Inserting the CT rating-table version fired the ADR 0025 `state_rating_versions_seed_short_rate` trigger and auto-seeded a **CT `short_rate_factors` row: factor `0.9000`, basis `unearned_premium_multiplier`, band `0.0–1.0`** — the flat 10% holdback. This is the **first time that trigger has run against a real state** rather than a test fixture; verified directly against the live insert (`tests/0034` T2), not inferred from its unit tests.

## The APP-0001 walkthrough — the actual point

APP-0001's real data flowed through the whole pipeline (`tests/0034` T4):
- **`submit_application()` → `AUTO_PROCEED`** (clean history, no DUI, no adverse loss, CT now licensed so PC-03 clears, $215,000 well above the $100k floor).
- **`create_quote()` → premium `$4,179.92`** — the **real computed number** (`production_luxury` → rate class `01 Luxury Sedan/SUV`, $215,000 → the $100k–250k band at base rate `0.92`, × CT's `1.12` territory factor / the `0.53` gross-up). Asserted against `compute_indicative_premium`'s own output, not a hand-guessed figure.
- **The ADR 0029 rating view unpacks it correctly** — `model=indicative_premium_v1`, `class=01 Luxury Sedan/SUV`, `agreed=215000`, `base_rate=0.92`, `territory_state=CT`, `territory_factor=1.12`, `indicative_premium=4179.92`. A real application, not a fixture, showing in the read view for the first time.
- **`bind_policy()` → an active policy** — the full application→quote→policy lifecycle on the first real state.

## Genuine onboarding-flow gaps this surfaced (the other point of the exercise)

1. **No atomic `onboard_state()` — the compliance record and the territory factor are two independent loads with nothing coupling them.** PC-03 checks `state_rating_table_versions`; rating checks `territory_factors`. A state onboarded with only the first (PC-03 clears) but not the second would pass referral and then fail `create_quote` at `TERRITORY_FACTOR_NOT_CONFIGURED`. ADR 0030 already named "a state isn't ready for quoting until BOTH exist" as the precondition — but **nothing enforces the pairing**; onboarding is raw inserts into two tables, and forgetting one is silent until a quote is attempted. A future `onboard_state(...)` helper that loads both together (and lets the trigger seed the third) would make this a single, validated operation. Recorded as the follow-up `state-onboarding-not-atomic`.
2. **Seed placement is load-bearing and implicit.** The short-rate auto-seed only fires if the `state_rating_table_versions` insert runs *after* the ADR 0025 trigger is created in the schema file. A future state seed placed earlier would silently get no short-rate row. An `onboard_state()` function would remove this ordering trap entirely.
3. **Illustrative state data now lives in the core schema file**, intermixed with system reference data, because that is the only persistence mechanism (the `sample-data/*.json` files are pure reference, never loaded). Fine for one demo state; a real onboarding path might want a separate data-load mechanism reading the sample JSON.

## Testing

`tests/0034_ct_onboarding.sql` (4 cases): CT onboarding present/correct (compliance record + 1.12 territory factor, NY-standard AI docs); the short-rate auto-seed fired for CT; PC-03 clears for a CT application **and still fires for an unlicensed state** (the gate narrowed to CT, not weakened for all); and the full APP-0001 walkthrough asserting the real `$4,179.92`. `scripts/run-tests.sh`: all 17 suites pass.

## Consequences

- CT is quotable end to end; APP-0001 demonstrates a real application producing a real premium through the real pipeline for the first time.
- The ADR 0025 auto-seed trigger is confirmed working against a real state.
- No schema-object change (`verify_schema.py` baseline unchanged — data seeds only).
- The biggest surfaced gap — **no atomic, ordering-independent state onboarding** — is the clear next piece of onboarding-infrastructure work.
