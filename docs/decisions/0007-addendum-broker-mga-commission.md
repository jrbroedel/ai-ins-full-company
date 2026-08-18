# ADR 0007 addendum: broker + MGA acquisition commission

**Status:** Decided; DB-side implemented
**Date:** 2026-08-18
**Extends:** ADR 0007 (quota-share / commission waterfall). This is the **top** of that ADR's waterfall — the broker and MGA acquisition commission on gross premium — which ADR 0007 documented but left unbuilt (only the panel/cession side was built). See ADR 0007's 2026-08-18 addendum note and its now-closed open item.

## The two commissions, kept distinct

ADR 0007's waterfall is `gross premium − retail/wholesale broker − MGA = net to the capacity provider → split among the panel`. This addendum builds the acquisition layer (broker + MGA), **not** the panel/cession layer (`program_participants.commission_rate`, `calculate_premium_waterfall()`), which already existed. These must not be conflated: `program_participants.commission_rate` is a *panel participant's* cession commission; the columns added here are the *broker's* and the *MGA's* acquisition commission on gross premium.

## Confirmed business rules

- **30% combined cap** — broker + MGA commission together may not exceed 30% of gross premium.
- **15% broker ceiling.**
- **Single channel only** — retail *or* wholesale/surplus-lines, never both on the same bound policy. ("It's either retail or wholesale, not both. If it's both we'll think about that then" — so the dual-channel case is a future decision, not designed around now.)
- **MGA fills the remainder** — MGA commission = 30% − broker, not an independent number.
- **A broker is legally required on every placement** — the channel is mandatory; there is no direct/no-broker case.
- **No floor** on either side (broker may be 0%).

## Where it lives: new columns on `quotes`

The commission split lives on `quotes`, decided at quote time and inherited by the bound policy via `quote_id` — exactly how `premium_amount` already works (the policy carries no commission columns of its own; it reads them off its quote). A new table would be over-engineering: one channel, two rates, 1:1 with the placement. This also matches the project's "decided facts get stored, not recomputed" preference — the split is part of the priced, issued offer and is frozen once bound.

| Column | Definition | Purpose |
|---|---|---|
| `broker_channel` | `broker_channel_t NOT NULL` (new enum: `retail`, `wholesale`) | which single channel placed the risk |
| `broker_commission_rate` | `NUMERIC(5,2) NOT NULL`, `CHECK (>= 0 AND <= 15)` | broker % of gross premium |
| `mga_commission_rate` | `NUMERIC(5,2) GENERATED ALWAYS AS (30 - broker_commission_rate) STORED` | MGA % — derived, stored, not settable |

**Rates are percentages, not fractions** — confirmed against the existing convention: `program_participants.commission_rate` is a percentage that `calculate_premium_waterfall()` divides by 100 (`gross_share × rate / 100`). So `broker_commission_rate = 15` means 15%, and `mga = 30 - broker` is likewise in percentage points.

## Enforcement — all at the database level, structural where possible

- **Single channel:** the `broker_channel` enum *is* the constraint. One column holds exactly one value, so a dual retail+wholesale placement is **structurally unrepresentable** — the strongest enforcement, and it matches "either/or, never both" without building the deferred dual case (which, if it ever arises, is a future schema change this doesn't obstruct). No CHECK is needed beyond the column being typed and `NOT NULL`.
- **15% broker ceiling:** `CHECK (broker_commission_rate >= 0 AND broker_commission_rate <= 15)` (named `quotes_broker_commission_rate_ck`). No floor beyond 0, per the confirmed "no floor."
- **30% combined cap:** enforced **structurally** by the generated column. `mga = 30 - broker`, so `broker + mga = 30` always, which is `≤ 30` by construction — no separate combined CHECK, which would be trivially always-true. The `30` and `15` are hard-coded literals (like CP-02's $2M); changing a cap is a deliberate schema change, not config.
- **MGA is stored *and* derived.** A `GENERATED ALWAYS ... STORED` column is stored (materialised, queryable like any column — matching "decided facts stored") *and* structurally correct: it cannot be set wrong or drift, and "MGA fills the remainder" becomes a property of the schema rather than something a bind/quote function must remember to compute. Attempting to insert `mga_commission_rate` directly is refused by Postgres (asserted in the tests).

## Idempotent apply against the existing `quotes` table

`quotes` predates this addendum, so on a live database the `CREATE TABLE IF NOT EXISTS` is a no-op and the columns arrive by `ALTER` (a fresh apply gets them inline from the CREATE TABLE). Added nullable, then `SET NOT NULL` under a guard that counts rows lacking a channel/rate and refuses with a clear message rather than a bare NOT NULL violation — the same discipline the ADR 0016 addendum used for the vin/identity columns. `quotes` is empty today, so the guard passes; the CHECK is added under a `pg_constraint` lookup (idempotent), and the inline constraint carries the same name so a fresh apply adds it once, not twice.

## Deliberately out of scope (all flagged, none forgotten)

- **No broker identity field.** Confirmed: record the channel + rate only, not *which* broker. Settlement will eventually have to pay a specific broker; adding a minimal broker reference is a future decision, not built here.
- **No wiring into `calculate_premium_waterfall()` / the panel side.** Broker + MGA sits at the top of the waterfall; making the panel's "gross" net-of-acquisition is separate follow-on work. Storing the split (this addendum) is prerequisite to and independent of that. `calculate_premium_waterfall()`, `bind_policy()`, and every other prior-ADR function are untouched.
- **No dollar-split helper function.** A helper turning the rates into dollar amounts off `premium_amount` was considered and *not* built — there is no consumer yet (the Odoo view and the panel-waterfall integration are both deferred), and building unused plumbing is exactly what this project avoids. It belongs with whichever of those consumers is built first.
- **No Odoo view/model.** Per the standing decision, DB work ships first; Odoo visibility for recent work (reinstatement, referral engine, short-rate seeding, and now this) is batched into a later dedicated pass.

## Testing

`tests/0007_addendum_broker_mga_commission.sql`: the broker-rate CHECK boundary at 0, 15, and just over 15 (15.01 and 16 both rejected); `mga = 30 - broker` across values including the boundary (broker 15 → MGA 15) and that MGA cannot be set independently; `broker_channel` rejects NULL and any out-of-enum value and accepts both valid values; and a quote's commission fields carrying through `bind_policy()` to the bound policy, the same inheritance the premium already has. The three existing fixtures that insert quotes (0018, 0023, 0024) were updated to supply the now-required `broker_channel`/`broker_commission_rate`. `scripts/run-tests.sh` runs all suites; all pass.

## Consequences

- The full ADR 0007 waterfall is now representable end to end: acquisition commission (this addendum) on top, panel cession (original ADR 0007) below.
- `verify_schema.py` baseline moves by +1 type (`broker_channel_t`) and +2 SET NOT NULL columns; no new table, function, view, or trigger.
- The next natural step is wiring acquisition commission into `calculate_premium_waterfall()` (net-of-acquisition gross to the panel) and surfacing all of it in the deferred Odoo pass — both explicitly out of scope here.
