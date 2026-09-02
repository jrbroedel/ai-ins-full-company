0049 — Canonical name-only refreeze (sha 5a2be288) and multi-vehicle insured file conventions
Status: Accepted Date: 2026-09-02 Supersedes: dataset freeze of ADR 0045 (sha faa3c9b7) — dataset only; all other 0045 decisions stand. Related: 0043 (generate-once/freeze/derive), 0044, 0045, commits 36548a3 and 1716d1e.
Context
The investor-facing insured file set required three of the five canonical insureds to carry multi-vehicle schedules (Delacroix 17, Vasquez 8, Harrington 4). Under the ADR 0043 discipline, added vehicles could not be rated into existence; they had to be adopted from the frozen canonical book so every document premium still traces to a frozen bound premium. Kent's review also established two artifact conventions the prior set did not follow: the bordereau is a monthly PROGRAM file (every certificate bound that month, one file per month), and the rating workbook's Portfolio Register — not one workbook per vehicle — is where a client's full schedule lives.
Decision

1. Twenty-six clean, reconciling bound donor policies were adopted from the frozen book, state-matched to their adopting insureds, and reattributed BY NAME ONLY (16 to Delacroix/KS, 7 to Vasquez/CA, 3 to Harrington/MA). Premiums, VINs, months, garaging states, money waterfalls and `canon.<seq>` provenance emails are unchanged. Bound GWP remains 71,301,212.64 across 7,655 binds; monthly aggregates still reconcile.
2. The canonical dataset is refrozen at sha `5a2be288360c84289225ee75ff782c947bcb6a014f7627cb16a7d45946789ac2` (commit 36548a3), superseding `faa3c9b7...`. The audit trail is `sample-data/canonical/donor_reattribution_map.json`.
3. Document-facing bind dates for adopted vehicles are normalized to the adopting insured's inception (whole schedule binds at once). Dataset month indices are NOT moved, deliberately: moving them would break the frozen monthly aggregates that drive the dashboard. This presentation liberty is recorded here and in the insured-files README.
4. Insured file conventions (commit 1716d1e): one rater per client, Rating Engine holding the lead vehicle and the Portfolio Register holding the full schedule (one row per vehicle, keyed by certificate, specimen rows cleared, per-row judgement adjustment 0); monthly program bordereaux under `insured-files/03_Monthly_BDX/` whose per-row technical premiums tie the register to the cent; consolidated quote/binder/invoice on frozen charged premiums; certificate series extended TQ-C-2026-0147..0177.
5. `templates/Exotic_Auto_UW_Bordereaux_Template.xlsx` is repaired in place: its external-workbook zone-multiplier links are localized to an internal Lists sheet so the template recalculates standalone.

Consequences

* Any artifact regenerated from the canonical book must use sha 5a2be288 and, for the three multi-vehicle insureds, must consume the adopted schedule via the reattribution map rather than re-selecting donors.
* The rating matrix template ships with six specimen Portfolio Register rows; any client-facing rater must clear or overwrite them (review trap, caught by Kent).
* Register/BDX show technical premium; client documents show frozen charged premium. Reconciling the two is a per-row judgement-adjustment exercise (register col AQ / BDX col AC) and is deliberately out of scope here.
* Blackwood and Fairweather remain on the prior single-vehicle form and per-client BDX artifacts (byte-identical); the monthly BDX series is canonical going forward.
