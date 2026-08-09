# ADR 0006: How Odoo talks to the pipeline's database

**Status:** Decided
**Date:** 2026-08-09
**Follows from:** the open question flagged (not decided) in ADR 0005.

## The fact that settles this

Odoo's ORM requires every model's primary key to be an auto-incrementing **integer** called `id`. This isn't a style convention - it's structural. Odoo's own 19.0 tutorial documentation shows the actual `psql \d` output of a standard Odoo-managed table:

```
id | integer | not null | nextval('estate_property_id_seq'::regclass)
```

Every model gets this. `many2one` relations, the chatter/mail-thread mixin, `ir.attachment` linkage, XML-ID references - large parts of Odoo's internals assume an integer `id`. There is no supported, first-class way to make a model's primary `id` a UUID.

This directly rules out **Option A** from ADR 0005 as originally framed: Odoo models cannot simply declare `_table = 'applications'` and treat our UUID-keyed pipeline tables as their own primary storage. The ORM would either refuse to manage the table sensibly or require compromises (Odoo's own `id` column, separate from our `application_id`) that end up looking like Option B anyway - so there's no version of "just point Odoo at our tables" that avoids the integer/UUID mismatch. Better to design for it directly.

## Decision

**Odoo owns its own thin, integer-keyed models. The pipeline's UUID-keyed tables (`schemas/db/postgresql_schema.sql`) remain the system of record and are never written to directly by Odoo's default ORM save behavior.**

Concretely, two different paths for reads and writes:

### Reads: `_auto = False` Odoo models backed by SQL views
Odoo has a documented, standard pattern for this exact situation (models backed by data Odoo didn't create) - a model with `_auto = False` and an overridden `init()` that creates a SQL `VIEW` instead of a normal table. Odoo still requires that view to expose an `id` column, so the view derives a stable pseudo-integer from each UUID primary key (a standard, documented workaround in the Odoo ecosystem - hashing the UUID into a 32-bit integer, e.g. via `('x' || substr(md5(application_id::text), 1, 8))::bit(32)::int`) purely so Odoo's web client has something to key its list/form views on. This is display-only plumbing - the real identity of a record is still the pipeline's UUID.

This gives underwriters and brokers Odoo list views, kanban boards, and forms over live pipeline data with no duplication and no sync lag - the view always reflects the current table contents.

### Writes: explicit, controlled paths - not Odoo's default auto-save
Odoo's default behavior is "any field on a form the user can edit gets saved back to the table on its own." That's the wrong default here, for a reason specific to this project: every change that matters (an underwriter resolving a referral, an application field being corrected) needs a `decision_log` row, and the append-only discipline that table enforces (ADR 0005) only means something if writes go through a path that's guaranteed to also write the log entry. A stray direct ORM write on a `_auto = False` view wouldn't do that.

So: actions that change pipeline state are implemented as explicit Odoo server actions / controller methods that call into the pipeline's own write logic (stored procedures for now, a proper service layer later if the multi-industry goal demands it) - not as editable form fields that Odoo saves on its own. The UI can still feel like "editing a form," but the save button is wired to a controlled action, not the ORM's default write.

## Why not a synced/duplicated copy instead

An alternative worth naming and rejecting: give Odoo its own integer-keyed tables that mirror pipeline data, kept in sync via triggers or a background job. Rejected for now - it introduces a second copy of the truth, sync lag, and a whole class of "which copy is right" bugs, for no benefit over the view-based approach given the data lives in the same Postgres instance anyway (no network hop, no separate service to keep available). Worth revisiting only if Odoo and the pipeline end up on physically separate databases later - not the current plan.

## Consequences

- Every future pipeline table needs a corresponding read-side view (with the hashed-integer `id` trick) if Odoo needs to display it - a small but real piece of boilerplate per table.
- Every action a user can take in the Odoo UI that changes pipeline state needs an explicit server action wired to pipeline write logic - more upfront design per feature than "just add a field to the form," but this is the cost of keeping the decision log honest.
- This keeps ADR 0001's database-agnostic/UI-agnostic principle intact in practice, not just in intent: the pipeline's tables and logic don't reference Odoo at all; Odoo reaches into them, not the other way around.
- Not yet decided: the exact mechanism for write actions (raw SQL in Python server actions vs. Postgres stored procedures vs. a future API layer). Small enough to resolve during implementation rather than needing its own ADR now.
