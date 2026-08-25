# Operator checklist — luxauto demo dashboard (portal steps)

The Static Web App and its API are **deployed and running**, but access is intentionally
**closed** until you complete the steps below. Nothing here needs the command line — every
step is in the Azure portal. Steps 1–7 make the dashboard work; step 8 is cleanup.

## Values you'll need

| What | Value | Who produced it |
|---|---|---|
| Site URL | `https://orange-bush-0d66eac0f.7.azurestaticapps.net` | generated (deployed) |
| Static Web App name | `luxauto-dashboard-swa` (RG `luxauto-rg`) | generated |
| Function App name | `luxauto-dashboard-api` (RG `luxauto-rg`) | generated |
| **Function App identity — object ID** | **`b0fce7f1-8419-477c-a157-e1fff0cd4682`** | generated — used in **Step 6** |
| Blob storage account (grant scope) | `luxautosa91a2e1` (RG `luxauto-rg`) | existing |
| Tenant ID | `2c7981fb-d0ee-46b6-a5c2-87aaa0a84d0b` | existing |
| Subscription ID | `ff1d4234-2dc1-476c-b350-ddabbc59c566` | existing |
| Entra **redirect URI** to register | `https://orange-bush-0d66eac0f.7.azurestaticapps.net/.auth/login/entra/callback` | generated |
| App registration **Client ID** | _(blank — you create it in Step 1)_ | **you supply** |
| App **Client secret** | _(blank — you create it in Step 2)_ | **you supply** |
| Security group **Object ID** | _(blank — you create it in Step 4)_ | **you supply** |

---

## Step 1 — Create the Entra app registration

1. Portal → **Microsoft Entra ID** → **App registrations** → **New registration**.
2. Name: `luxauto-dashboard`. Supported account types: **Accounts in this organizational
   directory only (single tenant)**.
3. Under **Redirect URI**, choose platform **Web** and paste:
   `https://orange-bush-0d66eac0f.7.azurestaticapps.net/.auth/login/entra/callback`
4. **Register**. On the Overview page, copy the **Application (client) ID** — you need it in Step 3.

## Step 2 — Create a client secret

1. In the app registration → **Certificates & secrets** → **New client secret** → add a
   description, pick an expiry, **Add**.
2. Copy the secret **Value** immediately (it's shown only once). You need it in Step 3.

## Step 3 — Put the client ID and secret into the Static Web App

1. Portal → **Static Web Apps** → `luxauto-dashboard-swa` → **Settings → Environment variables**
   (a.k.a. Application settings), **Production**.
2. Replace the two placeholder values:
   - `ENTRA_CLIENT_ID` → the **Application (client) ID** from Step 1.
   - `ENTRA_CLIENT_SECRET` → the **client secret Value** from Step 2.
3. **Save**. (These are read server-side only; they never reach the browser.)

## Step 4 — Turn on "assignment required" and define the app role

This is the core of the allow-list: with assignment required **on**, only assigned
users/groups can get a token — tenant membership alone does **not** grant access.

1. Portal → **Entra ID** → **Enterprise applications** → open `luxauto-dashboard`
   (the enterprise app that was auto-created alongside the registration).
2. **Properties** → set **Assignment required?** = **Yes** → **Save**.
3. (Recommended) Define an app role so you can assign a whole group:
   Back in **App registrations** → `luxauto-dashboard` → **App roles** → **Create app role**:
   - Display name: `Dashboard User`
   - Allowed member types: **Users/Groups**
   - Value: `dashboard.user`
   - Description: `Can view the luxauto demo dashboard`
   - **Apply**.

## Step 5 — Create the allow-list security group and assign it to the app

1. Portal → **Entra ID** → **Groups** → **New group**:
   - Type: **Security**, Name: `luxauto-dashboard-access`. **Create**.
   - Open it and copy the group's **Object ID** (for your records).
2. Portal → **Entra ID** → **Enterprise applications** → `luxauto-dashboard` →
   **Users and groups** → **Add user/group**:
   - **Users and groups**: pick `luxauto-dashboard-access`.
   - **Select a role**: pick **Dashboard User** (the app role from Step 4).
   - **Assign**.

> From now on, **who can see the dashboard = who is in `luxauto-dashboard-access`.**

## Step 6 — Grant the API read access to the snapshot blob  ⭐ required for data

Without this, sign-in works but the dashboard's data call returns a 503. The API reads the
blob using its **managed identity** — no key, no SAS.

1. Portal → **Storage accounts** → `luxautosa91a2e1` → **Access Control (IAM)** →
   **Add → Add role assignment**.
2. **Role**: `Storage Blob Data Reader`.
3. **Members**: **Managed identity** → **Select members** → **Function App** →
   choose `luxauto-dashboard-api`
   (verify its object ID is **`b0fce7f1-8419-477c-a157-e1fff0cd4682`**).
4. **Review + assign**. Scope stays **this storage account only** — do not grant at
   resource-group or subscription level.

## Step 7 — Invite the external collaborator (Gmail) and add members

1. Portal → **Entra ID** → **Users** → **New user → Invite external user**:
   - Email: the collaborator's Gmail address. **Invite**. They'll get an email — they must
     **accept** before they can be added to the group.
2. After they accept: **Entra ID → Groups → `luxauto-dashboard-access` → Members → Add
   members** → add the guest.
3. Add **yourself** to the same group the same way.

## How to test

- **Allowed user:** open `https://orange-bush-0d66eac0f.7.azurestaticapps.net` in a private
  window, sign in as a group member → you should land on the dashboard, and the data loads.
- **Not-allowed tenant user:** sign in as someone in your tenant who is **not** in the group
  → they should be **denied** (they can't get a token because assignment is required; if they
  reach the app they see the 403 "no access" page). Tenant membership alone must not work.

## Adding / removing people later

Just edit membership of **`luxauto-dashboard-access`** (Entra ID → Groups → Members).
No redeploy, no config change. Removal takes effect on their next sign-in / token refresh.

## Step 8 — Cleanup (after you've verified the site works)

- Remove the **temporary Contributor** grant that let the build agent provision this:
  Portal → **Resource groups** → `luxauto-rg` → **Access control (IAM)** →
  **Role assignments** → find **Contributor** assigned to the managed identity
  **`luxauto-odoo`** (object ID `e67de137-c107-41fd-8226-1b3c0276504b`) → **Remove**.
  The running site does **not** depend on this grant.

---

### What's already done (no action needed)
- Static Web App **Standard** created and serving `index.html` **verbatim** (unmodified).
- Linked **Function App** API (`/api/snapshot`) reads the blob **server-side**; the blob URL
  and any credential never reach the browser.
- Route protection: the site and `/api/*` require an **authenticated** user; anonymous
  requests are redirected to Entra login; the linked backend rejects direct/forged calls.
- The blob container remains **private** (no public access, no SAS).
