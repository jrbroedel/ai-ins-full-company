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

SQL scripts, applied against `luxauto_demo` only (never `luxauto`):

- [`sample-data/demo/onboard_demo_states.sql`](../sample-data/demo/onboard_demo_states.sql)
  — onboards the four Tier A states (CA, NY, TX, FL) through the sanctioned
  `onboard_state()` path, all DEMO-flagged, filling the skeleton's `TBD`/null
  fields with plausible synthetic values.
- [`sample-data/demo/onboard_demo_states_tier_bc.sql`](../sample-data/demo/onboard_demo_states_tier_bc.sql)
  — the 50-state expansion: Tier B (CO, MA, HI, MI) hand-written from the research
  skeleton, and Tier C (the remaining 41 states) bulk-generated in a loop. Also
  via `onboard_state()` only, no raw inserts.
- [`sample-data/demo/seed_demo_applications.sql`](../sample-data/demo/seed_demo_applications.sql)
  — seeds the five demo application profiles, each re-homed into a demo state, and
  submits each through `submit_application()` so they move through the referral
  matrix.

The schema itself is deployed from `main` **except** for the PC-02 demo
placeholder rule documented below (`schemas/db/postgresql_schema.sql`).

## State coverage — all 50 states, three tiers

`luxauto_demo` holds **all 50 US states** in `state_rating_table_versions`, every
one onboarded via `onboard_state()` (no raw inserts). The three tiers reflect how
much real basis each row has, and the distinction is preserved in the data
(`documentation.tier` and `documentation.verified_by`):

| Tier | States | Basis | `documentation.verified_by` |
|------|--------|-------|------------------------------|
| A | CA, NY, TX, FL (4) | First demo states, plausible synthetic | *"...illustrative data only, not sourced from a real filing"* |
| B | CO, MA, HI, MI (4) | Onboarded from the 2026-08-08 research skeleton (`state_rating_tables_sample.json`); researched fields (credit-score bans, AI-governance citations, MI PIP) preserved | *"...based on the 2026-08-08 design-session research skeleton, illustrative data only, not a filed rate"* |
| C | remaining 41 | Bulk-generated placeholders, **no state-specific research**; formulaic-but-varied territory factors, standard defaults | *"...bulk-generated illustrative placeholder for 50-state demo breadth, no state-specific research performed, not a filed rate"* |

Plus **CT**, the schema's own baked-in illustrative seed (present since the first
deploy; not part of any tier). All Tier A/B/C rows carry the `DEMO-SYNTHETIC-`
SERFF prefix and `-DEMO` record_id suffix. None of it is real filed data — the
platform holds no real filed rating data for any state (CT included).

## PC-02 sanctions rule — DEMO PLACEHOLDER (first code divergence from `main`)

**This is the first change on this branch that touches code, not just data.**
Every prior piece (states, applications) was data only —
`schemas/db/postgresql_schema.sql` was byte-identical to `main`. This addition
changes the schema file, so the branch's code now diverges from `main`. That is
intentional, but do not mistake it for a reviewed production design.

What was added: a **PC-02** rule, inlined into `evaluate_application_referrals()`,
that returns `HARD_DECLINE_COMPLIANCE` (reason code `PC02_SANCTIONS_HIT`) when
`applicant_enrichment.sanctions_screen_result = 'positive_hit'`, or when any
`additional_driver_sanctions` row for the application is `positive_hit`. It
follows the same decision_log pattern as the other rules and changes no other
rule's behaviour.

- **Placeholder, not production.** The rule logic is legitimate (it only reads a
  field's value), but **nothing populates that field via a real vendor** on this
  branch. For the demo the field is seeded by hand.
- **The real path is ADR 0041** (real NameScan integration, on `main`) — a
  separate effort, **not yet built**, with its own scoping still to come
  (including the still-open question of whether a not-yet-screened application
  should also block quoting; this placeholder does **not** answer that).
- **Do not merge this rule to `main` as-is** without going through ADR 0041's own
  review. It is inlined (rather than a separate `evaluate_pc02()` function)
  specifically so the demo deploy passes the `verify_schema.py` baseline
  unchanged; the real ADR 0041 version should be its own function.

Fifth demo application seeded to exercise it: an obviously-fictional applicant
(Grigor Marchetti, TX) whose `applicant_enrichment.sanctions_screen_result` is
manually set to `'positive_hit'` before submission, landing on
`HARD_DECLINE_COMPLIANCE`. The demo now spans the full spectrum:
`AUTO_PROCEED` → `MANUAL_REVIEW_REQUIRED` → `MANUAL_REVIEW_SENIOR` →
`HARD_DECLINE_COMPLIANCE`.

## Scope boundaries

- Does **not** touch `main`, the production `luxauto` database, or
  `.github/workflows/`.
- Builds the data substrate only — no connection layer, API, or MCP server
  (the live visual "drop-in" is a separate, deferred piece of work).

## Full context

Scoped with Dash in chat on 2026-08-23 (following the MGA workbook review of
2026-08-23). That conversation holds the full rationale; it is not reproduced
here — this note only records that it exists.
