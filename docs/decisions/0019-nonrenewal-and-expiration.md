# ADR 0019: Nonrenewal and policy expiration

**Status:** Decided; implemented
**Date:** 2026-08-13
**Follows from:** ADR 0010 (`policies.status`, `policy_status_t`, `policy_events`), ADR 0012 (`cancel_policy()`, `SECURITY DEFINER` gateway pattern), ADR 0015 (versioned operational scripts, apply-and-verify), ADR 0018 (cancellation: reason codes, atomicity standard, the empty-table-plus-loud-failure treatment for filed numbers), ADR 0016 addendum 2 and 3 (correction-function mechanics: the same-table-subquery trap and the earlier-date supersession fix)
**Not in scope:** renewal itself - see section 5. Also untouched: the commission formula (ADR 0007), ADR 0017's deferred items, and ADR 0018's flagged loose ends (settlement view, an Odoo view over `policy_cancellations`, endorsement closeout at cancellation, reinstatement).

## What this ADR decides

`policy_status_t` has carried `'expired'` and `'nonrenewed'` since ADR 0010 and **nothing has ever set either one** - `cancel_policy()` was the only status transition in the schema. This ADR fills that in. It decides four things: when a nonrenewal decision changes a policy's status, how the notice requirement is handled given that it is a filed number, how the term-end transition actually runs given what this database can and cannot schedule, and why expiration gets no correction function when everything else here does.

## 1. What the investigation found

Three things were checked against the live system before any design, because each one could have changed the answer.

**`policies` is exactly as assumed, and the term end is `upper(effective_range)`.** From the catalog: `effective_range TSTZRANGE NOT NULL`, `status policy_status_t NOT NULL DEFAULT 'active'`, `idx_policies_status`, enum `('active','cancelled','expired','nonrenewed')`. No separate term-end column exists, so `upper(effective_range)` is the only candidate and it is the right one.

**A cancelled policy's term end is also in the past, which makes the status filter load-bearing rather than decorative.** ADR 0018's `cancel_policy()` truncates `effective_range` to the cancellation instant *and* sets `status = 'cancelled'`. So a date-only sweep - "term ended, mark it expired" - would pick up every cancelled policy in the database and overwrite a terminal status with the wrong one. The expiration job filters on `status = 'active'` first; that is what keeps cancelled and nonrenewed policies out, not the dates. Verified in testing: a cancelled policy whose term end had passed was untouched by the job.

**pg_cron is preloaded on `luxauto-pg` but cannot be created.** `shared_preload_libraries` includes `pg_cron` (Azure preloads it on Flexible Server), and `pg_available_extensions` offers 1.6 - but `azure.extensions` is `UUID-OSSP,BTREE_GIST`, and `CREATE EXTENSION pg_cron` is refused outright:

```
ERROR: extension "pg_cron" is not allow-listed for "azure_pg_admin" users in Azure Database for PostgreSQL
```

Allow-listing it means an Azure control-plane server-parameter change plus a restart - infrastructure work this ADR does not carry, and `az` is not installed on `luxauto-odoo` in any case. A second obstacle sits behind the first: `cron.database_name` is `postgres`, so even a permitted `pg_cron` would schedule jobs from a different database than `luxauto`.

**So the schedule lives on the VM** - a `systemd` timer running a versioned script that calls one SQL function. That is the same VM-side operational pattern `scripts/deploy-vm.sh` already established, and ADR 0015's argument applies unchanged: the scheduling artifact belongs in this repo, reviewed and rolled back like everything else, not as VM-local state nobody can see. The unit files live in `infra/systemd/` for the same reason.

## 2. A nonrenewal decision does not change the policy's status when it is made

**Decision: `nonrenew_policy()` records the decision and leaves `policies.status = 'active'`. The flip to `'nonrenewed'` happens at term end, performed by the same scheduled function that expires everything else.**

The alternative - flip to `'nonrenewed'` the moment the decision is recorded - breaks what `'active'` means everywhere else in this schema. A policy nonrenewed with 90 days' notice is *still in force* for those 90 days: it covers claims, it can be endorsed, and the insured can still cancel it mid-term. But `cancel_policy()` refuses any policy whose status is not `'active'`, so an early flip would make a policy that is genuinely in force uncancellable, and would make `luxauto_policy_view` report a policy as nonrenewed while it is still paying claims. `'active'` means in force; a nonrenewal is a decision about the future, and the decision has its own record.

Tested directly: after a nonrenewal notice is recorded, the policy still reports `active`, and `cancel_policy()` still accepts it.

This also removes any possibility of the two mechanisms disagreeing. One function owns the term-end transition and picks the status by asking whether a nonrenewal decision is in force, so "nonrenewed" and "expired" cannot both be written for the same policy, and no ordering between two schedules has to be reasoned about.

`policy_nonrenewals` follows the shape every other decision record here has: append-only, one live row per policy (exclusion constraint), `effective_range` = `[notice given, term end)` - the notice window the decision covers, which also preserves the term end for the correction path. It records the reason code, and both the notice period that was *required* at decision time and the notice period actually *given*, because the validation is only as good as the table it read and a later audit needs to see which number it used.

## 3. The notice requirement is a filed number, so it ships empty

**Decision: `nonrenewal_notice_requirements` ships with no rows. `nonrenew_policy()` raises `NONRENEWAL_NOTICE_REQUIREMENT_NOT_CONFIGURED` when nothing is loaded for the state and program, and `NONRENEWAL_NOTICE_TOO_SHORT` when a requirement exists and the notice does not satisfy it.**

Same treatment, for the same reason, as ADR 0018's `short_rate_factors` and the state rating table registry:

> **Nonrenewal notice periods must be sourced from the actual filed rule or the governing DOI bulletin for each state before any nonrenewal is issued in production.** They are state-regulated - commonly 30-60+ days of advance written notice, varying by state and sometimes by how long the insured has been with the carrier - and every row in this table must trace back to a real source document, or it is a data gap waiting to surface at the worst time. Nothing in this repo invents one.

The table carries `state`, optional `program_id` (program-specific beats statewide), `notice_days`, an effective range, and `regulatory_reference`/`serff_filing_tracking_number` for provenance. It also carries `min_policy_years`, which is the mechanism for a tenure-banded requirement. That column is honest about its own limits: until renewal exists, a policy's tenure is just its own age and is always under one year, so no real band above zero can currently be reached. It is there so a genuine banded filing can be *represented* rather than silently flattened - the same reason ADR 0018 put a `basis` column on `short_rate_factors` instead of assuming one convention.

Pro-rata needed no filing in ADR 0018 because it is arithmetic. Nothing here is arithmetic: a notice period is a rule someone filed, and there is no defensible default. So unlike cancellation, where pro-rata always works, **no nonrenewal can be issued at all until a requirement is loaded** - which is the correct failure mode for a decision that has to be defensible to a regulator.

## 4. Correction: supersede by emptying, both known traps handled up front

**Decision: `correct_policy_nonrenewal()` empties the superseded row rather than closing it at the new notice date, and re-validates the corrected notice against the filed requirement.**

A nonrenewal is a point decision whose range describes the notice window *one* decision covered - the same shape as a cancellation, and unlike an endorsement or a vehicle snapshot, which are period facts that really were true until the correction took over. Closing a notice dated 31 March at 14 June would assert that a 135-day notice actually ran 75 days, which nobody decided. So this follows ADR 0018's cancellation semantics rather than ADR 0016 addendum 3's `GREATEST()` split - and as a consequence the earlier-date bug that addendum had to fix in four other functions **cannot arise here at all**, because no shortened range is ever constructed. Both directions were tested anyway.

Both mechanics from ADR 0016 addendum 2/3 were applied from the start rather than rediscovered: the append-only trigger's escape hatch is a transaction-local flag permitting exactly two shapes (close the upper bound, or empty a non-empty row), never `ALTER TABLE ... DISABLE TRIGGER`; and every test resolved the target id with a subquery scanning `policy_nonrenewals` in the same statement.

Re-validating on correction matters in one direction specifically: moving a notice date *later* can push it inside the required period that the original satisfied. Tested - it is refused.

**Not a withdrawal.** "This nonrenewal should never have been issued" means the policy renews after all, which is renewal, which is section 5.

## 5. Expiration, and why it has no correction function

**Decision: `expire_policies(as_of)` transitions every policy that is still `'active'` with a term end at or before `as_of` - to `'nonrenewed'` if a nonrenewal decision is in force, `'expired'` otherwise - and logs a `policy_events` row for each, `performed_by = 'system'`.**

It logs to `policy_events` because every other status change in this schema does (`bound`, `cancelled`, `endorsed`, `nonrenewal_noticed`), and a status that changed with no audit row would be the one transition nobody could explain afterwards. The events are written in the same statement as the updates, so a partial run cannot log a transition it did not make.

**Idempotency falls out of the status filter rather than being bolted on.** The job only touches `'active'` rows, and its own writes make them not-active, so a re-run, an overlapping run, or a catch-up run after downtime finds nothing to do. Verified: three consecutive runs after the first reported `0 expired, 0 nonrenewed` and changed nothing.

**No correction function, deliberately.** Every other state change here has one because every other state change encodes a human decision that can be wrong in a way the data cannot detect - a wrong cancellation date, a mistaken VIN, a misfiled reason code. Expiration encodes no decision: it is a derived consequence of a term end and the absence of anything else. If a policy shows `'expired'` incorrectly, the term or the status that should have superseded it is wrong, and the fix is to that - or the job's query is wrong, and the fix is a code change with a test, not a data correction. Adding a `correct_policy_expiration()` would offer a way to paper over both.

**Timing: hourly, `Persistent=true`.** A policy whose term has ended shows a stale status until the job runs, so the question is how much staleness to accept. The job is one indexed `UPDATE` over `status = 'active'`, so hourly costs nothing meaningful and bounds staleness at an hour rather than a day. `Persistent=true` makes a VM that was down catch up on boot instead of silently skipping a term end. This is the scheduling decision for *this* job only - ADR 0012/0015's open item about CI/CD trigger timing for the other scripts is untouched and unrelated.

## 6. Renewal is out of scope and deliberately undesigned

Whether a renewed policy is a new row referencing its predecessor or the same row with an extended term is a real modelling decision with consequences for the snapshot tables, the waterfall's `as_of`, and tenure - and this ADR does not make it, in either direction.

What it does do is avoid foreclosing it. The expiration job only touches policies that are still `'active'` **and** whose term has ended, so any future renewal mechanism that extends a term or sets a different status before the job next runs simply removes that policy from the job's view. Nothing here needs to detect, link to, or prevent a renewal, and nothing here assumes one will look a particular way. The `min_policy_years` column is the one place renewal is anticipated at all, and only as an inert representation of something a filing might require.

## Consequences

- Two new tables, five new functions, two new triggers; ADR 0015's verifier baseline moves accordingly (+2 tables, +5 functions, +2 triggers, no new types or views).
- `nonrenew_policy()`, `correct_policy_nonrenewal()`, `nonrenewal_notice_days()` and `expire_policies()` are granted to `odoo`, so the scheduled job runs as the least-privilege role against a `SECURITY DEFINER` function and needs no table privileges and no Key Vault round-trip - it reads the role's password from the Odoo config the unit's user already owns.
- `nonrenewal_notice_requirements` is empty, and every nonrenewal fails until it is loaded from filed sources. That is the intended state, not an incomplete build.
- `scripts/expire-policies.sh` and `infra/systemd/luxauto-expire-policies.{service,timer}` are versioned here. `scripts/deploy-vm.sh` picks up script changes on the next deploy; **unit-file changes need the install step in `infra/systemd/README.md` re-run**, since installing system units is a privileged one-time operation a deploy script has no business doing unattended.
- There is no Odoo model or view over `policy_nonrenewals`, and no wizard for issuing a nonrenewal - the same deliberate split ADR 0016 and ADR 0018 made. The status change itself is visible through `luxauto_policy_view.policy_status`.
- Renewal, reinstatement, and a nonrenewal-withdrawal path all remain unbuilt and unclaimed.
