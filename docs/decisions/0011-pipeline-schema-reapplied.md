# ADR 0011: Pipeline schema was missing from `luxauto-pg` and has been reapplied

**Status:** Corrected; live
**Date:** 2026-08-12

## What was found

While starting work on ADR 0010's implementation (the `policies`/`policy_events` tables), a live check of `luxauto-pg` before writing anything found that the `luxauto` database contained **only Odoo's own 139 stock tables**. None of the 19 pipeline tables from `schemas/db/postgresql_schema.sql` - `applicants`, `applications`, `quotes`, `insurance_programs`, `program_participants`, `decision_log`, `state_rating_table_versions`, and the rest - existed anywhere on the server, and neither `uuid-ossp` nor `btree_gist` was installed (`\dx` showed only `plpgsql`).

This directly contradicts ADR 0008 ("Schema loading in this session used approach (b) ... the schema `postgresql_schema.sql` is loaded and verified against the running server") and the README's equivalent claim. Checked, not assumed: `\l` on the server lists only `azure_maintenance`, `azure_sys`, `luxauto`, `postgres`, `template0`, `template1` - no other database exists that could be holding the pipeline schema instead.

## Best-guess root cause

Not confirmed, but the most consistent explanation given the other ADRs: ADR 0008's schema load happened from a temporary jump-box VM, which was deleted afterward per that ADR's own account - deleting the jump box wouldn't touch data already committed to `luxauto-pg` itself, since Postgres is a separate managed service. But ADR 0009's Odoo install (`odoo -d luxauto -i base --stop-after-init`) is the next documented touch of this server, and its Deviation 3 fix (`ALTER SCHEMA public OWNER TO odoo; GRANT ALL ON SCHEMA public TO odoo;`) is described as something run "once per database as the Postgres admin **after creation**" - language that reads as though `luxauto` was being created fresh at that point, not reused. If the database ADR 0008 originally loaded the pipeline schema into no longer exists under that name - or if ADR 0008's verification was actually run against a different, non-`luxauto-pg` instance despite its wording - the practical result is the same: whatever `luxauto` database Odoo has been running against since ADR 0009 never had the pipeline schema applied to it.

This ADR does not rewrite ADR 0008's account of what that session did - it may well be accurate for the point in time it describes. This is a new record of the state actually found on 2026-08-12 and the correction applied, not a retraction.

## What was done about it

Before touching anything: queried `information_schema.tables` in `luxauto` for name overlap against all 21 pipeline table names (the original 19 plus ADR 0010's `policies` and `policy_events`), and checked `pg_extension` for `uuid-ossp`/`btree_gist` conflicts. Both checks came back empty - a clean database with no naming collisions with Odoo's own tables, safe to proceed.

Then applied `schemas/db/postgresql_schema.sql` in full against the live `luxauto` database using the Postgres admin credentials (fetched from `luxauto-kv-90a311` via this VM's managed identity, same pattern ADR 0009 established - no secret value passed through the operator or any chat/log channel). The server's `azure.extensions` allow-list already included `UUID-OSSP,BTREE_GIST` from ADR 0008's earlier work, so the load ran cleanly in one pass with no errors - no repeat of ADR 0008's extension allow-listing detour needed.

Verified afterward, not just assumed from a clean exit code: all 19 original pipeline tables present in `information_schema.tables`, both extensions present in `\dx` (`uuid-ossp` 1.1, `btree_gist` 1.7), and the `public` schema's owner still `odoo` - confirming Odoo's own tables and functionality were undisturbed by the load.

## This is a process gap, not just a one-off fix

The actual defect isn't that the schema went missing once - it's that nothing would have caught it going missing. ADR 0008 and the README both asserted "loaded and verified" as a past-tense fact with no standing way to re-check it, and no automated step re-applies or verifies the schema when other infrastructure changes (like ADR 0009's Odoo install) touch the same database. A manual, one-off `psql -f` run from a jump box is exactly the kind of step that silently stops being true the next time someone touches the same database for an unrelated reason.

**Action item:** schema application/verification should become a repeatable script - idempotent (`CREATE TABLE IF NOT EXISTS` or equivalent migration tooling, not a bare `-f` load assumed to run against a pristine database) and safe to run as a standing post-deploy check, not a manual step performed once from a throwaway VM and then trusted indefinitely. Worth resolving before any further infra changes touch `luxauto-pg`, not before this ADR is written.

## Consequences

- `luxauto-pg`'s `luxauto` database now actually matches what ADR 0008/README claimed: all 19 original pipeline tables plus both extensions, live and verified 2026-08-12.
- ADR 0010's implementation (`policies`, `policy_events`, the waterfall function) can now proceed against real tables instead of a documentation claim.
- ADR 0008 and the README are not edited by this ADR - a future pass should update their language to point here if the discrepancy needs to be visible from those documents too, but that's a documentation-hygiene decision, not part of this correction.
