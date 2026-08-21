# ADR 0032: Underwriter supervised release — the referral override path

**Status:** Decided; DB-side implemented
**Date:** 2026-08-19
**Follows from:** ADR 0031 (the referral gate this adds an override around), ADR 0026/0028 (the `referral_action_t` taxonomy and its five rules), ADR 0029 (the latest-per-rule / `evaluated_at` derivation the staleness pin mirrors)

## The gap

ADR 0031's gate permanently blocks any application worse than `AUTO_PROCEED_WITH_FLAG`. But the matrix's taxonomy says a `MANUAL_REVIEW_*` application is still *quotable* — "the pipeline may still compute a provisional/indicative price for the underwriter's use, but it cannot be released to the applicant unsupervised." That supervised-release mechanism did not exist: a flagged application was a dead end. This builds it, **around** the gate — it does not change what triggers a referral (the rules, orchestrator, `submit_application`, `current_referral_action` are untouched).

## The hard constraint (the single most important property)

**`HARD_DECLINE_COMPLIANCE` is never overridable, by anyone, structurally.** A sanctions/compliance hit has no human discretion, and an AI-driven decline released with no human in the loop is exactly the fact pattern that draws regulatory scrutiny — get this wrong and the platform can be made to quote a sanctioned party. It is enforced two ways (belt and suspenders):
1. **A whitelist CHECK on `referral_overrides`** (`overridden_action IN ('MANUAL_REVIEW_REQUIRED','MANUAL_REVIEW_SENIOR','DECLINE_RECOMMENDED')`) — a row overriding a compliance decline *cannot physically be inserted*. A whitelist (not a `<>` blacklist) also excludes `INFORMATION_REQUEST` (a data-completeness gate, resolved by re-evaluation, not a risk override) and the AUTO levels, and can't be widened by a future enum value by accident.
2. **An explicit guard in `create_quote()`** that raises `QUOTE_APPLICATION_COMPLIANCE_DECLINE` for a compliance disposition before it even looks for an override.

`DECLINE_RECOMMENDED` is categorically different — a human confirming or reversing a recommendation is normal, expected behaviour — so it *is* overridable.

## What was built

- **`underwriter_authority_t` enum** (`standard` / `senior`) — the two tiers the matrix actually distinguishes, no finer.
- **`underwriters`** — a small *mutable* reference roster (`underwriter_id`, `name`, `authority_level`, `active`, `created_at`), the first backed-identity concept in the schema. `active` closes a real hole: a departed underwriter must not retain authorization power. `add_underwriter()` is the minimal controlled write path; promotion/deactivation is a deferred trivial `update_underwriter()`.
- **`referral_overrides`** — the append-only supervised-release audit record: `application_id`, `overridden_action`, `evaluated_at` (the staleness pin), `reason` (required, non-blank CHECK), `authorized_by_underwriter_id` (FK), `created_at`, plus append-only triggers and the whitelist CHECK above.
- **`authorize_referral_override(application_id, overridden_action, reason, underwriter_id)`** — the single controlled write path. Validates the override targets the application's *actual current* disposition, forbids a compliance decline with a clear message (the CHECK is the backstop), pins to the current evaluation, and does a friendly authority pre-check.
- **`current_referral_evaluated_at(application_id)`** — the staleness-pin read helper (`max(created_at)` over the latest row per rule, exactly the ADR 0029 view's `evaluated_at`).
- **`create_quote()` guard** — now, for a flagged application: raises `QUOTE_APPLICATION_COMPLIANCE_DECLINE` for a compliance decline; otherwise proceeds only if a `referral_overrides` row matches **both** the current disposition **and** the current `evaluated_at`.

## The decisions

- **Authority enforcement is a `BEFORE INSERT` trigger** (`MANUAL_REVIEW_SENIOR` requires `senior`; an inactive or unknown authorizer is refused), because a plain CHECK can't subquery `underwriters`. The trigger is the real, structural enforcement — it catches a direct `INSERT` that bypasses the function — with the function's pre-check giving a friendlier early error. Same belt-and-suspenders shape as the compliance CHECK.
- **The FK divergence is deliberately localized.** `authorize_referral_override`'s authorizer is a real FK into `underwriters` — the one action whose whole point is a specific, authority-bearing human standing behind it. Every other function's free-text `performed_by` / `decided_by` convention is **untouched**; forcing backed identity system-wide would be an unrelated, unwanted migration. A future pass *could* migrate other actors, but nothing here forces it.
- **The override is a standing authorization pinned to its evaluation.** It authorizes quoting while it matches the current disposition *and* `evaluated_at`; any re-evaluation moves `evaluated_at` and invalidates it — so an override can never clear a newer, unreviewed disposition, even one with the same action value. One-shot consumption was rejected (it fights the append-only design and adds friction without safety gain).
- **Authority mapping:** `MANUAL_REVIEW_REQUIRED` / `DECLINE_RECOMMENDED` → `standard` or `senior`; `MANUAL_REVIEW_SENIOR` → `senior` only; `HARD_DECLINE_COMPLIANCE` → never (the CHECK, independent of authority).

## Not built (confirmed out of scope / deferred)

- **Promotion / deactivation of underwriters** (`update_underwriter`) — a trivial future addition; the roster is add-only for now.
- **No Odoo underwriter/override wizard** — `add_underwriter` and `authorize_referral_override` are granted to `odoo` for a later one, matching how visibility/UI always followed the mechanism.
- **`INFORMATION_REQUEST` is not overridable** through this path (a data-completeness gate, resolved by supplying data + re-evaluation), by construction of the whitelist CHECK.

## Testing

`tests/0032_referral_override.sql` (9 cases): `add_underwriter` happy path + blank-name refusal; standard override of `MANUAL_REVIEW_REQUIRED` and of `DECLINE_RECOMMENDED`; a standard underwriter refused for `MANUAL_REVIEW_SENIOR` (via the function **and** a direct INSERT, proving the trigger); a senior override of `MANUAL_REVIEW_SENIOR`; an inactive underwriter refused (function and trigger); **`HARD_DECLINE_COMPLIANCE` never overridable** — the function forbids it and a direct INSERT (even by a senior) is rejected by the table CHECK, with no row written; the staleness pin (a re-evaluation to the same disposition value invalidates the override and `create_quote` stays blocked); and end-to-end (a DUI application blocked at `create_quote`, senior-overridden, then quoting 10754.72). `scripts/run-tests.sh` runs all suites; all pass.

## Consequences

- A `MANUAL_REVIEW_*` (or `DECLINE_RECOMMENDED`) application is no longer a dead end — a suitably-authorized underwriter can supervise-release it, audited and reason-required — while `HARD_DECLINE_COMPLIANCE` remains absolutely, structurally un-overridable.
- The schema now has its first backed-identity table (`underwriters`), deliberately scoped to override authorization.
- `verify_schema.py` baseline: +1 type, +2 tables, +5 functions (3 callable + 2 trigger functions), +3 triggers. `create_quote` gains the override branch but is the same object.
- Next work: an Odoo underwriter/override surface, and `update_underwriter` when promotion/deactivation is needed.
