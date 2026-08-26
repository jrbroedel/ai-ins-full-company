# Operator checklist — luxauto demo **operator control panel** (portal steps)

This is the **write-capable, partly-destructive** operator surface. It is a **separate**
Static Web App + Function App from the investor dashboard, gated by its **own** allow-list
group **`luxauto-control-access`** — so "who can *drive* the demo" is independent from "who can
*watch* it" (`luxauto-dashboard-access`). Someone in the dashboard group does **not** get the
control panel unless you also add them here.

After `deploy/deploy.sh` runs, the panel is **deployed but closed** until you finish the steps
below. Every step is in the Azure portal (plus two role grants). None of this touches the
dashboard, its API, its exporter, or its auth.

## Values you'll need

| What | Value | Who produced it |
|---|---|---|
| Site URL | `https://<generated>.azurestaticapps.net` | deploy output |
| Static Web App name | `luxauto-control-swa` (RG `luxauto-rg`) | deploy |
| Control Function App | `luxauto-control-api` (RG `luxauto-rg`) | deploy |
| **Function App identity — object ID** | **(printed by deploy)** | deploy — used in **Step B** |
| VM identity (control agent) | `luxauto-odoo` — obj ID `e67de137-c107-41fd-8226-1b3c0276504b` | existing — used in **Step B** |
| Storage account | `luxautosa91a2e1` (RG `luxauto-rg`) | existing (shared) |
| Control container | `demo-control` (private) | deploy (or Step A) |
| Tenant ID | `2c7981fb-d0ee-46b6-a5c2-87aaa0a84d0b` | existing |
| Subscription ID | `ff1d4234-2dc1-476c-b350-ddabbc59c566` | existing |
| Entra **redirect URI** | `https://<generated>.azurestaticapps.net/.auth/login/entra/callback` | deploy |
| App registration **Client ID** | _(blank — Step 1)_ | **you supply** |
| App **Client secret** | _(blank — Step 2)_ | **you supply** |
| Allow-list group **Object ID** | _(blank — Step 4)_ | **you supply** |

---

## Step A — Create the private control container (only if deploy said it couldn't)

`deploy.sh` tries to create the `demo-control` container. If it printed *"could not create with
current data-plane rights"*, create it by hand:

1. Portal → **Storage accounts** → `luxautosa91a2e1` → **Containers** → **+ Container**.
2. Name `demo-control`, **Public access level: Private**. **Create**.

## Step B — Grant blob data access to BOTH identities (scoped to the container) ⭐ required

The control API (cloud) and the control agent (VM) both use **managed identity** — no key, no SAS.
Grant **`Storage Blob Data Contributor`**, scoped to the **`demo-control` container only**
(not the account, not the RG):

1. Portal → **Storage accounts** → `luxautosa91a2e1` → **Containers** → `demo-control` →
   **Access Control (IAM)** → **Add → Add role assignment**.
2. Role **`Storage Blob Data Contributor`**. Add **two** members:
   - **Managed identity → Function App → `luxauto-control-api`** (verify the object ID printed by deploy).
   - **Managed identity → `luxauto-odoo`** (the VM; obj ID `e67de137-…`) — this is the control agent.
3. **Review + assign.**

> Without this: the API's writes and the agent's reads/writes 502/timeout. The dashboard's
> `demo-dashboard` container and its reader grant are untouched.

## Step 1 — Create the Entra app registration (separate from the dashboard's)

1. Portal → **Microsoft Entra ID** → **App registrations** → **New registration**.
2. Name `luxauto-control`. Account types: **single tenant**.
3. **Redirect URI**, platform **Web**:
   `https://<generated>.azurestaticapps.net/.auth/login/entra/callback`
4. **Register**, copy the **Application (client) ID** (Step 3).

## Step 2 — Create a client secret

1. App registration → **Certificates & secrets** → **New client secret** → add, pick expiry, **Add**.
2. Copy the secret **Value** immediately (shown once). Needed in Step 3.

## Step 3 — Put the client ID + secret into the Static Web App

1. Portal → **Static Web Apps** → `luxauto-control-swa` → **Settings → Environment variables**, **Production**.
2. Replace the placeholders:
   - `ENTRA_CLIENT_ID` → Application (client) ID from Step 1.
   - `ENTRA_CLIENT_SECRET` → secret Value from Step 2.
3. **Save.** (Read server-side only; never reach the browser. The secret lives here, not in the repo.)

## Step 4 — Turn on "assignment required" and define the app role

1. Portal → **Entra ID** → **Enterprise applications** → open `luxauto-control`.
2. **Properties** → **Assignment required?** = **Yes** → **Save**.
   (This is the allow-list core: tenant membership alone must NOT grant access.)
3. **App registrations** → `luxauto-control` → **App roles** → **Create app role**:
   - Display name `Control Operator`; member types **Users/Groups**; value `control.operator`;
     description `Can drive the luxauto demo generator`. **Apply.**

## Step 5 — Create the allow-list group `luxauto-control-access` and assign it

1. Portal → **Entra ID** → **Groups** → **New group**: Security, name **`luxauto-control-access`**. **Create.**
   (Do **not** reuse `luxauto-dashboard-access` — the whole point is a separate, smaller driver list.)
2. **Enterprise applications** → `luxauto-control` → **Users and groups** → **Add user/group**:
   - Group: `luxauto-control-access`; Role: **Control Operator**. **Assign.**

> From now on, **who can drive the demo = who is in `luxauto-control-access`.**

## Step 6 — Add members (operator + Kent)

1. **Entra ID → Groups → `luxauto-control-access` → Members → Add members**:
   - Add **yourself** (the operator).
   - Add **Kent** (if a guest, invite via **Users → New user → Invite external user** first; they must
     **accept** before they can be added).
2. Keep this list short — it can trigger a destructive rebuild.

## How to test

- **Allowed:** open the site in a private window, sign in as a `luxauto-control-access` member →
  the panel loads; Status shows the generator state and demo row count.
- **Not allowed (dashboard-only user):** sign in as someone in `luxauto-dashboard-access` but **not**
  in `luxauto-control-access` → **denied** (403 page). Watching does not grant driving.
- **Anonymous:** hitting `/api/control/status` or any `/api/control/*` without a session →
  **401 / redirected to login**. No control endpoint is anonymous.

## Bringing the VM side up (generator + control agent)

The panel writes *intent*; the **VM** executes it. Two systemd services run on `luxauto-odoo`.
They are **staged, not installed** — install when ready (each needs `sudo`):

```bash
sudo cp infra/systemd/luxauto-synthetic-generator.service /etc/systemd/system/
sudo cp infra/systemd/luxauto-demo-control-agent.service   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now luxauto-synthetic-generator.service
sudo systemctl enable --now luxauto-demo-control-agent.service
```

The generator boots **paused** (the control file ships `state: "paused"`), so nothing generates
until you click **Start** in the panel. The agent reflects your clicks into the control file and
publishes status back. Reset runs the **existing fenced reprovision** on the VM — never in the cloud.

## Adding / removing drivers later

Edit membership of **`luxauto-control-access`** (Entra ID → Groups → Members). No redeploy.
Removal takes effect on their next sign-in / token refresh.

---

### What's already done (no action needed)
- Separate **Static Web App (Standard)** serving the operator panel; separate **Function App** API.
- API re-validates the `x-ms-client-principal` and required role **server-side** on every endpoint
  (defense in depth); the linked backend rejects direct/forged calls.
- The API holds **no database credential** and opens **no DB connection** — it only touches the
  three control blobs. Destruction is executed on the **VM** via the sanctioned reprovision path.
- The reset endpoint re-asserts the **luxauto_demo** pin and **refuses the production name**
  server-side before writing; the VM agent re-verifies again before the DROP.
- **The dashboard, its exporter, its API, and its auth are unchanged.**
