# `demo/investor-preview` — synthetic demo branch

**This branch and its database (`luxauto_demo`) contain SYNTHETIC DEMO DATA ONLY.**
None of it is real filed rating data. It exists solely for an investor-preview
demo and is **never merged into `main`**.

## What's synthetic here, and how it's labelled

Every demo state written into `luxauto_demo` is unmistakably flagged:

- `state_rating_table_versions.serff_filing_tracking_number` is prefixed
  `DEMO-SYNTHETIC-` (e.g. `DEMO-SYNTHETIC-CA-01`).
- The human-readable record label is suffixed `-DEMO` (e.g. `CA-2026-DEMO-v1`),
  carried in `state_rating_table_versions.documentation->>'record_id'` (the
  table's own `record_id` column is a generated UUID, so the label lives in the
  `documentation` JSONB).
- `state_rating_table_versions.documentation->>'verified_by'` reads
  *"Demo branch - illustrative data only, not sourced from a real filing"*.

## Purpose

Show multi-state breadth (CA / NY / TX / FL) in the platform ahead of real
filed-data collection. Real filed-data collection is **currently paused per Kent
(2026-08-22)**; the demo runs on national rates plus synthetic per-state
territory factors so the investor audience sees geographic breadth now.

## What the build does

Two SQL scripts, applied against `luxauto_demo` only (never `luxauto`):

- [`sample-data/demo/onboard_demo_states.sql`](../sample-data/demo/onboard_demo_states.sql)
  — onboards CA, NY, TX, FL through the sanctioned `onboard_state()` path, all
  DEMO-flagged, filling the skeleton's `TBD`/null fields with plausible synthetic
  values.
- [`sample-data/demo/seed_demo_applications.sql`](../sample-data/demo/seed_demo_applications.sql)
  — seeds the four `luxury_auto_sample_applications.json` profiles, each re-homed
  into one of the four demo states, and submits each through
  `submit_application()` so they move through the referral matrix.

The schema itself is deployed unmodified from `main`
(`schemas/db/postgresql_schema.sql`) — see the first implementation report.

## Scope boundaries

- Does **not** touch `main`, the production `luxauto` database, or
  `.github/workflows/`.
- Builds the data substrate only — no connection layer, API, or MCP server
  (the live visual "drop-in" is a separate, deferred piece of work).

## Full context

Scoped with Dash in chat on 2026-08-23 (following the MGA workbook review of
2026-08-23). That conversation holds the full rationale; it is not reproduced
here — this note only records that it exists.
