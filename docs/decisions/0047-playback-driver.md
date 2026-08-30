# ADR 0047 — Demo driver: fabrication → playback (reveal the frozen $71M book, never insert)

Status: Accepted — 2026-08-30. Builds on ADR 0046 (the $71M canonical book loaded into luxauto_demo
as the source of truth) and ADR 0041 (dashboard architecture / exporter). Retires the ADR-era
synthetic generator's write path.

## Context
The synthetic generator manufactured NEW applications through the real pipeline
(`materialize` → `submit_application()` → `create_quote()` — the last an **un-softened re-rate**),
growing the book past $71M; and its Reset was `DROP SCHEMA public CASCADE` + rebuild to a curated
5-app seed — which would **destroy the canonical load**. Both hazards put the frozen $71M book at
risk (the 14:46 accidental "running" flip only failed to pollute because the generator's DB
connection was dead). Dash's model: the data lives in the DB; the board is powered by that data;
control paces the **reveal**. So the driver becomes **playback**, not fabrication.

## Decision

1. **A single playback clock — one cursor row.** New tiny table
   `demo_playback_state(id bool PK, current_position timestamptz, mode, updated_at)`. The driver
   advances `current_position`; the exporter reads it and reveals only rows whose authoritative time
   key ≤ cursor. Chosen over a blob: the exporter is already in the DB, so it reads the cursor as a
   query parameter (transactional, no extra round-trip). **The driver's ONLY write anywhere is that
   one row** (plus the idempotent CREATE/seed) — never applications/quotes/policies/decision_log/
   canonical_*. So the book cannot be polluted and every tile foots at all times.

2. **The authoritative time key is `applications.submitted_at`** (app-grain), with
   `lower(effective_range)` for policy-grain (== submitted-month for binds, **0 mismatches**). All
   10,500 subs carry `submitted_at` spanning 2025-08-01 → 2026-07-31. **Claims are revealed WITH
   their policy (ULTIMATE development), never filtered by `date_of_loss`** (which runs to 2027 and
   would recreate the emerged-basis bug killed in STEP FIVE).

3. **Exporter is cursor-aware, additive/back-compat** (`export_dashboard_snapshot.py`). It resolves
   the cursor; **if `demo_playback_state` is absent/NULL, the cursor is a far-future sentinel → the
   whole book is revealed == today's full snapshot** (foots to the artifact). Every query gains a
   `time_key ≤ cursor` filter; `states` (the rating world) is unfiltered so the map grid always
   shows all 50 cells. A new additive `playback` key reports `{active, cursor}`.

4. **Loss-ratio tile stays ULTIMATE, gated for stability** (tightening). LR = Σ incurred(revealed
   policies) ÷ Σ written(revealed policies) — ultimate over the revealed book. Month 1 alone (506
   binds) swings to ~0.86 (small-n), so the tile is **suppressed ("—") until ≥ 1,000 revealed binds**
   (`LOSS_RATIO_MIN_REVEALED_BINDS`), after which it settles in a tight 0.52–0.63 band and lands
   **0.5600** at full. `disposition_mix` / `bind_ratio` read `canonical_load_disposition` **joined to
   `applications.submitted_at`** so the mix is the revealed subset (never full-book while other tiles
   are partial); `time_saving` derives from the revealed `applications_total` so hours-saved grows
   with the year.

5. **Driver (`playback_driver.py` + `playback-driver.sh`).** Long-lived loop: reads the same control
   file; `running` advances the cursor by *speed × elapsed*, `paused` freezes it; preset → base
   reveal speed (surge fast … volume_drying slow), `rate_per_min` scales it; clamps at window end
   then idles (cursor ≥ end → exporter serves full book). **Connection health:** ANY DB error
   (OperationalError **and** InterfaceError / "connection already closed") triggers a reconnect on the
   next tick — fixing the old fabricator's silent-freeze failure mode. Same target guard
   (PGDATABASE=luxauto_demo, refuse prod) + Key Vault creds.

6. **Reset = REWIND, never reprovision.** `--rewind` sets the cursor to 2025-07-31 (empty board). The
   control agent's reset repointed from `synthetic-generator.sh --reprovision --yes` (DROP) to
   `playback-driver.sh --rewind`. The retired generator's `run_loop()` (fabrication) and
   `reprovision()` (DROP) now **hard-refuse** — its shared guard/constants remain for the agent.

7. **Reboot policy.** The playback unit (`luxauto-demo-playback.service`) is read-only against the
   book (writes only the cursor row) → **enable** (safe auto-start). The old
   `luxauto-synthetic-generator.service` is retired: **stop + disable + MASK** so its write + DROP
   path can never auto-start, on reboot or otherwise.

## Consequences
- Committed deliverables: `scripts/lib/playback_driver.py`, `scripts/playback-driver.sh`,
  `infra/systemd/luxauto-demo-playback.service`, and edits to `export_dashboard_snapshot.py`,
  `synthetic_generator.py`, `control-swa/agent/control_agent.py`, plus this ADR. `demo_playback_state`
  is created by the driver (not in the canonical schema); the dashboard `index.html` is unchanged.
- Verified: full playback foots to the cent (GWP 71,301,212.64 / avg 9,314.33 / LR 0.5600 / mix
  7655/789/2056 / bind_ratio 0.729); mid-playback (2026-01-31) is internally consistent and matches
  direct SQL (apps 4,659 / bound 3,404 / GWP 34,667,256.38 / LR 0.5225, mix sums to apps); empty
  (rewind) is valid with no divide-by-zero; **book row counts unchanged (applications still 10,500)**;
  the driver writes only `demo_playback_state`; the generator refuses both paths.
- **Activation is a deploy step (HOLD):** restart the exporter onto this code (the running instance
  predates it — it ignores `demo_playback_state`, so the board is safely full today), install +
  enable the playback unit, and stop/disable/mask the generator.
- Tracked, non-blocking (separate small proposals, NOT this commit): the control-panel copy ("Reset
  wipes and rebuilds", "new applications") is now inaccurate → cosmetic-honesty update; an optional
  play/scrub affordance on the dashboard.
