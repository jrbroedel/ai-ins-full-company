# ADR 0038: `update_underwriter()` — the roster-mutation counterpart to `add_underwriter()`

**Status:** Decided; implemented
**Date:** 2026-08-22
**Follows from:** ADR 0032 (the `underwriters` roster, `add_underwriter()`, `referral_overrides`, and the authority/active enforcement this extends and interacts with)

## Scope

ADR 0032 built the `underwriters` roster (standard/senior authority, `active` flag) and `add_underwriter()`, and named this gap explicitly in the schema: *"Promotion / deactivation … is a trivial future `update_underwriter()`, not this pass."* This ADR fills it — one partial-update function to promote/demote, (de/re)activate, and rename an existing underwriter. Purely additive; no new tables/types/triggers/views.

## The function

```sql
update_underwriter(
  p_underwriter_id   UUID,
  p_name             TEXT DEFAULT NULL,                    -- NULL = leave unchanged
  p_authority_level  underwriter_authority_t DEFAULT NULL, -- NULL = leave unchanged
  p_active           BOOLEAN DEFAULT NULL                  -- NULL = leave unchanged
) RETURNS UUID   -- the underwriter_id, symmetric with add_underwriter()
```

`SECURITY DEFINER SET search_path = public, pg_temp`, granted `EXECUTE … TO odoo` — matching `add_underwriter()` exactly. **Mutable:** `name`, `authority_level`, `active`. **Immutable:** `underwriter_id` and `created_at` (identity and the creation record never change). Partial-update via `COALESCE(p_x, x)`, so a caller changes only what it names. Validation, `UPPER_SNAKE` codes like the rest of the schema:

- `UPDATE_UNDERWRITER_NO_CHANGES` — all three mutable args NULL (a no-op call is a caller mistake worth surfacing, not a silent success).
- `UPDATE_UNDERWRITER_NAME_REQUIRED` — a supplied name is blank/whitespace.
- `UPDATE_UNDERWRITER_NOT_FOUND` — no such underwriter.

**One function, not a split** (promote/demote/deactivate/reactivate/rename). For a three-field mutable roster the partial-update form is the smallest surface and one place to reason about; a split would multiply into ~5 near-identical functions. **Not a guard-trigger / sole-path function** either: `underwriters` is a deliberately mutable roster (no append-only trigger, unlike `referral_overrides`/`decision_log`), and `add_underwriter()` likewise does not forbid a direct `INSERT`. `update_underwriter()` is the sanctioned, validated wrapper — not a lock. A direct `UPDATE` remains possible (and `tests/0032`-T6 still uses one, deliberately left as-is for zero blast radius).

## The audit finding — demotion, past overrides, and what stays true (Option A)

Demotion is **allowed**. It does **not** retroactively invalidate a past supervised release, and the reason is structural, not incidental:

- `referral_overrides` is **append-only** and immutable; each row **proves valid authorization at insert time** — the `enforce_referral_override_authority` trigger enforced the senior/active requirement *then*, against the roster as it stood.
- `create_quote()`'s override gate reads only whether a matching `referral_overrides` row **exists** (by `application_id`, `overridden_action = current disposition`, `evaluated_at = current evaluation`). It never re-reads the authorizer's *current* `authority_level` or `active`. So demoting or deactivating an underwriter after they authorized an override leaves that override fully effective. **Test T8 proves this end to end**: a senior authorizes an override of `MANUAL_REVIEW_SENIOR` (and a standard is shown to be refused for the same action), the underwriter is demoted to standard, and `create_quote()` still succeeds against the existing override (re-rated 10754.72).

**The accepted, tracked residual:** because `referral_overrides` stores only `authorized_by_underwriter_id` (an FK) and not a snapshot of the authority level at the time, a *live join* `referral_overrides → underwriters` shows the authorizer's **current** roster status, not their status at authorization. After a demotion, a past `MANUAL_REVIEW_SENIOR` override — validly senior-authorized — would *read* on such a join as authorized by a "standard" underwriter. The row itself is correct and immutable; only the joined presentation is potentially misleading.

This is a **deliberate, tracked deferral, not an oversight.** The fix — an `authorized_by_authority_level` snapshot column frozen onto `referral_overrides` at insert — is **out of scope for ADR 0038** because it changes ADR 0032's append-only table and only helps future rows; it is tracked as its own future ADR. Until then, any audit surface joining these tables must label roster fields as "current roster status," not "authority at time of authorization."

## Deactivation — no cascade, no blocking

The only FK into `underwriters` is `referral_overrides.authorized_by_underwriter_id`. There is no assignment table and no "manual review in progress assigned to underwriter X" concept anywhere in the schema, so deactivation cascades nothing and blocks nothing: a deactivated underwriter's past overrides remain fully queryable (append-only + FK intact), and the intended effect of `active = false` already exists — the authority trigger refuses *future* overrides by an inactive underwriter (`OVERRIDE_AUTHORIZER_INACTIVE`). **Test T9** proves the round-trip: a deactivated underwriter is refused, then reactivated, then authorizes a new override successfully.

## Testing

`tests/0038_update_underwriter.sql` (9 cases): promote (T1, incl. return value + COALESCE preservation), demote (T2), deactivate→reactivate (T3), rename with partial COALESCE (T4), all-NULL rejected (T5), blank name rejected with no partial write (T6), unknown id rejected (T7), and the two interaction proofs (T8 functional immutability after demotion, T9 reactivation restores authorization). `tests/0032` is untouched and still passes. `scripts/run-tests.sh`: all 20 suites pass against luxauto-pg.

## Consequences

- The `underwriters` roster is now fully manageable (add + update); the ADR 0032 gap is closed.
- A demotion/deactivation is functionally safe for past overrides — proven, not just asserted (T8/T9). The **audit-presentation residual** (no historical authority snapshot on `referral_overrides`) is an **accepted, separately tracked gap**: a future ADR adds an `authorized_by_authority_level` snapshot column to `referral_overrides`. A future reader should treat the absence of that snapshot as a known deferral recorded here, not a miss.
- `verify_schema.py` baseline: **functions 68 → 69** (`update_underwriter`); no new tables/types/triggers/views.
- `update_underwriter` is a sanctioned wrapper, not a lock — direct `UPDATE`s on the mutable roster remain possible by design, consistent with `add_underwriter()`.
