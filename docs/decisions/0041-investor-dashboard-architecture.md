# ADR 0041 — Investor Dashboard: Snapshot-to-Blob + Entra-Gated Static Web App

**Status:** Accepted (deployed; access-gating pending operator portal steps)
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
| Allow-list group (to be created) | `luxauto-dashboard-access` |
| Resource group / region | `luxauto-rg` / `eastus2` |
| Repo commits | `42c6273` (exporter), `1b0be7f` (SWA app) on `demo/investor-preview` |
| Exporter files | `scripts/lib/`, `scripts/`, `infra/systemd/`, `sample-data/` |
| App tree | `dashboard-swa/` (repo root) |

**Client secret is deliberately NOT recorded here or anywhere in the repo.**

## Status / what remains

- Site is deployed and **correctly denies everyone** until operator portal steps complete
  (create app registration + secret, wire into SWA, flip assignment-required, create group +
  assign to app, grant blob-reader role to the Function App identity, invite guest + add
  members). Full checklist: `dashboard-swa/deploy/OPERATOR-CHECKLIST.md`.
- Until the blob-reader role is granted, `/api/snapshot` correctly returns 503, not data.
- The **temporary Contributor grant** on the `luxauto-odoo` managed identity (added for
  provisioning) must be **removed after verification**.
- The **systemd unit** (`infra/systemd/luxauto-dashboard-exporter.service`) is committed as a
  repo artifact **only** — not installed, no cron/timer. The exporter is not yet running on a
  cadence on the VM. Activation is a deliberate later step.

## Not yet built (follow-ups)

- **Generator** — an autonomous process feeding synthetic applications through the *real*
  `luxauto_demo` pipeline (submit → referral eval → disposition → quote) on a cadence, with a
  reset-to-curated-book control. This is what fills the currently near-empty board with live
  motion. Not built.
- **Dashboard repoint** — swap the frontend's placeholder in-browser data generator for
  polling `/api/snapshot`. Until then the served page shows mock motion (real 50-state map
  universe, mock counts).
- **Exporter activation** — install/enable the systemd unit so the exporter runs continuously.
