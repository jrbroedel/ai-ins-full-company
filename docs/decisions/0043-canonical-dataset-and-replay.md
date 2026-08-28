# ADR 0043 — Canonical 12-Month Demo Dataset + Replay Mode

**Status:** Accepted
> Headline numbers superseded by ADR 0044 (re-freeze to ~$57M, 2026-08-28); design unchanged.
**Date:** 2026-08-27
**Branch:** demo/investor-preview
**Relates to:** ADR 0042 (corrected commission structure — the money math here applies it);
the existing synthetic generator (this adds a new deterministic mode alongside the live preset
generator); ADR 0041 (dashboard/exporter — new snapshot content feeds it).

## Context

The investor pitch needs a coherent, defensible year of demo data that (a) tells the core
story — premium rate trending down over 12 months while the program stays profitable and the
profit-commission "bonus" stays on track — and (b) is the single source of truth that BOTH the
live dashboard AND Kent's deck/reports derive from, so they cannot disagree.

Kent will build his slides and reports off the artifacts this produces. Therefore the data is
generated ONCE, FROZEN as a committed artifact, and everything downstream (four Excel
deliverables + the live-demo replay) reads from that one frozen dataset. This is the
"generate-once, freeze, derive-everything" principle — it is the reconciliation guarantee.

"Nothing may look fake" is a hard design goal. The strongest defense against that is to derive
figures from Kent's own workbook wherever they exist (his Claims History factor table, his PC
sliding scale, his expense budget, his technical loss ratio) rather than inventing parallel
numbers. Where his model specifies something, we match it.

All data is synthetic and carries the demo markers; production `luxauto` is never touched.

## Decision

### Book size (the sizing parameter)

A representative 12-month operating year of an **established-and-scaling** program (not a
brand-new launch — the number and the pitch must agree on this framing):

- **~2,400 policies bound** over the year, from **~3,300 submissions** (72% bind).
- **~$9,500 average premium** (Kent's own figure) → **~$23M GWP** for the year.
- Grounded in real market data: genuine new specialty MGAs write low single-digit $M in a true
  first year, with breakeven ~$8–15M GWP at 18–36 months; Kent's $60M plan is the mature target,
  not a first year. ~$23M framed as a representative operating year is credible and
  scrutiny-resistant, sitting between a bare startup and the mature plan.

### Data model (five record types)

1. **Submission** — applicant, vehicle, agreed value, garaging state, submitted_at (dated in the
   12-month window), a **loss run** (record 4), a disposition, and a quote (record 2). Every
   submission is rated.
2. **Quote** — premium, plus the derived money split (record type detail in Money Math below);
   exists for binds AND declines ("what it would have cost").
3. **Policy** — one per bound quote only; carries premium, effective date, and accrues
   policy-period claims (record 5).
4. **Loss Run** — the applicant's PRIOR claims history, at submission (backward-looking). ~72%
   clean; the rest carry 1–3 prior claims in a 3–5 year lookback. Drives the disposition.
5. **Policy-Period Claim** — a loss occurring on a bound policy DURING the year
   (forward-looking). Most policies have none. Feeds the loss ratio and the claims BDX.

Key distinction: a **submission has a loss run** (history, at intake); a **policy accrues
policy-period claims** (losses over the year). Same word "claim," two different roles.

### Generation logic (12 months)

- **Disposition mix:** annual ~**72% bind / ~20% decline / ~8% refer** ("Refer to
  Underwriting"). No `MANUAL_REVIEW_REQUIRED` (dropped per Kent). Mix wobbles month-to-month
  (dips/lulls/spikes) but always sums to 100%, hits the annual targets, and respects the ≤20%
  "in underwriting" cap.
- **Dispositions are DERIVED, not imposed:** each submission's loss run is generated from Kent's
  **Claims History factor table** patterns (no-claims → Preferred; 1 claim <$100k / comp-only →
  Acceptable; 1 claim >$100k / theft-total / 2 claims / prior non-renewal → **Refer**; **3+
  at-fault claims → Decline**). The disposition follows the loss run via his rules, so a declined
  submission is genuinely EXPLAINED by its history. Pattern frequencies are weighted to land the
  ~72/20/8 mix. This causality is the primary anti-"fake" mechanism.
- **Bind rate = ~72% of ALL submissions** (auto-proceeds essentially all bind). The dashboard
  "Bind Ratio" tile (bound/quotes) reads ~72% since every submission is quoted.
- **Premium trend:** the rate trends clearly DOWN across the year (~20–30% reduction month 1 →
  month 12) with monthly noise so the trend graph reads as clearly-falling, not artificially
  smooth. Volume ramps/varies month to month toward the ~2,400 annual binds.

### Money math (applies ADR 0042; modeled the WORKBOOK way)

On premium P, per ADR 0042: total commission 25% = **12.5% broker + 12.5% Torque**; **75% to the
markets**. Modeled as Kent's Program Master does it: the full 25% is commission INCOME, the
broker's 12.5% is a distribution EXPENSE (same Torque bottom line, but presented to reconcile
line-for-line with his workbook).

- **Market subdivision:** the 75% is split **10% each across the ten Lloyd's syndicates**
  (Beazley, Hiscox, Chaucer, Ark, Brit, Canopius, Apollo, Antares, MS Amlin, Ascot) — 7.5% of
  premium each — per Kent's instruction to make the panel total 100% at 10% apiece. (The rater's
  original target shares summed to ~162% and were illustrative placeholders; Kent flattened them.)
- **Fees:** policy fee $350/policy and inspection fee $250 for AV ≥ $1M, per his Commission
  Structure sheet, added as fee income where applicable.
- **Loss ratio** = Σ(policy-period incurred losses) ÷ Σ(bound premium), on the bound book only
  (loss runs are underwriting input, NOT in the loss ratio). **Target ~0.56** — Kent's technical
  loss ratio from the rater — under the 0.60 PC hurdle with a modest margin. Tracked cumulatively
  month over month (large losses spike it, quiet months settle it).
- **Profit commission ("bonus"):** Kent's sliding scale — LR <0.40 → 30% of profit; 0.40–0.45 →
  25%; 0.45–0.50 → 20%; 0.50–0.55 → 15%; 0.55–0.60 → 10%; **≥0.60 → 0%**. At ~0.56 LR the bonus
  pays at the **10% band** — "just in the money," the thin-margin story that automation defends as
  premium falls. 3-year deficit carry-forward supported (no-op for a single-year set).

Commission economics were previously kept OFF the demo under the ADR 0039 conflict; ADR 0042
resolved it, so these figures may now appear on the corrected 25% basis.

### The story (one line)

Premium falls all year → commission income (12.5% of a shrinking base) falls with it → but claim
frequency/severity is tuned to hold LR ~0.56 → under the 0.60 hurdle → the bonus keeps paying →
**profitable and bonus-on-track even as rates soften.** Every figure traces to generated
policies and claims; nothing is fabricated independently.

### Two claims dimensions (both required)

- **Loss runs** (historical, at submission, ~72% clean) — drive underwriting decisions and seed
  the predictive-analysis triggers (3+ claims in 3 years; any claim >$1M).
- **Policy-period claims** (on bound policies, over the year) — feed the loss ratio and claims
  BDX. Low frequency (realistic for garaged HNW collector cars), occasional larger losses for
  texture, rare near-$1M+ losses.

### Outputs

Four **Excel** deliverables (Kent's format), all derived from the frozen dataset:
1. **Submissions export** — every submission with full detail.
2. **Monthly rater ×12** — each month's rated business; the declining rate trend visible across
   the twelve.
3. **Underwriting BDX (monthly)** — bound book: premium, the 25% split, 75%-to-markets
   subdivided 10%-each across the ten syndicates.
4. **Claims BDX (monthly)** — policy-period claims: date of loss, incurred, status.

The **P&L / bonus-attainment model** (expenses + revenue + PC band → "on track for the bonus")
is a SEPARATELY-SCOPED later deliverable; this dataset produces its inputs (premium, commission,
losses, LR), but the assembled P&L is its own piece.

### Replay mode (the live-demo mechanism)

- **Generate-and-freeze:** a deterministic (seeded) generation mode produces the full 12-month
  canonical dataset once and writes it as a **committed artifact** — the versioned source of
  truth Kent's deck depends on.
- **Replay:** a new generator mode feeds the frozen dataset's submissions through the real
  pipeline on the demo's timeline, so the live board plays through the canonical year and matches
  Kent's slides (because it IS the data they were built from).
- **Play-forward with pace control** (the 12 months over a few minutes, controllable from the
  control panel) for v1; scrubbing/jump-to-month deferred.
- **Coexistence:** the existing live preset-driven RANDOM generator stays (for open-ended "watch
  it run" demos); replay is a NEW, deterministic mode. The control panel gains a "replay
  canonical year" option alongside the presets.

### Live-demo feed (exporter)

The exporter reads the canonical dataset (in replay) and adds to the snapshot: a monthly
**premium time-series** (feeds the bottom rate-trend graph, 6mo/1yr toggle), the **cumulative
loss ratio**, and **per-state policy aggregates** (feeds the risk-colored national footprint).
Existing snapshot content (tiles, disposition mix, pipeline events, feed) now sources from the
canonical dataset.

## Consequences

- One frozen dataset → four deliverables + the live replay all derive from it → they cannot
  disagree. This is the reconciliation guarantee and the whole point.
- Determinism: seeded generation means every replay is identical; the demo always matches the
  deck.
- The build is staged (generator core → Excel deliverables → replay + exporter → dashboard
  consumers), each verified before the next.
- Anti-"fake" rests on: dispositions derived from Kent's factor table (causal), loss/LR figures
  matched to his model (0.56 technical LR, his PC scale, his expense budget), realistic low HNW
  claim frequency, and a book size grounded in real market data and framed honestly (representative
  operating year, not year-one).

## Not in scope here

- The predictive-analysis ("SHAP") work — its own scoped decision. (This dataset seeds its
  triggers via loss runs, but SHAP itself is separate.)
- The assembled P&L / bonus-attainment model — separate deliverable (inputs produced here).
- Invoicing (per Kent).
- Scrub/jump-to-month replay (deferred; play-forward for v1).