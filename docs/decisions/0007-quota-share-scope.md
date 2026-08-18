# ADR 0007: Quota-share / commission module scope

**Status:** Scoped and DB-side implemented; Odoo-side custom module not yet built.
**Date:** 2026-08-09

## What "quota share" means for this line of business

The Energy manual's Chapter 11 describes a Lloyd's panel: multiple syndicates each taking a fixed percentage of every risk bound under one binder, visible as a multi-market split on the policy itself. Luxury auto doesn't work that way - per ADR 0001's core regulatory finding, this is admitted-market business behind a single fronting carrier, not a Lloyd's delegated-authority panel.

In practice, that means the equivalent structure here is more likely a **reinsurance or participation arrangement behind the fronting carrier** - the carrier cedes a share of premium and risk to reinsurers (or to the MGA's own risk-sharing vehicle, if one exists), typically invisible to the policyholder. Functionally, though, the accounting shape is identical to the Lloyd's panel case: a set of participants, each with a share percentage and a commission rate, rolling up to a waterfall from gross premium down to net amount due. This ADR scopes for that shape and doesn't assume which specific arrangement (reinsurance treaty vs. MGA-owned participation vs. something else) ends up governing it - that's a business/reinsurance-structuring decision outside this ADR's scope, not a technical one.

## The commission waterfall (direct analogue to Energy manual Ch.10)

```
Gross premium
  less retail broker commission
  less wholesale broker commission (where applicable)
  less the MGA's own commission (including any profit commission,
    calculated on the underwriting-year result after losses and expenses)
= Net premium due to the capacity provider
```

This is the same waterfall structure the Energy manual documents, applied to a program rather than a syndicate panel.

## What's been built (database side)

Added to `schemas/db/postgresql_schema.sql`:

- **`insurance_programs`** - one row per program (capacity provider, effective period, estimated premium income).
- **`program_participants`** - one row per participant on a program (`capacity_provider`, `reinsurer`, or `mga_retention`), with `share_percentage` and `commission_rate`. `profit_commission_formula` is a free-text field for now, not a computed formula - see open items below.
- **`quotes.program_id`** - every quote now references which program's participant panel and commission structure applies to it.
- **A deferred constraint trigger enforcing that risk-bearing participant shares (`capacity_provider` + `reinsurer`) sum to exactly 100% per program**, checked at transaction commit rather than after each individual row change - mirrors the discipline already established for the state rating table's exclusion constraint and the decision log's append-only trigger.

### Verified, not just written
Ran against a live PostgreSQL 16 instance in this session:
1. A 70/30 capacity-provider/reinsurer split inserted within a single transaction - committed successfully.
2. A 60/25 split (85%, not 100%) inserted within a transaction - correctly rejected at `COMMIT` with the exact shortfall reported.

### A limitation flagged on purpose, not hidden
The 100%-sum check is **not temporally aware** - it validates the current total for a program on every write, not a full time-range-overlap-aware version the way the state rating table's exclusion constraint is. A program whose participant panel changes over time (a reinsurer swapped mid-year, for example) isn't yet protected against a gap or overlap in *when* each participant's share applies. This needs a more rigorous version before it's production-safe - documented here explicitly rather than letting the current simplified version pass as more robust than it is.

## What's not yet built: the Odoo module itself

Per the MGA software research (`docs/reference-materials/MGA_Software_Options.docx`), quota share isn't natively supported by any open-source ERP option, Odoo included - this was already known going in. What's now scoped, ready to build against:

- Odoo-side models/views over `insurance_programs` and `program_participants` (read via the view pattern from ADR 0006; writes via controlled server actions, same as everywhere else in this architecture).
- The waterfall calculation itself as a computed report - given gross premium and a program's participant rows, produce the net-due figure per participant.
- A capacity-provider settlement report - the bordereau-equivalent artifact mentioned in earlier design notes, built from `quotes` joined to `program_participants` for a given period. Same underlying data the Energy manual's premium bordereau serves, different regulatory context.
- **Trust accounting is not custom development** - worth noting explicitly, since it could be mistaken for part of this module. Segregating collected premium in a fiduciary account until settlement (mentioned in the Energy manual's Ch.10) is standard practice most state DOIs require of MGAs, but it maps cleanly onto Odoo's native Accounting module (a dedicated bank account/journal) - configuration, not code.

## Open items for underwriting/finance leadership

Same pattern as the referral matrix's own open items list - these are business decisions, not things derivable from the schema:

- ~~The layered retail/wholesale broker commission tiers - the top of the waterfall above (`less retail/wholesale broker commission`, `less the MGA's own commission`), which the "what's been built" section deliberately did not include, and which `calculate_premium_waterfall()`'s own comment flags as unresolved.~~ **Closed by the 2026-08-18 addendum below** (`0007-addendum-broker-mga-commission.md`): the broker + MGA *acquisition* commission is now modelled - confirmed as a 30% combined cap, a 15% broker ceiling, MGA filling the remainder, a single retail-or-wholesale channel only, and a broker legally required on every placement. (Wiring it into `calculate_premium_waterfall()`'s panel/cession side - so the panel's "gross" becomes net-of-acquisition - is separate follow-on work, not part of the addendum.)
- The actual profit-commission formula (currently a free-text placeholder field).
- Who the capacity provider and any reinsurance/participation partners actually are, and their real percentages - `program_participants` is ready to hold this data the moment it's decided, but no real program has been created yet.
- Settlement timing (the Energy manual's 30-60 day broker settlement window is illustrative of market practice, not a number this project has picked yet).

## Consequences

- This is the second table-design addition since ADR 0005 (Odoo integration was the first, in ADR 0006) - `postgresql_schema.sql` is accumulating real structure and should keep being treated as living source of truth, not a one-time artifact.
- ~~The temporal-overlap gap in the 100%-sum check is a known, tracked simplification - revisit before any real program data goes in, not before.~~ **Closed by ADR 0017** (2026-08-13), still before any real program data went in. It turned out to be worse than a simplification: the non-temporal check also *rejected* correct panel changes, so the panel could never have changed at all.

## Addendum — 2026-08-18: broker + MGA acquisition commission (the top of the waterfall)

The waterfall this ADR drew (`gross premium − retail/wholesale broker − MGA = net to the capacity provider`) had only its **bottom** built - the panel/cession side (`insurance_programs`, `program_participants`, `calculate_premium_waterfall()`). Its **top** - the broker and MGA *acquisition* commission on gross premium - was documented but not modelled, and `calculate_premium_waterfall()`'s own comment named that gap. It is now built.

Confirmed business rules (from underwriting leadership):

- **30% combined cap** - broker + MGA commission together may not exceed 30% of gross premium.
- **15% broker ceiling** - and only ever one broker channel per placement (retail *or* wholesale/surplus-lines, never both at once).
- **MGA fills the remainder** - MGA commission = 30% − broker, not an independent number ("MGA's share fills whatever's left under the 30% ceiling").
- **A broker is legally required on every placement** - so the channel is mandatory; there is no direct/no-broker case.
- **No floor** on either side (broker may be 0%).

Schema-level detail (the columns, the enum, the generated MGA column, the caps as constraints, and what is deliberately still deferred - broker identity, the Odoo view, and wiring this into the panel waterfall) is in the addendum ADR, **`0007-addendum-broker-mga-commission.md`**. A future reader landing here should go there for the mechanics; a reader landing there is pointed back to this ADR for the waterfall context.
