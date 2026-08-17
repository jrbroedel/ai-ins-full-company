# ADR 0024: Reinstatement — backdated new business (and the gap-only design that was rejected first)

**Status:** Decided; implemented
**Date:** 2026-08-17
**Supersedes:** the gap-only reinstatement design first built under this same ADR number (see §1 — it was proposed, built, tested, and then rejected on business review; this ADR records it rather than erasing it)
**Follows from:** ADR 0023 (the reinstatement-as-new-business + `link_reinstated_policy()` path this extends), ADR 0018 (cancellation and the `policy_cancellations` gap start this reads), ADR 0021 addendum (the DROP-before-recreate idiom for a defaulted parameter)

## 1. What was built first, and why it was rejected

The first implementation under this ADR closed reinstatement as a **gap-only reversal of the same policy**: within 14 days of cancellation, the original `policy_cancellations` row was voided, the original policy and term put back in force, and the insured charged only for the gap days — mirroring the original refund method (`209.58` short-rate / `246.57` pro-rata worked examples). It was fully built and tested (a `reinstate_policy()` that reversed a cancellation, a `policy_reinstatements` charge table, a 14-day window, seven passing cases).

It was **rejected on business review.** Direct reasoning from the insurance-domain sign-off: reinstatement is *always a brand-new one-year policy, backdated to close the gap, at full annual premium* — there is no case where the original policy/term survives and only the gap is charged. Being on risk for only 10–14 days against a $1M+ limit is a risk/premium mismatch the carrier will not accept ("if they crash within the 10 days you only get 10 days of premium and have to pay out $1M"). Both candidate charge formulas the gap-only design had reached for (proportional-to-refund and reapply-the-flat-percentage) were rejected outright, because the shared premise underneath them — a gap-only charge on a surviving policy — was itself wrong.

That rejected work is preserved out-of-tree (a stash plus a saved patch) as a record of the explored path; it is **not** what shipped and it shares no code with what did. This section exists so a future reader sees the rejected design and understands why it isn't here, the same transparency the other ADRs give their "what this deliberately does not cover" sections.

## 2. The shipped mechanism

**A reinstatement is always new business, backdated.** A new policy is bound through the ordinary ADR 0023 path (`bind_policy` + `link_reinstated_policy`), with its inception **backdated to the gap start** — the prior policy's cancellation effective date — so coverage is continuous, at **full annual premium, no proration**. The prior cancelled policy and its truncated term survive untouched; nothing is reversed.

This is structurally ADR 0023's path, not a new mechanism. ADR 0023 already binds new business and links it to the prior cancelled policy; the only thing it could not do was **backdate the new policy's inception**. That is the entire gap this ADR closes, plus the reinstatement-specific preconditions (window, attestation, audit).

### The ≤14-day / >14-day split

- **≤14 days since the lapse:** backdated reinstatement, through the new `reinstate_policy()` wrapper (§4). Inception is pinned to the gap start.
- **>14 days:** there is *no backdating*. It is ordinary new business at **today's** inception, which plain `bind_policy` + `link_reinstated_policy` already handle with **no new code**. `reinstate_policy()` deliberately does not do this case — it rejects (`REINSTATEMENT_WINDOW_EXPIRED`) rather than silently binding at an inception other than the gap start it was handed.

> **Flag for confirmation (business input was an inference, not a direct quote):** the sign-off said "14 days is the maximum" for backdating. The "past 14 days ⇒ ordinary new business at today's inception, no new code" reading is the natural complement and is what is built. Reading it in code, it holds cleanly — the wrapper owns only the backdated case, and the >14-day case is already served by the existing path. If the business actually means something else past 14 days (e.g. no reinstatement at all, or a different attestation rule), only the wrapper's rejection branch changes, not the mechanism. Confirm before deploy.

## 3. Backdating the bind — a defaulted parameter, DROP-then-recreate

**Decision: `bind_policy()` gains an optional `p_inception_date TIMESTAMPTZ DEFAULT NULL`.** NULL preserves the original behaviour exactly (term starts at `now()`); a supplied date backdates the whole term, and the vehicle/driver snapshots inherit it through the same variable. **Premium is untouched** — it is the quote's full annual written premium, and nothing in `bind_policy()` prorates it, so a backdated term is charged the full year, not a stub.

This is the general term-selection hook `bind_policy()` always flagged as an open item — **not** the reinstatement-specific prior-policy reference ADR 0023 deliberately kept out of its signature. That linkage still lives in `link_reinstated_policy()` and the wrapper, so the ADR 0021/0023 "one function quietly doing two jobs" caution is respected: `bind_policy()` gains one general date input, not a reinstatement responsibility.

A defaulted parameter **overloads rather than replaces** (Postgres keys functions on their argument list), which would make an existing three-argument `bind_policy()` call ambiguous. So the three-argument form is `DROP FUNCTION IF EXISTS`ed first, then the four-argument form created — exactly the idiom ADR 0021's addendum used for `program_share_gaps`. There is one `bind_policy()`, and existing three-argument callers bind at `now()` through the default, unchanged (asserted by the 0023 suite still passing).

## 4. The reinstatement wrapper

**Decision: `reinstate_policy(p_quote_id, p_cancellation_id, p_policy_number, p_attestation_reference, p_performed_by) RETURNS UUID`** — a thin wrapper over the existing primitives, in one atomic transaction. It takes the **source cancellation** (which carries the gap start and the prior policy) and the returning customer's fresh **issued** quote. It:

1. Locks the source cancellation; rejects if it does not exist (`REINSTATEMENT_CANCELLATION_NOT_FOUND`) or is superseded/empty (`REINSTATEMENT_CANCELLATION_NOT_IN_FORCE` — a corrected cancellation has no valid gap start to backdate to).
2. Rejects a cancellation already reinstated (`REINSTATEMENT_ALREADY_EXISTS`; the `UNIQUE(cancellation_id)` on the audit table is the backstop).
3. Requires the attestation reference (`REINSTATEMENT_ATTESTATION_REQUIRED`) — **unconditionally, no elapsed-time carve-outs**, the same required-reason-code discipline `cancel_policy()` applies.
4. Enforces the 14-day window (`now() - gap_start > interval '14 days'` ⇒ `REINSTATEMENT_WINDOW_EXPIRED`).
5. Calls `bind_policy(..., v_gap_start)` — new business, inception pinned to the gap start.
6. Calls `link_reinstated_policy()` **unchanged** — it enforces the prior policy is cancelled and sets the link once; if the prior isn't cancelled it raises and the whole wrapper rolls back.
7. Writes the audit row (§5) and a `reinstated` `policy_events` row on the new policy.

The reinstatement-specific rules live here; `bind_policy()` and `link_reinstated_policy()` stay general primitives.

## 5. The audit record — link-and-attestation, not a charge

**Decision: a new append-only `policy_reinstatements` table** recording `new_policy_id`, `prior_policy_id`, `cancellation_id` (UNIQUE), `gap_start`, `attestation_reference`, `performed_by`, `created_at`. It records the **link-and-attestation event**, not a charge — the premium is the new policy's own full annual premium, carried on its `policies`/`quotes` rows like any other new business, so there is nothing money-shaped to store here.

The **signed attestation document** itself lives in the underwriting document store (the per-policy underwriting folder pattern from the Power/Energy manual) — a DMS/file-taxonomy concern, not a schema one. What the database still owns is its **own** audit fact: which policy, which attestation reference/pointer, who, when. This row is that fact. Same append-only discipline as `policy_events`/`program_coverage_gaps`, with no supersession hatch — a reinstatement is a point event, never corrected into another one.

(The name `policy_reinstatements` is reused from the rejected gap-only design, but the shape is entirely different — a link-and-attestation record, not a charge computation. The rejected table was empty and was dropped; see §7.)

## 6. Testing

`tests/0024_reinstatement.sql`, **rebuilt** after the gap-only suite was rejected (a header comment says so — it is not a silent overwrite). Five cases, same BEGIN…ROLLBACK / `IS DISTINCT FROM` / assert-on-the-message discipline as the sibling suites. The fixture builds a prior bound-then-cancelled policy (inserted directly so its term straddles the backdated cancel date) plus the returning customer's fresh issued quote.

- **T1 — happy path (lapsed 1 day ago):** the new policy's inception equals the gap start exactly, its term is a full year (no stub), it carries the full annual premium (`10000`, asserted directly off its quote — no proration), `reinstated_from_policy_id` points at the prior policy, the audit row is correct, the `reinstated` and both `reinstatement_linked` events exist, and the prior policy survives as `cancelled`.
- **T2 — the 14-day window, mutation-tested to the second.** `now()` is the transaction start time and constant across the suite, so "cancelled exactly 14 days ago" is exactly on the boundary: lapsed 1 day and lapsed exactly 14 days are accepted; lapsed 14 days + 1 second and lapsed 15 days are refused (`REINSTATEMENT_WINDOW_EXPIRED`), nothing partial written.
- **T3 — missing attestation** (null and blank) refused, nothing written.
- **T4 — unknown cancellation** refused; **already-reinstated** cancellation refused (reinstate once, then again), exactly one audit row.
- **T5 — superseded cancellation** (emptied by `correct_policy_cancellation()`) cannot be reinstated off.

`scripts/run-tests.sh` runs all six suites (0017, 0018, 0021×2, 0023, 0024). All pass. The 0023 suite passing is the regression check that `bind_policy()`'s new signature left every existing three-argument caller unaffected.

## 7. What this deliberately does not cover / open operational items

- **Short-rate holdback discrepancy — separate, untouched.** The sign-off also noted short-rate cancellation refunds hold back a flat 10% for admin, whereas an earlier worked example used a 0.85 (15%) factor. That is a `short_rate_factors` data question with its own check to do; it is explicitly **not** part of this work and nothing here touches the short-rate table or lookup.
- **Odoo read-side visibility for `policy_reinstatements`** is not built here (a view/model is a separate follow-up), the same sequencing ADR 0018 and ADR 0023 used for their read sides.
- **Live-DB drift cleanup.** The rejected gap-only objects (`reinstate_policy(uuid,timestamptz,text,text)`, the old-shape empty `policy_reinstatements`) were applied to `luxauto-pg` during that build and were never committed. They must be dropped on the live database before this schema deploys cleanly (the new `policy_reinstatements` shape cannot land while the old-shape table exists). This is a one-time authorized cleanup, not part of the committed schema file, which stays free of rejected-object handling.

## 8. Consequences

- Reinstatement is one mechanism: new business, backdated to the gap start within 14 days (full annual premium), or ordinary new business at today's inception past 14 days — both through `bind_policy` + `link_reinstated_policy`, with `reinstate_policy()` adding backdating, the attestation gate, and the audit row for the ≤14-day case.
- `bind_policy()` now carries a general optional inception date, closing the term-selection open item it always flagged.
- `reinstate_policy()` is `SECURITY DEFINER` and granted to `odoo`, like the other lifecycle write functions, for the Odoo reinstatement wizard.
- `verify_schema.py`'s baseline moves by +1 table, +2 functions, +2 triggers; the added `UNIQUE`/`CHECK` and the new event-type string are covered by the 0024 suite, not the parser.
- The gap-only design is on record as rejected (§1), so a future reader will not mistake it for what shipped or try to revive it.
