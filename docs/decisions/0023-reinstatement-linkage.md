# ADR 0023: Reinstatement, the ">14-day" path — link new business to the prior cancelled policy

**Status:** Decided; implemented
**Date:** 2026-08-17
**Follows from:** ADR 0018 (named reinstatement as deferred, section 6), ADR 0012/0010 (bind_policy and the policies/policy_events tables), ADR 0016 (bind-time snapshots), ADR 0021 addendum (the overload trap this deliberately avoids)

## What this ADR decides, and what it explicitly does not

Reinstatement — putting a cancelled policy's coverage back — was named as deferred in ADR 0018 section 6, which flagged the questions it raised ("does coverage apply to the gap, is a new policy issued, what happens to the refund already paid") rather than answering them. Those questions have two genuinely different answers depending on timing, and this ADR closes exactly one of them.

**In scope — the ">14-day" path.** Business decision, confirmed: if a cancelled policy is reinstated **more than 14 days** after its cancellation effective date, there is a genuine, permanent coverage gap. Coverage did not exist during that window and cannot retroactively be made to. So this is **not a reversal** of the old policy — it is ordinary **new business**, run through the existing `application → quote → bind_policy()` flow exactly as any other submission. The only thing that makes it a "reinstatement" at all, rather than an unrelated new customer, is a requirement to **link the new policy back to the prior cancelled one** for traceability and reporting.

**Explicitly NOT in scope — the "≤14-day" path.** True retroactive reversal within 14 days — the same policy put back in force across the gap, with the already-paid refund clawed back — is a **separate, still-open piece of work**, blocked on a business decision (the clawback amount) that is still pending. This ADR builds nothing for it. A future reader should not mistake this ADR for the whole of reinstatement: it is deliberately half of it, and the harder, refund-touching half is untouched here. Nothing in this change goes near `cancel_policy()`, `correct_policy_cancellation()`, or `policy_cancellations` — the ≤14-day path is where those live, and it stays where ADR 0018 left it.

## 1. A separate linking step, not a widened `bind_policy()`

**Decision: `link_reinstated_policy(p_new_policy_id, p_prior_policy_id, p_performed_by)`, called AFTER a normal `bind_policy()` — not a new argument on `bind_policy()`.**

The >14-day reinstatement *is* ordinary new business, so it uses the ordinary bind. Threading an optional prior-policy reference through `bind_policy()`'s signature would change every existing call site and make one function quietly do two jobs — the exact overload trap ADR 0021's addendum documented once already for `program_share_gaps` (a defaulted parameter that overloads rather than replaces, and reads as one function while being two). A separate step keeps the common bind path — every non-reinstatement bind, which is nearly all of them — completely untouched. That the common path is untouched is not a hope; it is asserted, as the regression case T5 (below).

## 2. The link is a set-once column, not correction machinery

**Decision: a nullable `policies.reinstated_from_policy_id UUID REFERENCES policies(policy_id)`, set once and never rewritten.**

This project uses append-only close-the-old-row/insert-new correction machinery for facts that are *temporal and correctable* — a participant's share over a period (ADR 0017), an endorsement's range (ADR 0014), a cancellation's date (ADR 0018). "Which cancelled policy this new policy reinstated" is not that kind of fact. It is a single, immutable statement of provenance: either this policy has a predecessor or it does not, and that answer does not change over time or get "corrected to a different value as of a date." So it is a plain nullable column, and `link_reinstated_policy()` **rejects a second call** on a policy that already has one set rather than silently overwriting. (If a link were ever set to the genuinely wrong predecessor, that is a data-repair question for a DBA, not a business correction with its own temporal semantics — a distinction the function's error message makes explicit.)

A `policies_no_self_reinstatement` CHECK constraint (`reinstated_from_policy_id IS NULL OR reinstated_from_policy_id <> policy_id`) blocks the most obvious data-entry mistake — a policy pointing at itself — at the table level, so it holds even against a raw `UPDATE` that bypasses the function.

## 3. Reading the prior policy's status — confirmed a plain column, not a trap

`link_reinstated_policy()` must confirm the prior policy is actually `cancelled`. This project has been burned before by reading "the current value" off a table that turned out to carry its own correction history, so this was checked rather than assumed: **`policies.status` is a plain mutable `policy_status_t` column.** `cancel_policy()` sets it with a direct `UPDATE policies SET status = 'cancelled'`; `expire_policies()` and the nonrenewal path do likewise; there is no `policies_history`, no versioned status, no append-only status log. So reading `status` straight off the `policies` row *is* the current status, and a simple equality check is correct and sufficient. The function rejects a prior policy whose status is anything but `cancelled` (`REINSTATEMENT_PRIOR_NOT_CANCELLED`).

## 4. Events on both policies

**Decision: `link_reinstated_policy()` writes a `policy_events` row against BOTH the new and the prior policy, `event_type = 'reinstatement_linked'`.**

`policy_events` is the append-only audit trail keyed to a single policy, so a link recorded on only one side would be invisible from the other's history. Writing both means the relationship reads correctly whether you start from the new policy ("reinstates cancelled policy X") or the prior one ("reinstated by new policy Y"). `event_type` follows the existing past-tense-verb convention (`bound`, `cancelled`, `cancellation_corrected`); the `notes` carry the counterpart policy id in each direction, the same way `cancel_policy()`'s notes carry their context.

## 5. Same-insured checking — deliberately NOT enforced in SQL

**Decision: `link_reinstated_policy()` does NOT check that both policies belong to the same insured. That check, to the extent it is made at all, belongs at the UI (the Odoo wizard), not in this function.**

Investigated before deciding. "The same insured" across two policies means walking each chain `policy → quote → application → applicant` and comparing `applicant_id`. The problem: a >14-day reinstatement is **new business**, so the returning customer is re-keyed through a **fresh application**, and this schema does **not** resolve applicant identity across separate application chains. `applicants` has no natural key and no dedup — two applications by the same real person get two different `applicant_id`s (there is no unique constraint on email, ssn_last4, or name; each `applicant_id` is a fresh UUID). So a hard "same `applicant_id`" check would **reject the ordinary, correct case this path exists for** — a genuine returning customer — far more often than it would catch a mistake.

That makes it the wrong invariant for the database to enforce. Whether the operator picked the right predecessor is a human judgement, and the right place to support it is the Odoo bind/reinstatement wizard, which can show the prior policy's insured details for the operator to eyeball before confirming. A SQL check that is wrong as often as it is right would be worse than no check — it would train operators to work around it. This is stated in the function's own comment so the omission reads as a decision, not an oversight.

## 6. Read-side visibility

`luxauto_policy_view` gains `reinstated_from_policy_id` (null for the ordinary policy), and the `luxauto.policy` Odoo model gains a matching `Char` field — mapped as `Char` like `policy_id`/`quote_id`, because the model is `_auto = False` over a view and there is no relational column to key a `many2one` against. The policy form shows it only when present (`invisible="not reinstated_from_policy_id"`), the same conditional-visibility pattern the cancel button already uses. No new exposure mechanism — a plain passthrough column, the way every other field on that view is exposed.

## Testing, and two ordering bugs the tests caught

`tests/0023_reinstatement_linkage.sql`, following the BEGIN…ROLLBACK / `IS DISTINCT FROM` / assert-on-the-error-message conventions of the 0017/0018/0021 suites. Its fixture binds through **`bind_policy()` itself** rather than INSERTing a policies row, because exercising the real common path is the point here. Five cases: the happy-path link (column set, an event on each side, the view exposing it); rejection when the prior policy is not cancelled; rejection of a second link on an already-linked policy (set-once); self-reference blocked both by the function guard and by the CHECK constraint via a raw UPDATE; and — the case that proves section 1's whole bet — **T5, the regression: an ordinary `bind_policy()` with no reinstatement is completely unaffected** (null link, no `reinstatement_linked` event, its usual single `bound` event, and the view returning the row rather than filtering it).

Two bugs were found by applying the schema rather than trusting it, both existing-database-only (a fresh apply hid them, which is exactly why both apply paths were run):

1. **The new index preceded the column** on an existing table. `CREATE TABLE IF NOT EXISTS` is a no-op on the live server, so the column arrives via the idempotent `ALTER … ADD COLUMN`, and `idx_policies_reinstated_from` was ordered before that ALTER — it failed with "column does not exist." Fixed by moving the index after the ALTER.
2. **`CREATE OR REPLACE VIEW` cannot insert a column mid-list.** The new column was first placed after `policy_status`, which shifts the later columns and fails with "cannot change name of view column." Fixed by appending it at the end of the select list, the only position `CREATE OR REPLACE VIEW` allows over an existing view.

Both were confirmed fixed by re-running a genuine fresh apply (empty scratch database) *and* the existing-database apply (`apply-and-verify-schema.sh` against the live server), then the full `scripts/run-tests.sh` — all five suites pass, nothing committed.

## Consequences

- The ">14-day" reinstatement path is closed: it is new business plus a set-once traceability link, with no change to the common bind path.
- **The "≤14-day" retroactive-reversal path remains open**, blocked on the pending clawback-amount decision. It is the piece that touches refunds and `policy_cancellations`, and it will need its own ADR. This ADR is explicitly not it.
- `link_reinstated_policy()` is `SECURITY DEFINER` and granted to `odoo`, like the other policy-lifecycle write functions, so the Odoo wizard can call it after bind.
- The same-insured check is an operator/UI responsibility, by the reasoning in section 5. If applicant identity resolution is ever added to this schema, that decision could be revisited — but it would be a new capability, not a fix to this function.
- `verify_schema.py`'s baseline moves by one function (`link_reinstated_policy`); the added column and CHECK are not categories that parser tracks, and are covered by the 0023 suite instead.
