# ADR 0044 — Canonical dataset re-freeze at ~$57M; loss-model recalibration; definition pins

Status: Accepted — 2026-08-28. Supersedes the headline numbers of ADR 0043 (design unchanged).

## Context
Kent's threshold: to draw investor attention the book must read in the $50–60M range; target ~$57M.
The ADR 0043 canonical artifact was ~$23M. Rescaled by VOLUME only (submission count), holding
average premium, disposition mix, rate softening, and the commission stack.

## Decision
1. Volume rescale. CANON_SUBMISSIONS 3300→8414; value_scale 1.90 and seed 20260827 unchanged.
   New book: 8,414 subs / 6,089 bound / $56,932,078.70 GWP / $9,349.99 avg / 72.4-20.1-7.6 mix.
   sha256 0a3d67e8774e8cd15fba1c8ab9fa484cd433ac71665a04ca040d9db96b3a9811. Supersedes the $23M v1 set.
2. Loss-model recalibration (authorized deviation from volume-only). Added CANON_CLAIM_FREQUENCY
   env knob (default 0.04, so the v1 book still reproduces byte-for-byte); recalibrated to 0.056.
   Rationale: 0.04 was a point-fit only N=3300 satisfied by tail-luck; at larger N fresh draws
   centered raw LR ~0.40 and blew the 0.75–1.35 scale clamp. 0.056 centers raw LR ~0.55. Seed-to-seed
   fat-tail variance (~±0.04) is irreducible without flattening the severity tail — declined, because
   the fat tail is the HNW loss story. Canonical seed 20260827 is a representative (median) draw at
   realized scale 1.000, so 0.5600 is achieved with negligible severity distortion, not a forced fit.
3. Premium-trend definitions (pins).
   - Modeled rate softening (softening_index): ~−24% m1→m12, byte-identical to v1 for seed 20260827
     (drawn before the book loop; independent of N). This is the price line.
   - Realized average bound premium: −30.0% m1→m12 = rate × mix; this draw's late-year book skewed
     to lower-value cars, so the average fell more than rate alone. Narrate as
     "price down ~24%, mix drove the average lower still." Both true.
   - Loss ratio 0.5600 = incurred ÷ written GWP (bound book; earned==written). Distinct from the
     workbook's technical LR (pure risk premium ÷ charged GWP, 0.560364) — same value to 2 d.p.,
     same PC band (10%). The emerged-to-date cumulative_loss_ratio field stays non-authoritative.
4. Syndicate panel. The even 10%-each split (7.5% of premium per syndicate ×10 = 75%) is Kent's
   deliberate flattening of his workbook's unbalanced panel (which summed to ~160%), matching his
   Ferrari example — NOT an invention. Retained as-is.
5. Deliverables restyle. The four Build 2 files were restyled to MGA Program Master conventions
   (Arial; navy title banners; blue section headers; semantic tab colours; 1-dp dash-for-zero formats).

## Consequences
- Replay engine re-pinned to 0a3d67e8; RECON_TARGETS + replay_reconciliation.json regenerated;
  premium-trend reconciliation target moved −23.5% → −30.0%.
- OPEN (separate slice): per Kent 2026-08-28 (phone), the department deliverable is 24 files rendered
  read-only from this artifact — 12 monthly underwriting BDX workbooks (separate files, bound business
  only, every policy a row with the full premium-bordereau field set incl. the 12.5/12.5/75 split and
  the ten syndicate participations) plus 12 monthly sample-rater workbooks (one bound account each,
  laid out in his rater format, reproducing that account's artifact premium so it verifies against the
  same BDX row). Decision (Option B): our data and locked-in logic are authoritative; his workbooks are
  layout/reference only. The sample rater DISPLAYS the artifact's rating build — it does NOT run his
  live 12-step chain — so rater and BDX tie to this artifact by construction; his separate 12-step chain
  (distinct from the artifact's step-1-plus-territory rating) is not used for these outputs. The restyled
  Build-2 files are an interim checkpoint, superseded by this 24-file set.
