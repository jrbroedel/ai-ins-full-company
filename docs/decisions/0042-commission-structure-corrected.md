# ADR 0042 — Corrected Commission Structure (25% total, 12.5/12.5, 75% premium to markets)

**Status:** Accepted
**Date:** 2026-08-27
**Branch:** demo/investor-preview
**Supersedes:** ADR 0039 (commission convention). ADR 0039's model is incorrect and is replaced
by this ADR — see "Correction" below.

## Context

The demo's canonical 12-month dataset, the raters, and both BDX types must carry premium and
commission figures. Two conflicting conventions were on record and had blocked every money-
bearing feature:

- ADR 0039 (platform-coded): 30% total commission, "net 0.70 to the panel," with a
  `net_premium_to_panel` framing and a `mga_commission_rate` generated column.
- Kent's MGA Program Master workbook: 25% commission, 0.75 to the panel.

Kent (domain authority for this program) has now confirmed the correct structure, and in doing
so corrected a conceptual error in ADR 0039's model — not merely the percentage.

## Decision — the correct commission structure

On any given premium, the split is:

- **Total commission: 25% of premium**, divided:
  - **Torque (the MGA): 12.5%**
  - **Broker (who brings the business): 12.5%**
- **Premium to markets: 75%** — this goes to the panel of insurers (the "markets") that support
  the program and carry the risk. It is subdivided among the markets **by their risk
  participation share**.

Worked example (Kent's): on a $100,000 Ferrari premium —
- Broker commission (12.5%): $12,500
- Torque commission (12.5%): $12,500
- Premium to markets (75%): $75,000, split by participation. If 10 markets each take 10% of the
  risk, each receives $7,500.

## Correction — what ADR 0039 got wrong

ADR 0039 framed money flowing to the panel as involving "commission to the panel" and a
`net_premium_to_panel`. This is conceptually wrong. Per Kent:

> Commission does not go to the panel of insurers (the markets that support us). They get the
> premium.

- **Commission (25%)** is retained by Torque (12.5%) and the broker (12.5%). It is *not* paid to
  the markets.
- **Premium (75%)** is what flows to the markets, subdivided by participation.

So ADR 0039 was not merely a different-but-valid percentage (30 vs 25); it modeled the split
incorrectly by treating the panel's share as a commission-adjacent figure. This ADR replaces
that model. The 25% figure also matches Kent's workbook, so the demo, his deck, and the platform
now agree on a single source of truth.

## Implications

- **Canonical 12-month dataset:** every quote (on binds AND declines) carries a premium; from it
  the 12.5% broker commission, 12.5% Torque commission, and 75%-to-markets are derived
  deterministically.
- **Underwriting BDX:** shows premium, the commission split (broker / Torque), and premium-to-
  markets subdivided by the market panel's participation shares.
- **Claims BDX:** reports claims/losses, not commission (different artifact — see the dataset
  ADR when written).
- **Platform code:** the `mga_commission_rate` generated column and any `net_premium_to_panel`
  view/field built on the ADR 0039 model are now incorrect and must be reworked or excluded
  before they emit figures. (For the demo, commission had been kept off the dashboard entirely
  under the old conflict; that block is now resolved — figures may appear where appropriate, on
  the corrected basis.)

## Open shape questions (pending Kent, do not block this ADR)

These affect the dataset, not the commission structure itself, and are being confirmed with
Kent separately:

- Whether the 25% holds flat across the 12 months or compresses toward a lower floor (the
  premium-down-while-profitable story).
- The market panel composition and participation shares (real vs. illustrative; fixed vs.
  time-varying).
- Whether synthetic claims are generated (needed for the claims BDX and for the predictive-
  analysis triggers), and the loss experience they should show.

## Not in scope here

- Invoicing (Kent: "don't worry about invoicing at this point").
- The predictive-analysis ("SHAP") work, which is its own scoped decision.
- The canonical-dataset generation spec itself (its own ADR once the shape questions above are
  answered).
