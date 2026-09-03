0051 — Snapshot authorizing underwriter's authority level on referral overrides
Status: Accepted Date: 2026-09-03 Related: 0036 (referral matrix), 0040 (override UI). ADRs 0041–0049 live on `demo/investor-preview`.
Context
`referral_overrides` records who authorized an override but not the authority level they held at that moment. Any view joining to the underwriter's current authority shows their status as of query time: after a demotion (or promotion), the historical record silently misstates the authority under which the override was granted. Audit answers must reflect the facts at decision time — the same point-of-decision discipline the referral matrix applies to reason codes.
Decision

1. Add `authorized_by_authority_level` to `referral_overrides`, populated at write time from the authorizing underwriter's authority level. NOT NULL for all new rows.
2. Existing rows are backfilled from current authority levels, with a column comment recording that pre-backfill rows carry authority as of the backfill date, not the original decision date. This limitation is accepted and documented rather than guessed around.
3. All views and the ADR 0040 override UI read the snapshot column; the live join to current authority is removed from historical displays.

Consequences

* Post-migration overrides are audit-accurate at decision time regardless of later personnel changes.
* The backfill caveat is permanent for legacy rows; a market-conduct-style question about a pre-migration override must cite the caveat.
* Same snapshot pattern should be applied to any future decision-recording table (bind confirmations, subjectivity waivers) at design time, not retrofitted.
