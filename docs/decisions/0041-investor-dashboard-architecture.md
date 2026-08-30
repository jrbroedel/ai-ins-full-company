# ADR 0041 — Investor Dashboard: Snapshot-to-Blob + Entra-Gated Static Web App

**Status:** Accepted (live in production-demo; deployed, access-gated, custom-domained, generator + control panel operational)
**Date:** 2026-08-26
**Branch:** demo/investor-preview
**Supersedes / relates to:** demo/investor-preview build (separate `luxauto_demo` DB), ADR 0039 (commission convention — see "Commission excluded" below)

## Context

The investor demo needs a live-feeling visual dashboard for non-technical C-level viewers,
showing applications flowing through the underwriting pipeline (intake → enrichment →
referral evaluation → disposition → quote) in approximately real time. Two hard constraints
shaped the design:

1. **Odoo remains the system of record and the workplace.** The dashboard is a strictly
   read-only *window* onto pipeline state — it performs no underwriting and is not operated
   from. Work happens in Odoo; the dashboard reflects it.
2. **`luxauto_demo` (on `luxauto-pg`) is VNet-private.** A browser cannot reach the database
   directly, so some component inside the network must bridge to a viewable surface.

The audience is non-technical executives who care about the visual, so pipeline *motion* is
the hero; financial tiles are supporting context.

## Decision

Three components, all in the demo lane (`PGDATABASE=luxauto_demo`), nothing touching
production `luxauto`:

1. **Snapshot exporter** (`scripts/lib/export_dashboard_snapshot.py`, wrapper
   `scripts/export-dashboard-snapshot.sh`) — reads dashboard-source views only, assembles a
   single `snapshot.json`, writes it to a **private** Azure Blob container every 3–5s.
   Opens Postgres `readonly=True` and issues only SELECTs. Credentials via the existing
   managed-identity → Key Vault → Postgres pattern; storage key pulled from the same vault.

2. **Static Web App (Standard tier)** `luxauto-dashboard-swa` — serves the dashboard frontend
   (`dashboard-swa/frontend/index.html`, served verbatim) behind Microsoft Entra login.

3. **Linked Function App (Flex Consumption, Node 20)** `luxauto-dashboard-api` — exposes
   `GET /api/snapshot`, which reads the private blob **server-side via managed identity**, so
   the browser never sees the blob URL or any storage credential.

### Why these choices (alternatives considered)

- **Snapshot-to-Blob over live DB polling.** Nothing live in the room during a pitch —
  eliminates connectivity/query-hang risk without sacrificing the real-data feel. The
  dashboard polls a static JSON that is at most a few seconds stale. A live-DB-polling
  dashboard that stalls mid-pitch is the worst outcome; a snapshot is always instantly
  available.
- **Static Web App Standard, not Free.** Free tier cannot do custom Entra auth with
  "assignment required." Standard is ~$9/mo.
- **Linked Function App, not SWA built-in managed functions.** SWA's built-in functions
  cannot use a managed identity to read Blob (Microsoft's FAQ limits them to Key Vault).
  A bring-your-own linked Function App was required to keep the "no SAS, no public blob,
  managed-identity read" posture. This broke the original "exactly one resource" goal, which
  was rescinded — the security posture matters, the resource count did not. Function App is
  on Flex Consumption (serverless, ~$0 idle).

### Access model — Entra app-role assignment (allow-list, not tenant-wide)

- Enforcement is **app-role assignment** ("assignment required" = yes on the app
  registration): tenant membership alone does **not** grant access.
- The allow-list is a single Entra security group, `luxauto-dashboard-access`. Add/remove a
  person by editing group membership — no redeploy, no link to rotate.
- External collaborators (e.g. Kent, a Gmail address) are added as **B2B guests** in the
  tenant, then added to the group.
- This was chosen over a SAS "secret link" (leaks on forward, no per-person revocation) and
  over tenant-wide auth (too broad — "just us" means an explicit list of people).

### Security invariants (must hold)

- Blob container `demo-dashboard` stays **private** (`allowBlobPublicAccess=False`,
  `publicAccess=None`). **No SAS token, ever.**
- The Function App's managed identity gets **Storage Blob Data Reader scoped to the one
  storage account** (`luxautosa91a2e1`) — nothing broader.
- The **Entra client secret** lives only in SWA app settings
  (`clientSecretSettingName: ENTRA_CLIENT_SECRET`). It is **never** committed to the repo,
  written to memory, or placed in chat. `.gitignore` carries `*secret*` / `.env` /
  `local.settings.json` patterns as belt-and-suspenders.
- `index.html` is served **verbatim** (byte-identical to source).

### Commission excluded (by design)

The dashboard emits **no commission, waterfall, or settlement data**. The exporter never reads
`luxauto_premium_waterfall_view`, `luxauto_quote_commission_view`, or `luxauto_settlement_view`.
Rationale: the platform's `quotes.mga_commission_rate` is a generated column baked to the ADR
0039 convention (30% total / net-0.70-to-panel), which does not reconcile with Kent's workbook
(25% / 0.75). Keeping commission off the board means there is nothing unreconciled to explain
in front of investors. A grep of the emitted JSON for
`commission|net_premium|waterfall|gross_share|mga_|broker_commission` must return empty.

### Honesty markers

- The **enrichment stage is visibly (but minimally) marked "simulated."** VIN decode, title
  history, household driver, and sanctions/OFAC (referral rules VV-01, VV-02, DH-02, PC-04,
  PC-02) are not yet built — no external data integrations exist. The dashboard shows those
  stages as motion but does not imply the lookups are real.
- Every state in the snapshot carries a **`synthetic: true`** flag derived from real markers
  (`DEMO-SYNTHETIC-<ST>-01`, or `TBD-ILLUSTRATIVE` for CT). No state holds real filed data;
  CT remains the ADR 0034 illustrative seed. There is no DC row (50 states only).
- Snapshot `meta` carries `synthetic: true`, `enrichment_simulated: true`,
  `source_db: luxauto_demo`.

## Deployment facts (operational record)

| Item | Value |
| --- | --- |
| Static Web App (Standard) | `luxauto-dashboard-swa` |
| Linked Function App (Flex Consumption, Node 20) | `luxauto-dashboard-api` |
| Function App backing storage | `luxautoapi97276` |
| Site URL | `https://orange-bush-0d66eac0f.7.azurestaticapps.net` |
| Function App managed-identity object id | `b0fce7f1-8419-477c-a157-e1fff0cd4682` |
| — needs role | Storage Blob Data Reader, scoped to `luxautosa91a2e1` only |
| Snapshot storage account / container / key | `luxautosa91a2e1` / `demo-dashboard` / `snapshot.json` |
| Allow-list group (created; gating confirmed) | `luxauto-dashboard-access` |
| Entra app registration — client (application) ID | `fc420fe2-1e12-4811-923c-6948aceb311f` |
| Entra app registration — object ID | `ab8d9826-a897-441a-9f27-85a37bd7c66d` |
| Resource group / region | `luxauto-rg` / `eastus2` |
| Repo commits | `42c6273` (exporter), `1b0be7f` (SWA app) on `demo/investor-preview` |
| Exporter files | `scripts/lib/`, `scripts/`, `infra/systemd/`, `sample-data/` |
| App tree | `dashboard-swa/` (repo root) |
| Control panel SWA (Standard) | `luxauto-control-swa` |
| Control API Function App | `luxauto-control-api` |
| Control API managed-identity object id | `99b85fd3-9f3d-4a3f-9567-192127187f31` (Storage Blob Data Contributor on the demo-control container) |
| Control allow-list group | `luxauto-control-access` (separate from dashboard group) |
| Dashboard custom domain | `https://dashboard.ironcliffvertex.com` |
| Control panel custom domain | `https://control.ironcliffvertex.com` |
| Dashboard azurestaticapps URL | `https://orange-bush-0d66eac0f.7.azurestaticapps.net` |
| Control azurestaticapps URL | `https://blue-tree-0dc34b50f.7.azurestaticapps.net` |

**Client secret is deliberately NOT recorded here or anywhere in the repo.**

## Status / what remains

- Operator portal configuration is COMPLETE (2026-08-26): app registration created,
  "assignment required" enabled, `luxauto-dashboard-access` group created and assigned to the
  app, client secret generated and stored in SWA settings only, blob-reader role granted to
  the Function App identity. Full checklist: `dashboard-swa/deploy/OPERATOR-CHECKLIST.md`.
- Control panel portal configuration is ALSO COMPLETE: the `luxauto-control-access` group
  (separate from the dashboard group) is created and its gating confirmed; the control app
  registration exists with "assignment required" enabled and its client secret stored in SWA
  settings only; **Storage Blob Data Contributor on the `demo-control` container** is granted to
  BOTH the control Function App identity AND the `luxauto-odoo` VM identity. Full checklist:
  `control-swa/deploy/OPERATOR-CHECKLIST.md`.
- Access gating VERIFIED (deny side): a valid `broedel.net` tenant user NOT in the group is
  denied at login — confirms tenant membership alone does not grant access. Grant side (a
  guest added to the group reaching the dashboard) being verified with the first external
  guest.
- The blob-reader role is granted; `/api/snapshot` serves snapshot data, and the dashboard
  frontend polls it live (repoint complete — see follow-ups below, now DONE).
- The **temporary Contributor grant** on the `luxauto-odoo` managed identity (added for
  provisioning both the dashboard and control SWAs) is **STILL PRESENT as of this update** and
  should be removed now that all deploys are complete — **pending final removal**.
- **All three systemd services are INSTALLED and RUNNING on `luxauto-odoo`:**
  `luxauto-dashboard-exporter` (writes `snapshot.json` to Blob, read-only),
  `luxauto-synthetic-generator` (drives synthetic apps through the real `luxauto_demo` pipeline;
  starts paused, steerable via the control panel), and `luxauto-demo-control-agent` (bridges the
  Entra-gated control API to the VM control file; runs the fenced reprovision on request).
  The generator resting state is **PAUSED** (no new apps until started from the control panel).
- **Both sites are live on custom domains** (`dashboard.ironcliffvertex.com`,
  `control.ironcliffvertex.com`) via Cloudflare CNAMEs (DNS-only) with Azure-managed TLS; the
  azurestaticapps URLs remain valid. Redirect URIs for both hostnames are registered on each app
  registration.

## Prior follow-ups — now completed

These were the open follow-ups at first acceptance; all are now DONE (kept here to preserve the
planned → done history):

- **Generator** — DONE. An autonomous process feeds synthetic applications through the *real*
  `luxauto_demo` pipeline (submit → referral eval → disposition → quote) on a cadence, with a
  guarded reset-to-curated-book control. It is **built, installed, and running** on
  `luxauto-odoo` (resting **paused**), and is now **steerable live** from the operator control
  panel (rate + five presets + pause/reset). Committed on `demo/investor-preview`.
- **Dashboard repoint** — DONE. The frontend's placeholder in-browser data generator was
  replaced by polling `/api/snapshot`; the board shows real pipeline motion and is **live** on
  `dashboard.ironcliffvertex.com`.
- **Exporter activation** — DONE. The `luxauto-dashboard-exporter` systemd unit is installed and
  running, writing `snapshot.json` on a cadence.

## Known follow-ups (polish pass)

Recorded, not yet implemented:

- **Richer `recent_activity` feed** — join applicant name + vehicle + state into each activity
  entry (data already available in the views); the feed is currently disposition-centric.
- **Dashboard deploy script clobbers auth settings** — the dashboard `deploy.sh` resets the
  populated `ENTRA_CLIENT_ID` / `ENTRA_CLIENT_SECRET` app-settings back to placeholders on
  redeploy; must be fixed so redeploys don't break login.
- **Node 20 runtime EOL** on both Function Apps (Azure nudging to a newer runtime) — maintenance.
- **App Insights skipped on the control API deploy** — optional telemetry.

## Addendum (2026-08-30) — exporter reads FROZEN sources (ADR 0046 STEP TWO)

With the frozen $71M canonical book loaded into `luxauto_demo` (ADR 0046), three exporter reads
were repointed from re-derived views to the frozen facts, so the board shows frozen values, never
re-derived ones. `scripts/lib/export_dashboard_snapshot.py`:

- **`avg_premium`** now reads `AVG(premium_amount)` off `luxauto_policy_view` (the SOFTENED written
  premium, **$9,314.33**), NOT `luxauto_quote_rating_view.indicative_premium` (the un-softened
  re-rate, $10,726.55, that the hybrid load exists to avoid). Any premium total likewise comes from
  `premium_amount`.
- **`disposition_mix`** now reads `bind`/`refer`/`decline` from `canonical_load_disposition`
  (**7,655 / 789 / 2,056 = 72.90 / 7.51 / 19.58 %**), NOT the engine's `most_severe_action` (which
  collapses refer+decline into MANUAL_REVIEW and emits zero declines — ADR 0046 STEP 0). The
  frontend "Disposition Mix" donut was reworked from the 7-engine-action → 4-bucket grouping to
  three frozen slices (Bound / Referred to underwriting / Declined).
- **`bind_ratio`** now = `count(bind) / count(*)` from `canonical_load_disposition` (**0.7290**),
  NOT `bound / quotes_issued` (~1.0 under the bound-only load). Sourced from the SAME frozen query
  as `disposition_mix` so the two can never disagree.

Untouched: `recent_activity` and `pipeline_events` still read `most_severe_action` (engine
disposition) — reason codes, the activity feed and the pipeline animation remain engine-driven.
The snapshot schema stayed back-compatible (same top-level keys; `disposition_mix`'s internal shape
changed 7-key → 3-key, consumed only by the donut). `quotes_issued == bound == 7,655` is the
accepted bound-only shape and was left as-is. The frontend also relabels were already present
(Submissions / Underwriting[simulated] / Refer to Underwriting); the synthetic + simulated markers
remain visible per the third-party-surface rule.

## Addendum (2026-08-30) — risk-colored state footprint (ADR 0046 STEP THREE)

The "National Footprint" tile now colors each state by **BOUND-POLICY COUNT** (off the frozen bound
book `luxauto_policy_view`), replacing the prior application-count / 3-live-ratio-bin shading. The
exporter adds a DISTINCT key `by_state_bound` (`{state, bound_policy_count}`, 50 states, Σ = 7,655);
`by_state` (application counts) is unchanged, and `snapshot.js` needed no change (verbatim
passthrough). Counts only — no premium read.

**FIXED, FROZEN bin edges** (5 bins), derived ONCE from this book's per-state bound distribution and
**hard-coded in the frontend `riskBin()` — never recomputed live** (the frozen-facts rule, ADR 0043/0046):

| Bin | Label | Bound-count edge | States on this book |
|---|---|---|---|
| 1 | Lowest | ≤104 | 9 |
| 2 | Low | 105–115 | 9 |
| 3 | Medium | 116–136 | 20 |
| 4 | Elevated | 137–249 | 8 (actual 212–239) |
| 5 | Highest | ≥250 | 4 (FL 334 / NY 365 / TX 384 / CA 447) |

Edges sit on the **natural breaks of the bimodal distribution** (the generator's populous-boost): the
empty 137–211 gap is the Medium/Elevated boundary so nothing straddles it, and the big-4 isolate as
Highest. Populations 9/9/20/8/4 are unequal **by design** — fixed thresholds on bimodal data, not
equal-population quantiles. A 5-swatch legend (Lowest→Highest with ranges) and per-state tooltips
("STATE · N bound policies") were added; the synthetic marker stays on the caption + footnote.
