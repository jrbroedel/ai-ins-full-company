# ADR 0030: Quote creation — wiring the rating engine into `create_quote()`

**Status:** Decided; DB-side implemented
**Date:** 2026-08-19
**Follows from:** ADR 0028 (`compute_indicative_premium()`, the rating engine this calls, and the `$100k` floor), ADR 0007 addendum (`quotes.broker_channel` / `broker_commission_rate` this function sets), ADR 0029 (the `luxauto.quote.rating` read view that renders the `rating_basis` this now writes), ADR 0025 (the fail-loud onboarding pattern the failure mode follows)

## The finding that reframed the task

ADR 0028 built `compute_indicative_premium()` and named `quotes.premium_amount` / `quotes.rating_basis` as its destination, but **nothing called it on quote creation** — and investigation showed why that gap was invisible: **there is no quote-creation function at all.** Before this ADR, a `quotes` row was only ever `INSERT`ed by test fixtures. There is no Odoo write path (quotes is read-only via views), no application logic, no `create_quote()`. Every fixture wrote `rating_basis` as `'{}'::jsonb` to satisfy the NOT NULL, and the only reader of `rating_basis` anywhere is ADR 0029's `luxauto_quote_rating_view`, which already tolerates a non-v1 shape (yields NULLs, never errors). So "wire rating into quote creation" is really **"build the first real quote-creation write path, and rate the quote as it is created."** Nothing depends on the old `'{}'` shape, so writing the v1 breakdown is a safe, additive change.

## What was built: `create_quote()`

A single SECURITY DEFINER function, the same thin-composition idiom as `bind_policy` / `reinstate_policy` — it does **not** reimplement rating:

```
create_quote(p_application_id, p_broker_channel, p_broker_commission_rate,
             p_state_rating_table_record_id, p_program_id, p_performed_by) RETURNS UUID
```

It resolves the application's single vehicle, calls `compute_indicative_premium(vehicle_category, current_appraised_value, garaging_state)`, and writes `premium_amount = indicative_premium` and `rating_basis = breakdown` **verbatim** onto a new `'issued'` quote. `compute_indicative_premium()` remains the single source of both the number and the breakdown; its guards propagate out unchanged (below-floor, unmapped category, unconfigured territory), and **no quote row is written when it raises**.

- **`p_agreed_value` is fed from `current_appraised_value`.** There is no separate numeric agreed-value column — `agreed_value_requested` is a boolean flag — and this is the same value ADR 0028's tests and `evaluate_el01()` already use. State for the territory lookup is the vehicle's `garaging_state` (`== applications.garaging_state`, which is keyed off it).
- **The quote is created `'issued'` (rated and bindable).** To be explicit about *why* there is no `'draft'` handling: **no quote lifecycle exists in the system yet** — there is no issue step, no acceptance workflow, no function that moves a quote from `'draft'` to `'issued'`. This is filling that gap, not following an established convention. ADR 0028 frames a clean rated risk as final and bindable, `bind_policy()` requires `'issued'`, and a `'draft'` quote would be stranded with nothing able to advance or bind it — so a fresh quote is born `'issued'`. A future draft→issued acceptance lifecycle, if ever wanted, is separate work; it was not considered-and-rejected here, it simply does not exist yet.

## The three resolved decisions

1. **Multi-vehicle — single vehicle only, fail loud.** Rating v1 is explicitly single-vehicle (ADR 0028), and a quote reaches vehicle data only through its application (1:N). Zero or 2+ vehicles raise `QUOTE_RATING_NO_VEHICLE` / `QUOTE_RATING_MULTI_VEHICLE_UNSUPPORTED` rather than silently pick one or aggregate (aggregation is deferred out of v1). This is the direct consequence of v1's confirmed scope, not a new rule.

2. **Failure mode — fail outright, never a partial quote.** When rating cannot compute (an unconfigured territory being the live reality — only `T0` has a factor), quote creation **fails and no quote is written**. No "unrated" status, no nullable premium, no partially-priced record — which would have been the first place in the whole schema where an incomplete record is allowed to exist. This matches the fail-loud pattern already established (`short_rate_factor()`, `territory_factor()`) and is consistent with the existing FK to `state_rating_table_versions` that already blocks a quote for an un-onboarded state.

3. **Scope — rating only.** This pass wires *rating*. The referral engine (`evaluate_application_referrals` / `evaluate_el01` and the rest) is **also unwired in production** and is a separate follow-up (see below) — referral evaluation belongs at application submission, a different moment than quote creation.

## State-onboarding precondition (made explicit)

A state is **not ready for quoting until BOTH its `state_rating_table_versions` row AND its `territory_factors` row exist.** The first was already enforced structurally (the NOT NULL FK on `quotes`); the second was implicit until now, because rating was never called at quote time. `create_quote()` is where that second precondition becomes observable: onboarding a state for quoting must load its territory factor, not only its filed rating-table version. A future onboarding pass must not create the compliance record and assume quoting works.

## Not built / flagged follow-ups

- **Referral-engine wiring is a separate task.** `evaluate_application_referrals()` fires nowhere in production today. Until it is wired (at application submission), EL-01's *audited* below-floor decline does not fire — only `compute_indicative_premium()`'s own hard `RATING_BELOW_AGREED_VALUE_FLOOR` guard protects quote creation, which is sufficient to stop a below-floor quote here but does not produce the audited `decision_log` decline. This is the sibling gap to the rating-wiring gap this ADR closes, flagged the same way.
- **Quote-creation provenance is recorded** in a new `quotes.quoted_by` column, which `create_quote()` persists `p_performed_by` into — a normal audit column, the same provenance every other write function records (`cancel_policy` / `reinstate_policy`'s `performed_by`). It is added by ALTER then `SET NOT NULL` under a guard, the same idiom as the ADR 0007 addendum's broker columns, so it lands on the already-created `quotes` table. The pre-existing quote-inserting test fixtures (0007/0018/0023/0024/0027/0029) were updated to supply it.
- **No Odoo quote-creation wizard.** `create_quote()` is granted to the `odoo` role so a later wizard can call it (as bind/cancel/reinstate do), but that UI is not built here.
- **Multi-vehicle aggregation, and the deferred rating factors** (ADR 0028's step 2–9/11 workbook factors) remain out of scope.

## Testing

`tests/0030_quote_creation_rating.sql` (6 cases): the single-vehicle happy path — premium asserted against `compute_indicative_premium()` itself (not hand-typed) and the documented 10754.72, `rating_basis` stored verbatim, quote `'issued'`, and the ADR 0029 rating view unpacking the stored basis end-to-end (`base_rate_per_100=0.95`, `territory_factor=1.00`, `indicative_premium=10754.72`); 2+ vehicles rejected; 0 vehicles rejected; unconfigured territory failing outright with no quote written; below-floor rejected via the rating guard; and an unmapped category rejected — each rejection asserting no quote row survives. `scripts/run-tests.sh` runs all suites; all 13 pass.

## Consequences

- Real quotes are now rated at creation: `premium_amount` and a v1 `rating_basis` are populated, so `luxauto.quote.rating` renders actual numbers instead of NULLs for the first time.
- Quote creation is fail-loud and all-or-nothing: an un-onboarded or unrateable risk produces no quote, never a partially-priced one.
- `verify_schema.py` baseline: +1 function (`create_quote`) and +1 SET NOT NULL column (`quotes.quoted_by`); no new table/type/view/trigger.
- Next work: wiring the referral engine at application submission (the sibling gap), an Odoo quote-creation wizard, and the deferred rating factors / multi-vehicle aggregation.
