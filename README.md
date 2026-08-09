# Luxury Auto MGA — AI Underwriting Pipeline

Design and reference artifacts for an AI-driven underwriting pipeline. Luxury/high-net-worth auto is the first line of business; the platform is intended to be portable to other lines (homeowners next) via swappable schema/rating/referral "packages" rather than a rebuilt pipeline.

## Repo structure

```
schemas/             Data structure definitions (application intake, state rating table registry, etc.)
sample-data/          Populated test/reference data (synthetic applications, state rating table entries)
referral-matrices/    Hard-stop and manual-review routing logic
docs/                 Design notes, regulatory research, architecture decisions
```

## Current contents

- `schemas/state_rating_table_schema.json` — registry structure defining what the rating engine is permitted to do per state (filing status, approved/prohibited rating variables, agreed-value rules, AI governance documentation requirements).
- `sample-data/state_rating_tables_sample.json` — illustrative/directional entries for CA, NY, CO, TX, FL, MA, HI, MI. **Not verified against actual SERFF filings — every field is flagged for re-verification before production use.** See the file's own `_disclaimer` field.
- `referral-matrices/luxury_auto_referral_matrix.json` — routing rules (auto-proceed / information request / manual review / hard decline) across vehicle & valuation, driver & household, account & loss history, coverage & pricing, and process & conduct categories. Wired to the edge-case test applications described below.

## Known gap — files from an earlier session not yet in this repo

An earlier working session (before this repo existed) produced four artifacts that are **referenced throughout the schemas and referral matrix in this repo but are not currently tracked here**, because this environment's file storage resets between sessions and they were never copied into a persistent location:

- `luxury_auto_application_schema.json` — the core application intake schema (ACORD 90 + HNW carrier supplement fields), which `state_rating_table_schema.json`'s `approved_rating_variables[].variable_name` and the referral matrix's `source_fields` both assume as their field-naming reference.
- `luxury_auto_sample_applications.json` — four synthetic filled applications (clean/low-risk, moderate-risk modified vehicle, high-risk with suspended driver, exotic agreed-value edge case).
- `luxury_auto_edge_case_applications.json` — seven synthetic applications, each designed to exercise a specific referral matrix rule (garaging mismatch, undisclosed household driver, DUI, incomplete data, VIN mismatch, salvage title, business-use misrepresentation).
- A PDF rendering of one sample application (ReportLab).

**Action needed:** upload these four files (wherever they were saved after the original session) so they can be added to `schemas/` and `sample-data/` and the cross-references in this repo become resolvable rather than just descriptive.

## Regulatory research notes

Key findings from the regulatory research behind this build (August 2026) are captured inline in `schemas/state_rating_table_schema.json`'s `build_note` and in the referral matrix's `design_note`. Headline points:
- Luxury auto is written in the **admitted market** (state DOI rate/form filing via SERFF), not the Lloyd's delegated-authority model — a structurally different governance shape than a binder-based MGA.
- CA, HI, MA, and MI ban credit-based insurance scoring for auto outright; other states permit it with varying use-context restrictions.
- NAIC's Model Bulletin on AI use had been adopted by 23 states + DC as of late 2025; NY (DFS Circular Letter 2024-7) and CO (C.R.S. §10-3-1104.9) impose additional, stricter requirements this build treats as the governance ceiling.

## Status

Early design phase. No production data. No live regulatory sign-off on any state rating table entry.
