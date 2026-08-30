# ADR 0045 — Canonical dataset re-freeze at ~$71M by volume

Status: Accepted — 2026-08-30. Supersedes the headline numbers of ADR 0044 (design and economics unchanged).

## Context
Kent wants the demo book to read larger — target ~$71M GWP — without changing any of the economics
the prior ADRs pinned. The ADR 0044 artifact was ~$57M. This is a scope change (bigger book, same
economics), not a fix to a downstream deliverable: the book is regrown purely by binding more
business, holding average premium, disposition mix, rate softening, loss ratio, PC band and the
commission stack.

## Decision
1. One-knob volume regrow. `CANON_SUBMISSIONS` 8414→10500. Everything else held and passed
   EXPLICITLY (main()'s defaults are wrong for this book): `CANON_VALUE_SCALE=1.9`,
   `CANON_CLAIM_FREQUENCY=0.056`, `CANON_SEED=20260827`. No other parameter moved.
   New book: **10,500 subs / 7,655 bound / $71,301,212.64 GWP / $9,314.33 avg / 72.9-19.6-7.5 mix**.
   sha256 `faa3c9b7f4d50478223133535cb16904b63533f656f3a522176ef0d756814095`.
   Supersedes the $57M ADR 0044 set.

2. Economics are volume-independent by construction. The generator solves for the loss ratio
   (it scales claim severities so `target_incurred = 0.56 × GWP`), so LR re-lands at 0.5600 and PC
   band at 10% at any volume; average premium and disposition mix are draws, not functions of N.
   The LR-probe implied_scale for this book was **1.0200** (well inside the [0.75, 1.35] clamp),
   confirming 0.5600 is achieved with negligible severity distortion, not a forced fit.
   `value_scale` (agreed-value multiplier) and `claim_frequency` (per-policy claim rate) were held
   because moving either would change the economics; only bind volume was allowed to move.

3. Premium-trend definitions (unchanged pins; realized value re-derived for this draw).
   - Modeled rate softening (`softening_index`): −23.9% m1→m12 — byte-identical to the v1/0044 draw
     for seed 20260827 (drawn before the book loop; independent of N). This is the price line.
   - Realized average bound premium: **−29.2%** m1→m12 = rate × mix (0044 was −30.0%; the small move
     is this book's late-year mix, nothing economic). Narrate as "price down ~24%, mix drove the
     average lower still." Both true.
   - Loss ratio 0.5600 = incurred ÷ written GWP (bound book; earned==written). Same value and PC
     band (10%) as 0044; the workbook technical-LR distinction from 0044 §3 still holds.

4. Unchanged from 0044 (explicitly not touched): loss model (`claim_frequency=0.056`), value_scale
   (1.90), seed, syndicate panel (even 10%-each / 7.5% of premium ×10 = 75%), commission stack,
   and the 24-file deliverable design (Option B: our data/logic authoritative; Kent's workbooks are
   layout/reference; the sample rater displays the artifact build, does not run his live 12-step chain).

## Consequences
- Replay engine re-pinned to `faa3c9b7…`; `RECON_TARGETS` updated (submissions 8414→10500,
  bound 6089→7655, gwp →$71,301,212.64, avg →$9,314.33, incurred →$39,928,679.10, LR 0.5600,
  premium-trend −30.0%→−29.2%); `replay_reconciliation.json` regenerated and reconciles clean
  (all gate checks PASS). Console/label strings moved "ADR 0043/0044 targets" → "ADR 0045 targets".
- 24 deliverables rebuilt off the new artifact via the surgical raw-XML path into Kent's own
  templates (all tabs / x14 dropdowns / charts preserved byte-for-byte; NOT the openpyxl path):
  each UW BDX foots to the artifact to the cent (Σ12 = $71,301,212.64), and each sample rater ties
  to the artifact by construction. Submissions export rebuilt (`submissions_all_20260830.xlsx`,
  10,500 rows, bound Σ GWP = $71,301,212.64); the stale `submissions_all_20260828.xlsx` removed.
- Generator provenance updated: artifact and manifest `adr` fields 0043→0045; module docstring
  refreshed to the $71M / value_scale=1.9 reality.
- The commission net-to-panel framing note (0039 30%/gross×0.70 vs 0042 25% model) is unchanged and
  still must not appear side by side without a note.
