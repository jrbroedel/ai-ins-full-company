# ADR 0005: Database table design

**Status:** Decided and verified (DDL runs clean; key constraints tested against a live PostgreSQL 16 instance in this session)
**Date:** 2026-08-09

## What this is

`schemas/db/postgresql_schema.sql` is the relational implementation of the three JSON schemas built earlier: `luxury_auto_application_schema.json` v1.1, `state_rating_table_schema.json` v1.1, and `luxury_auto_referral_matrix.json` v1.1. It's real, runnable DDL, not a description of one - see "Verification" below for what was actually tested.

## Design choices worth explaining

**Applicants are normalized separately from applications.** The JSON schema nests `applicant` inside a single application. The database splits them, because in practice one person submits more than one application over time (renewals, adding a vehicle) and there's no reason to duplicate applicant data per application.

**`state_specific_extensions` is a JSONB column, not per-state tables.** This mirrors the JSON schema's own mechanism directly: a namespace keyed by state, driven by `state_rating_table_versions.state_specific_application_fields` for whatever fields a given state declares it needs (Michigan's PIP tiers, for now). Adding a new state's supplemental fields is a data change, not a schema migration.

**State rating table versioning uses a range type with an exclusion constraint, not manual date-overlap checking.** `effective_range TSTZRANGE` plus `EXCLUDE USING gist (state WITH =, effective_range WITH &&)` makes it structurally impossible for two versions of the same state's rating table to have overlapping active periods - the database rejects the insert, full stop, rather than relying on application code to check this correctly every time. This was the specific mechanism ADR 0001 called out as the reason to pick PostgreSQL, and it's now implemented and tested (see below), not just described.

**The decision log is append-only, enforced by a trigger, not just convention.** `decision_log` has `BEFORE UPDATE` and `BEFORE DELETE` triggers that unconditionally raise an exception. This is the table the NY DFS / Colorado AI-governance documentation requirements are built from (per the referral matrix's own `how_this_is_used` notes), and per the Energy manual's Chapter 3 discipline this ADR keeps citing: a reason code gets captured at the point of decision, and correcting a mistake means adding a new row that references the old one, not editing history. Tested below.

**Violation history is one table for both the applicant and additional drivers, not two.** `person_violations.subject_driver_id` is nullable - NULL means the applicant, populated means a specific `additional_drivers` row. Avoids maintaining two near-identical tables for what the application schema's `enrichment_computed` already treats as the same shape (`applicant_enrichment.violation_history` and `additional_driver_enrichment[].violation_history`).

**Quotes pin the exact `state_rating_table_versions.record_id` used to generate them.** This is what makes the "never re-rate an in-flight quote when a new version goes active" principle (from both ADR 0001 and the registry schema's own `how_this_is_used`) actually true at the database level rather than just documented intent.

**Enums mirror the JSON schemas' `enum[...]` fields exactly.** If a schema enum changes, this file needs to change with it - they're meant to be kept in lockstep, not to drift into two different sources of truth for the same set of allowed values.

## Verification (not just claimed - actually run this session)

PostgreSQL 16 was installed in the build environment and the full DDL file was executed against a real database with zero errors. Two of the design's load-bearing behaviors were then specifically tested:

1. **Exclusion constraint correctness:** inserted two non-overlapping CA rating table versions (succeeded), then attempted to insert a third CA version with a date range overlapping the first (correctly rejected with `conflicting key value violates exclusion constraint`).
2. **Append-only enforcement:** inserted a `decision_log` row, then attempted an `UPDATE` against it (correctly rejected with `decision_log is append-only: UPDATE is not permitted`).

This is PostgreSQL 16, not yet confirmed as the exact version Azure Database for PostgreSQL Flexible Server will run - worth pinning explicitly when we get to actual Azure provisioning, but the DDL uses no version-specific syntax expected to be a problem across recent Postgres versions.

## Open question this doesn't answer: how Odoo talks to these tables

This DDL is written as plain, hand-designed PostgreSQL - deliberately not generated through Odoo's ORM, consistent with ADR 0001's principle that the pipeline stays database-agnostic and UI-agnostic. That leaves a real fork in the road for when Odoo customization work starts:

- **Option A - Odoo ORM models map directly onto these tables** (Python models with `_table = 'applications'` etc., pointing at the existing table rather than letting Odoo generate its own). Simplest to build, tightest coupling between the pipeline's schema and Odoo's specifics.
- **Option B - Odoo talks to a service/API layer, not raw SQL.** The pipeline owns and writes these tables; a thin API sits between Odoo and the data. Loosest coupling, most consistent with the multi-industry portability goal, more work to build now.

Not decided here on purpose - it's an Odoo-customization-scoping question, not a database design question, and deserves its own focused ADR when that work starts rather than a rushed call as a side effect of this one. **Resolved in ADR 0006** - a confirmed technical fact (Odoo's ORM requires integer primary keys, no exceptions) ruled out Option A as originally framed and led to a refined design: read-only SQL views with a derived pseudo-integer id for Odoo's UI, and explicit controlled write paths rather than default ORM auto-save.

## Consequences

- `schemas/db/postgresql_schema.sql` is the source of truth for the relational shape going forward. Changes to the JSON schemas (already at v1.1 each) should be reflected here, and vice versa - watch for drift.
- Actual Azure Database for PostgreSQL provisioning, connection/auth setup, and migration tooling (e.g. Alembic or a similar tool for future schema changes) are still open, not covered by this ADR.
