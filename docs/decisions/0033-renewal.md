# ADR 0033: Automatic renewal

**Status:** Decided; DB-side implemented
**Date:** 2026-08-19
**Follows from:** ADR 0019 (nonrenewal/expiration — this is the renewal it deliberately did not foreclose), ADR 0030 (`create_quote`), ADR 0031/0032 (the referral gate and override the renewal quote flows through), ADR 0024 (`bind_policy`'s `p_inception_date`, and the reinstatement-wraps-bind idiom), ADR 0023 (`reinstated_from_policy_id`, the linkage precedent this stays distinct from)

## ⚠️ The A1 consequence — read this first

**A renewal copies the predecessor application's risk data verbatim, and nothing in this pass refreshes it.** There is no MVR pull, no fresh loss run, no re-collection of current claims or violations anywhere in the schema. This was an explicit, informed choice (A1), and its consequence must not be understated:

> **The re-referral that runs on a renewal is mechanically real but practically inert.** It re-evaluates the *same frozen data* that was already evaluated at the prior bind, so it returns essentially the same disposition and **will not catch risk that materially worsened since** — a new DUI, a new at-fault claim, anything acquired after the original application. A policy can auto-renew even though the underlying risk has deteriorated. "The referral engine ran" must never be mistaken for "the risk was re-checked" on a renewal.

Time-based lookbacks can only shift a disposition *less* severe (an old violation ages out of a 5-year window); nothing in a renewal makes a disposition *more* severe, because no new adverse data is introduced. This is documented at the function (`generate_renewal_offers`), the script, and the systemd README, in the same spirit as ADR 0028's insistence that `indicative_premium` is not the full technical premium.

**A real risk-data refresh before renewal evaluation is genuine, near-term-relevant future work, not a nice-to-have** — recorded as the durable follow-up `renewal-risk-data-not-refreshed`.

## What was built

A renewal reuses the whole pipeline rather than duplicating it. The rules, orchestrator, `submit_application`, `current_referral_action`, `create_quote`, `bind_policy` and the ADR 0031/0032 gate/override are all **untouched** — renewal composes them.

- **Linkage columns on `policies`:** `renewed_from_policy_id` (immediate predecessor — distinct from `reinstated_from_policy_id`; renewal is a successive term, reinstatement is restored coverage after a lapse), `original_policy_id` (denormalized chain head, so cumulative tenure is O(1) rather than an unbounded walk), and `renewal_generation` (0 on an original, +1 each renewal). All nullable-or-defaulted, set once at renewal, never superseded, with self-reference CHECKs.
- **`policy_tenure_years(policy_id, as_of)`** — cumulative tenure in years, measured from the chain head's inception (contiguous terms make head-inception → now the continuous time on risk). O(1) via the denormalized head.
- **`copy_application_for_renewal(src_application_id)`** — deep-copies the application's *risk data* (application row, vehicles, drivers, claims, violations) into a fresh draft. `person_violations.subject_driver_id` is remapped to the new drivers. Coverage/prior-insurance/enrichment detail is deliberately **not** copied — no current rule or rating input reads it, so carrying it would be dead weight and a maintenance trap; that is future work if a rule ever reads it.
- **`renew_policy(quote, predecessor, number, by)`** — a thin `bind_policy` wrapper (the reinstate-wraps-bind idiom): binds the renewal quote at a **contiguous inception** (exactly `upper(predecessor.effective_range)`, via `bind_policy`'s existing `p_inception_date` — no widening needed) and sets the linkage/generation. Carries the **structural** nonrenewal guard.
- **`generate_renewal_offers(as_of)`** — the pre-expiry detector: finds active policies whose term ends within 30 days, excludes any with an active nonrenewal decision or an existing successor, and auto-renews each (copy → submit → create_quote → renew_policy). Returns `(renewed_count, skipped_count)`.
- **Ops:** `scripts/generate-renewal-offers.sh` + `infra/systemd/luxauto-generate-renewal-offers.{service,timer}`, mirroring `expire-policies` — **daily** (the 30-day window gives ~29 days of runway; hourly would be pointless churn), `Persistent=true`, run as the least-privilege `odoo` role.

## Key decisions

- **A1 (above):** copy predecessor data, auto-generate a full bindable renewal, zero human involvement — with the inert-re-referral consequence documented loudly.
- **Contiguous inception** via `bind_policy`'s existing `p_inception_date` — no new term machinery.
- **Idempotency needs an explicit guard**, unlike `expire_policies` (whose status filter is self-idempotent): the detector skips a policy that already has a successor, so a re-run creates no duplicate.
- **Robustness:** a policy whose renewal can't currently produce a clean quote (a lapsed state filing making PC-03 fire, an expired territory factor, or a risk that would now be flagged / was previously overridden) is caught per-policy and **counted as skipped**, not fatal to the sweep — which is the correct outcome (a non-clean risk must not silently auto-renew).
- **Two-place nonrenewal guard** (belt and suspenders, per the EL-01/HARD_DECLINE posture): the detector skips a nonrenewed policy, and `renew_policy` **structurally refuses** one regardless of caller (`RENEWAL_POLICY_NONRENEWED`).

## Flag B — a scoped relaxation of ADR 0019's protection, for exactly two lines

Both `nonrenew_policy()` and `correct_policy_nonrenewal()` now compute tenure via `policy_tenure_years()` instead of their inline own-age formula. This is the **only** way point 5's goal — making `nonrenewal_notice_requirements.min_policy_years` reachable — is actually met, and it is **byte-identical for every policy that exists today** (an original has `original_policy_id = NULL`, so the helper measures from its own inception, exactly as before). Both are relaxed together so there is **no divergence**: issuing a nonrenewal and correcting one validate against the same cumulative-tenure basis. The relaxation is scoped to **these two tenure lines only** — it is not a general precedent for touching ADR 0019 objects. (The original Flag B approval named `nonrenew_policy`; the adjacent `correct_policy_nonrenewal` line was found one function later and approved as the same category of change, closing the divergence in the same commit rather than shipping it.)

## Not built (deferred follow-ups)

- **A risk-data refresh mechanism** (`renewal-risk-data-not-refreshed`) — the A1 gap above. The most important follow-up.
- **Nonrenewal withdrawal** — "this nonrenewal should never have been issued → the policy renews after all" composes cleanly once it exists (withdrawing empties the `policy_nonrenewals` row, after which the detector no longer skips the policy), so it needs no renewal-side code; a separate `policy_nonrenewals`-side follow-up.
- **No Odoo renewal wizard/view** — `renew_policy`/`generate_renewal_offers`/`copy_application_for_renewal`/`policy_tenure_years` are granted to `odoo` for a later surface.

## Testing

`tests/0033_renewal.sql` (8 cases): happy path (in-window auto-renewal, contiguous inception exact, linkage/generation correct, re-rated to 10754.72); outside-window (no renewal); nonrenewal decision skipped by the detector; nonrenewal decision refused structurally by `renew_policy`; idempotency (two runs, one successor); multi-generation (renewal of a renewal — `original_policy_id` stays the true original, `policy_tenure_years` cumulative across the chain); the `nonrenew_policy` regression (byte-identical for a no-history policy, and reaching a higher tenure band via cumulative tenure on a renewal); and proof the pipeline really fires on a renewal (a fresh copied application with 5 decision_log rows and a v1 rating_basis). `scripts/run-tests.sh` runs all suites; all 16 pass.

## Consequences

- Policies now auto-renew 30 days before term end, contiguous and fully rated/bound, with cumulative tenure finally making `min_policy_years` reachable.
- **A renewal does not currently re-check risk** — the single most important limitation, documented above and everywhere the mechanism is defined.
- `verify_schema.py` baseline: +4 functions (`policy_tenure_years`, `copy_application_for_renewal`, `renew_policy`, `generate_renewal_offers`); three new `policies` columns and the Flag B one-line change are not baseline categories. No new table (A1: the successor policy *is* the offer), type, view or trigger.
- A third VM systemd timer joins `expire-policies` and `verify-attachment-storage`; its unit files need the install step in `infra/systemd/README.md` re-run.
