# ADR 0027: Vehicle category expansion — pre-war/vintage and restomod/coachbuilt

**Status:** Decided; DB-side implemented
**Date:** 2026-08-18
**Follows from:** ADR 0005 (the application-intake schema and `vehicle_category_t`), ADR 0016 (the bind-time vehicle snapshot onto `policy_vehicles`), the referral matrix's VV-04

## What this adds, and deliberately does not

Exactly **two** new `vehicle_category_t` values: `pre_war_vintage` and `restomod_coachbuilt`. **Not** the full 12-class taxonomy from the Exotic/Collector rating workbook — these two specifically, because they are the only classes flagged as real near-term interest. Usage categories (`primary_use`) are untouched — that delegation was scoped to vehicle categories only, so `primary_use` keeps its four values.

**Why only two, and why this is a real constraint rather than caution for its own sake:** adding categories the system cannot actually underwrite yet (rate, refer, or price correctly) would let the product *look* more capable than it is — exactly the gap that surfaces badly later when a customer picks an unsupported category and the pipeline proceeds as if it's handled. These two are added because they are genuinely wanted, not to pad the list. This ADR is **record-and-validate only**: the system can now record and validate that a vehicle is one of these types; it does **not** know how to price one. Pricing/rating for them is the separate, larger rating-engine work still to come.

## What `vehicle_category` actually is (confirmed, not assumed)

A **live Postgres enum** — `vehicle_category_t`, currently `('production_luxury', 'exotic', 'classic_collector', 'modified_performance')`, enforced on `vehicles.vehicle_category` and `policy_vehicles.vehicle_category` (both `NOT NULL`) and exposed on `luxauto_policy_vehicle_view`. Not documented-only. Server is PostgreSQL 16.14.

## The values and the migration

- **Naming:** `pre_war_vintage`, `restomod_coachbuilt` — snake_case, two-token descriptive, matching the existing `classic_collector` / `modified_performance` style.
- **Fresh apply:** the two values are added inline to the `CREATE TYPE vehicle_category_t AS ENUM (...)`, so a new database gets all six.
- **Existing database:** the `CREATE TYPE` raises `duplicate_object` (caught), so the values arrive by `ALTER TYPE vehicle_category_t ADD VALUE IF NOT EXISTS ...` — idempotent, appended at the end so the existing four keep their sort order.
- **Transaction safety (the classic Postgres gotcha, checked):** a newly added enum value cannot be *used* in the same transaction that added it. It does not bite here: `postgresql_schema.sql` has no top-level `BEGIN`/`COMMIT`, so `psql -f` autocommits each statement — the `ALTER TYPE ... ADD VALUE` commits immediately, and nothing in the schema file *uses* the value (data does, in later, separate transactions: the test suite runs in its own `BEGIN…ROLLBACK`, and any real application insert is its own statement). So inline application is safe; no standalone/pre-step is needed.

## Every call site checked — and why nothing else needs changing

`vehicle_category` is treated as an **opaque enum everywhere** — there is no `CASE`, `CHECK`, or per-value branch on the specific category values anywhere in code:

- **`postgresql_schema.sql`:** only the `CREATE TYPE`, the two `NOT NULL` columns, the bind-time snapshot passthrough (`bind_policy()` copies the value), `correct_policy_vehicle()`'s parameter, and the view's select. All pass the value through unchanged — new values flow through automatically.
- **Referral matrix — VV-04:** fires on "a modification field is populated while `vehicle_category` is still `production_luxury` rather than `modified_performance`." It keys on those two specific values only; it does not enumerate the full set, so the new categories neither trip it falsely nor need it changed. VV-04 is also **not built in code** — the referral engine (ADR 0026) implemented only AL-01/CP-02/DH-01/PC-03 — so there is no code path to update. (VV-01 mentions `vehicle_category` in prose only.)
- **Built referral engine (ADR 0026):** none of AL-01/CP-02/DH-01/PC-03 reference `vehicle_category`, so a new-category vehicle behaves exactly like any other — confirmed by tests/0027 T3 (a clean pre_war_vintage application still `AUTO_PROCEED`s with all four decision_log rows).
- **Odoo:** `luxauto_policy_vehicle.vehicle_category` is a **readonly `Char`** (the model is `_auto = False` over a view), not a hardcoded `Selection`, and the form/list views just display it. New values render automatically — there is no Odoo-side enumeration to update, and no writable dropdown that would otherwise omit them. (Category selection happens at intake against the application schema / pipeline, not in an Odoo form.)
- **Application schema:** `schemas/luxury_auto_application_schema.json`'s documented enum was updated to list all six, so the intake/reference contract matches the database.

## Flagged, not built: whether the new categories need their own referral rule

VV-04 exists because a *modified* car mislabeled as stock `production_luxury` is a risk/value gap worth a human's eyes. A parallel question — e.g. "should a `restomod_coachbuilt` require modifications to be declared, or a `pre_war_vintage` require an agreed-value appraisal?" — is a genuine underwriting-rule decision, but it is **rating/referral-engine work, not part of this change**, and is flagged here rather than silently built. Adding the values does not create any such rule; it only lets a vehicle *be* one of these types.

## Testing

`tests/0027_vehicle_category_expansion.sql`: both new values insert on `vehicles` and are distinct from the four originals (T1); a new category snapshots through `bind_policy()` onto `policy_vehicles` (T2); and the built referral engine handles a new-category vehicle identically to any other — no error, correct outcome, all four decision_log rows (T3), which is the "nothing downstream silently mishandles them" check rather than mere insertion success. `scripts/run-tests.sh` runs all suites; all pass.

## Consequences

- The system can record and validate `pre_war_vintage` and `restomod_coachbuilt`; it cannot yet price or rate them — an honest, documented boundary, not a hidden one.
- No `verify_schema.py` baseline change: adding enum *values* does not add a *type* (the parser counts `CREATE TYPE` statements), and there is no new table/function/trigger/view/SET NOT NULL column.
- The other ten workbook classes and any `primary_use` change are explicitly out of scope. Rating/pricing and any category-specific referral rules for the new types are the next, separate work.
