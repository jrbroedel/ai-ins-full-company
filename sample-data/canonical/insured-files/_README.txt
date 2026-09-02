TORQUE UNDERWRITERS — Insured Files (5 insureds; 3 multi-vehicle schedules)

Delacroix (17 vehicles), Vasquez (8), Harrington (4) bind their full schedules at policy
inception. Blackwood and Fairweather are unchanged from the prior single-vehicle set
(byte-identical, incl. their in-folder BDX copies).

Per insured folder:
  01_Submission  Revised policy-level Word form: one Section-4 vehicle block per scheduled
                 vehicle, with per-vehicle garaging/security/usage.
  02_Rater       ONE rating matrix per client. The Rating Engine holds the schedule's lead
                 vehicle; the PORTFOLIO REGISTER holds the full schedule — one row per
                 vehicle, keyed by certificate no., each row rating to its own technical
                 premium (all AUTO-BIND; specimen rows cleared; x14 dropdowns and charts
                 preserved; per-row judgement adj left 0).
  04/05/06       Consolidated quote / binder / invoice: full schedule with per-vehicle
                 certs and frozen premiums; coverage split, fee schedule ($250/cert + $150
                 inspection >= $250k agreed value) and per-state SL tax bases identical to
                 the prior shipped set.

03_Monthly_BDX/  MONTHLY PROGRAM bordereaux — one file per month listing every certificate
                 bound that month across the book (2025-08 Delacroix x17, 2025-09 Vasquez
                 x8, 2025-10 Harrington x4, 2025-11 Fairweather, 2025-12 Blackwood). Each
                 row's technical premium ties its rater's Portfolio Register row exactly;
                 all rows foot PASS.

Client documents (quote/binder/invoice) show the charged premium frozen in the canonical
book (ADR 0045, sha faa3c9b7…) — every vehicle's premium traces to its frozen canonical
bound premium. The rater register and BDX show TECHNICAL premium (judgement adj 0); set
the register's AQ column / BDX column AC to reconcile to charged. Added vehicles are
donor policies from the frozen book, state-matched, reattributed by NAME ONLY, with
document-facing bind dates normalized to inception (dataset months untouched, so frozen
monthly aggregates still reconcile). See _generator/donor_reattribution_map.json and
canonical_dataset_updated.json (proposed refreeze sha 5a2be288…). All data synthetic.
