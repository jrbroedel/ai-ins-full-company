# ADR 0039: broker/MGA acquisition commission wired into the premium waterfall

**Status:** Decided; implemented

**Superseded by ADR 0042** (2026-08-27) — the commission model here is incorrect; the markets receive premium (75%), not commission. Correct structure: 25% total commission (12.5% Torque / 12.5% broker), 75% premium to markets by participation. See ADR 0042.
**Date:** 2026-08-22
**Follows from:** ADR 0007 + its addendum (the quota-share waterfall and the broker/MGA acquisition columns this finally wires together), ADR 0010 (`calculate_premium_waterfall`, "where the waterfall math lives"), ADR 0014 (`calculate_endorsement_waterfall`, and the raw-overload split this reuses), ADR 0018 (`calculate_cancellation_waterfall`), ADR 0028 (`compute_indicative_premium`, the gross premium source), ADR 0013 (the settlement view this changes)

## Scope

ADR 0007's addendum added `quotes.broker_commission_rate` / `mga_commission_rate` (the 30% combined acquisition cap as a schema fact) but explicitly left them unwired: *"No wiring into `calculate_premium_waterfall()` … making the panel's gross net-of-acquisition is separate follow-on work."* This ADR is that work — the **top** of the ADR 0007 waterfall: `gross − retail/wholesale broker − MGA = net to the capacity panel → split among participants`.

The two commission layers stay distinct (per the addendum): `program_participants.commission_rate` is the *panel participant's cession commission* (untouched); the broker/MGA rates are the *acquisition commission on gross*. This ADR makes the panel cede **net of acquisition**, and adds a per-quote acquisition breakdown surface.

## The computation

For a quote with gross premium `G` and stored rates:

1. `broker_commission_amount = G × broker_commission_rate / 100`
2. `mga_commission_amount = G × mga_commission_rate / 100`
3. `net_premium_to_panel = G × (1 − (broker_commission_rate + mga_commission_rate)/100)`
4. Panel (existing math, base now net): each active `program_participants` row gets `gross_share = net_premium_to_panel × share_percentage/100`, then its own `commission_rate` and `net_due`.

**The net factor is read from the quote's frozen rates, never a hardcoded `0.70`.** Because `mga = 30 − broker` (generated column), `broker + mga = 30` always, so net-to-panel is `G × 0.70` for every quote today — but reading the columns keeps it correct-by-construction if the cap ever changes, and documents intent. The broker/MGA split moves dollars between broker and MGA only; it never changes what the panel receives.

## Touches to previously-shipped functions (flagged, not buried)

This is **not** purely new code alongside the old. Three entrypoints were **modified** to apply the net-of-acquisition factor — called out here the same way ADR 0037 flagged the `submit_application()` reorder:

- **`calculate_premium_waterfall(quote_id)`** (ADR 0010) — now cedes `premium_amount × net_factor`.
- **`calculate_endorsement_waterfall()`** (ADR 0014) — now cedes `premium_delta × net_factor`.
- **`calculate_cancellation_waterfall()`** (ADR 0018) — now cedes `return_premium × net_factor`.

Applied **uniformly** across new business, endorsements, and cancellations (a deliberate decision): an endorsement's additional premium carries acquisition commission and a cancellation's return premium claws it back pro-rata, so ceding gross for one and net for another would be accounting-incoherent. The gross figures the customer sees (`premium_amount`, `return_premium`) are unchanged; only the *panel's share* is now net.

**The raw `calculate_premium_waterfall(program_id, amount, as_of)` overload is untouched** — it stays a pure distributor with no acquisition awareness. The acquisition deduction lives only in the three entrypoints that can see the quote (and thus its rates). This preserves the raw overload's direct-call semantics (a caller passing an explicit amount gets it distributed as-is) and the "math written once" principle.

## The acquisition surface — separate, not panel rows

`calculate_commission_waterfall(quote_id)` returns one row per quote: `gross_premium, broker_channel, broker_commission_rate, broker_commission_amount, mga_commission_rate, mga_commission_amount, net_premium_to_panel`. Broker and MGA are **not** `participant_type_t` values (`capacity_provider`/`reinsurer`/`mga_retention`), so folding them into `calculate_premium_waterfall()`'s per-participant rows would abuse that type — they are a separate per-quote layer. `SECURITY DEFINER` read gateway with a pinned search_path, granted to `odoo`, same conventions as the panel waterfall. The acquisition columns are **appended** to `luxauto_premium_waterfall_view` (`CREATE OR REPLACE` can only append, per the view's own evolution constraint), so the full top-to-bottom waterfall reads in one place.

## Store vs. compute → compute on read

The **rates** are already stored and frozen on the quote (set by `create_quote()`, inherited by the policy via `quote_id`, immutable once bound) — that is the decided, auditable fact and it already gives the lock-at-quote-time property. The dollar **amounts** are pure functions of frozen rates × frozen premium, so they are computed on read (matching `calculate_premium_waterfall`'s own nature) rather than stored — no new columns, no drift risk against the generated rate.

## No decision_log write (considered, not defaulted)

Commission calculation is **deterministic arithmetic on already-`CHECK`-constrained, quote-frozen rates** — not a discretionary decision like a referral disposition. The NY DFS 2024-7 auditability need is met by the **frozen rate itself** (stored on the immutable-once-bound quote, the 30% cap structural via the generated column, the 15% ceiling a CHECK), not by a log row. `decision_log` is for referral-rule dispositions; a commission-arithmetic entry there would be noise. So **no audit-log write** — a deliberate decision recorded here.

## Blast radius — and a fifth assertion beyond the four scoped

The uniform net-of-acquisition change scaled the panel figures by `0.70` (all fixtures are retail/broker-10 → broker+mga = 30). `tests/0018` needed the four expected-value edits identified up front — T1 cancellation `SUM(gross_share) −27500 → −19250` and `Fronting Co −16500 → −11550`; T2 endorsement `−6000 → −4200`; T3 `−6500 → −4550` — **plus a fifth found during implementation**: `tests/0018` T4 asserts `luxauto_settlement_view`'s `return_premium` leg, which reads `calculate_cancellation_waterfall`, so its sum shifted `−33400 → −23380` (`−33400 × 0.70`). All five verified against the real fixtures, not just round numbers. The **direct raw-overload call** in T2 (`calculate_premium_waterfall(program, −6000, …) → −3600.00/−360.00/−3240.00`) is **unchanged**, confirming the raw overload stayed pure. `tests/0017` (panel share-integrity, no dollar sums) and `tests/0033` (asserts quote premium, not net_due) are insulated.

## Testing

`tests/0039_commission_waterfall.sql` (3 cases): acquisition breakdown across broker `0`/`10`/`15` (both boundaries) incl. the real `36500` figure with reconciliation `broker$ + mga$ + net = gross`; the `net_premium_to_panel = gross × 0.70` invariant; the panel now ceding net (`SUM(gross_share) = 70000` not `100000`, 60% share = `42000`); and the appended view columns with net-based panel figures. `tests/0018` updated for the five shifted assertions. `scripts/run-tests.sh`: all 21 suites pass against luxauto-pg.

## Consequences

- The ADR 0007 waterfall is now complete end to end: acquisition (broker/MGA) on top, panel cession below, reconciling to gross. `luxauto_premium_waterfall_view` and `luxauto_settlement_view` now report net-of-acquisition panel figures (a behavior change for any existing reader; intended).
- Three prior-ADR functions (0010/0014/0018 waterfalls) were modified, not just extended — noted above so a future reader treats it as a deliberate touch.
- `broker_channel` (retail/wholesale) still does not change the waterfall shape: `broker_commission_rate` is the full broker take regardless, and the dual-channel layered case remains deferred (ADR 0007 addendum).
- `verify_schema.py` baseline: **functions 69 → 70** (`calculate_commission_waterfall`); views via `CREATE OR REPLACE` (no count change); no new tables/types/triggers.
