# ADR 0048 — Data-driven scenario engine on the playback driver

Status: Accepted — 2026-08-30. Builds on ADR 0047 (playback driver / cursor) and ADR 0046 (the
frozen $71M book). BUILD staged on `demo/investor-preview`; not activated (separate step).

## Context
The playback driver (ADR 0047) reveals the frozen book chronologically by a single cursor. We want
named "scenarios" that tell different investor stories — WITHOUT fabricating rows or mutating the
book. A scenario is a data row: it changes PACE (how the driver advances the cursor) and, optionally,
a generic OVERLAY (per-metric per-month multipliers the exporter applies to displayed magnitudes at
build time). Adding a scenario later should be one INSERT — no code, no deploy.

## Decision

1. **`scenario_defs(name PK, pace JSONB, overlay JSONB, is_modeled BOOL, label, updated_at)`** —
   seeded idempotently in committed code (`scripts/lib/scenario_seed.py`, `ensure_scenarios`), same
   pattern as `demo_playback_state`. The driver reads `pace`; the exporter reads `overlay`;
   `is_modeled` drives the board marker. `demo_playback_state` gains a `scenario` column the driver
   writes each tick, so the exporter reads cursor + scenario in ONE query (no blob dependency).

2. **Reveal stays chronological by `submitted_at`.** A scenario NEVER reorders — it changes PACE and
   MAGNITUDE only.
   - **PACE** (driver): `pace.speed_scale` multiplies the base reveal speed; `pace.mode:"taper"` with
     `late_factor` slows the advance in the operating year's second half (volume_drying); `rate_per_min`
     still scales speed so the panel's rate slider bends pace.
   - **OVERLAY** (exporter), applied **row-wise by the row's effective/submitted month, then
     aggregated** — a uniform, composable model: every revealed row is weighted by `volume[m]`;
     dollars additionally by `premium[m]` (premiums) or `loss[m]` (incurred); `rate_trend` per-month
     avg by `premium[m]`. Absent metric/month = 1.0. Concretely:
     - `premium[m]` → `written_gwp`, `avg_premium`, `rate_trend.avg`, and the **LR denominator**
       (premium↑ → LR↓, a coherent "rates firming" story). NOT TIV (asset value ≠ price), counts, or mix.
     - `loss[m]` → `incurred` → **LR numerator only**.
     - `volume[m]` → month m's revealed counts AND its dollar slices together, so avg/bind_ratio/LR
       stay ~invariant; counts round to int (⇒ modeled). Generic/reserved — no seed uses it, but wired
       and tested (a throwaway 6th scenario proved it).
   - **Non-overlay (all factors 1.0 / overlay NULL) → identity → byte-identical to today's full-book
     snapshot** → steady/surge/volume_drying foot to the artifact at full playback.

3. **Five seeded scenarios:** `steady` (pace 1×, none), `surge` (pace 3×, none), `volume_drying`
   (taper, none), `premium_rising` (premium ramp, modeled), `stress` (loss spike, modeled).

4. **Start-empty:** the driver seeds the cursor to `REWIND_POSITION` (2025-07-31) so the board opens
   empty and plays up.

5. **Modeled marker:** the snapshot gains `scenario:{name,label,is_modeled}`. The dashboard shows
   "<label> · modeled figures" when `is_modeled`, a plain "Scenario · <label>" otherwise; the
   **synthetic footnote always stays** (double-labeling for the one non-measured surface).

## Two refinements

- **Mix re-scope (documented plainly).** Under playback, scenario differentiation is **pace +
  magnitude overlay, NOT mix character**. The old fabricator's mix-skew presets (stress → more
  declines, surge → more auto-proceed) do **not** carry over — they were achieved by generating
  different-character rows, which playback cannot do. `stress` is now a **loss overlay** (LR bends),
  not a decline skew. The generic overlay *could* express a per-disposition "mix" factor later as an
  available extension dimension — that is a capability, not a gap.

- **control.js seam — FIXED via option (b).** control.js has **no DB access by design** (the bright
  line: "structurally incapable of touching a database"), so it can't read `scenario_defs` directly.
  Instead the VM **agent publishes the live scenario list into `status.json`** (which control.js
  already reads), and control.js validates `preset` against that published list (falling back to the
  committed five if status is unavailable). `control_agent.validate_intent` also validates against
  `scenario_defs`, and the control panel renders its buttons from the published list. **Result: a 6th
  scenario added by INSERT is selectable end-to-end — API, agent, driver, exporter — with zero code
  change.** No SWA API restructuring was needed; the bright line is intact (the API reads a blob, never
  a DB).

## Seed model (a known, intended property)
The five presets live in **committed code**, so a DB rebuild recreates them. A scenario added later by
a bare **INSERT into the running `luxauto_demo` lives ONLY in the demo DB and is NOT in git** — a
rebuild recreates only the seeded-in-code five unless this seed is updated. That is the data-driven /
no-deploy tradeoff by design: instant new scenarios in the live demo, at the cost of them not
surviving a from-scratch rebuild until promoted into `scenario_seed.py`.

## Consequences
- Files: **new** `scripts/lib/scenario_seed.py`, this ADR; **modified** `playback_driver.py`,
  `export_dashboard_snapshot.py`, `control_agent.py`, `control-swa/api/src/functions/control.js`,
  `control-swa/frontend/index.html`, `dashboard-swa/frontend/index.html`. `snapshot.js` unchanged.
- Engine writes ONLY scaffolding (`scenario_defs` + `demo_playback_state`); the driver/exporter are
  read-only against the book. No dataset/artifact/BDX/rater regeneration.
- Verified: steady @full foots to the cent (GWP 71,301,212.64 / avg 9,314.33 / LR 0.5600 / mix
  7655/789/2056 / bind_ratio 0.729); stress @2026-01-31 bends LR 0.5225→0.6577 (numerator only,
  GWP/bound unchanged); premium_rising ripples (avg↑, GWP↑, LR↓); mid consistency (mix sums to apps);
  book row counts unchanged (10,500); a throwaway 6th scenario honored by driver+exporter+agent+control.js
  with no code change (and exercised `volume`).
- Activation remains a SEPARATE deploy step (ADR 0047): restart the exporter onto this code, install +
  enable the playback unit, stop/disable/mask the generator, redeploy the control + dashboard SWAs.
