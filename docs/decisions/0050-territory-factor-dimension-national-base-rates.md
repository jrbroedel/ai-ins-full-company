0050 — Territory-factor dimension; base rates stay national
Status: Accepted Date: 2026-09-03 Related: 0006 (Odoo read-only / SECURITY DEFINER), 0034/0035 (illustrative state data), 0036 (referral matrix). ADRs 0041–0049 live on `demo/investor-preview`; numbering is global.
Context
`onboard_state()` supports exactly one statewide physical-damage territory factor per state, structurally enforced by an exclusion constraint. `rating_base_rates` is a national table with no state column and no per-state ingestion path. These were tracked as two separate gaps for the 50-state rollout. The reference rating workbook (MGA_Program_Master, reviewed 2026-08-23) demonstrates they are one gap: its base rates are national by design (vehicle class × agreed-value band), and ALL geographic variation lives in a three-tier territory structure — statewide factor, metro relativity, ZIP-3 catastrophe-zone multiplier with state-default fallback. Real filed rate manuals similarly express state variation through territory tables, not through per-state base rates.
Decision

1. `rating_base_rates` remains national: base rate = f(vehicle_class, value_band). No state column will be added; no per-state base-rate ingestion path will be built.
2. A territory dimension is introduced with three tiers mirroring the reference design:
   * Tier 1 — statewide territory factor (one row per state; the existing statewide PD factors migrate here unchanged);
   * Tier 2 — metro relativity (named metro areas plus a mandatory rest-of-state default row per state);
   * Tier 3 — ZIP-3 → catastrophe-zone multiplier, with a state-default row where no ZIP-3 mapping exists.
3. New tables: `rating_territory_factors` (state, tier, territory_code, factor, effective-dated and versioned like `state_rating_table_versions`) and `territory_zip_lookup` (zip3 → territory_code / cat zone, plus state-default rows). Uniqueness is (state, tier, territory_code, version); the one-factor-per-state exclusion constraint is dropped as part of the migration.
4. Garaging-ZIP-to-territory resolution is a `SECURITY DEFINER` function with `SET search_path = public, pg_temp` per ADR 0006, returning the three composed factors for a garaging address. The rating chain composes base(class, band) × tier-1 × tier-2 × tier-3, matching the reference workbook's 12-step chain.
5. `onboard_state()` is extended to accept tier rows. Behavior preservation: a state with only a tier-1 row rates exactly as today (tier-2 and tier-3 resolve to 1.0 via the mandatory defaults), so existing CT-era rows are unaffected by the migration.

Consequences

* The 50-state ingestion path becomes: onboard tier rows per state; base rates never change per state. This is the keystone decision for the 50-state initiative.
* All tier factors remain illustrative/synthetic under the ADR 0034/0035 labeling discipline until real filed manuals are ingested; nothing in this decision implies real filed data exists for any state.
* The referral matrix's `territory_rating_basis` hook (PC-01) can now resolve to concrete territory codes instead of state-level only.
* Implementation is a follow-on migration + function change set; this ADR fixes the shape, not the schedule.
