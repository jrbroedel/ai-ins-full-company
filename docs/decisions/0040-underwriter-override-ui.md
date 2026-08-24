# ADR 0040: Odoo UI for the underwriter override mechanism

**Status:** Decided; implemented
**Date:** 2026-08-22
**Follows from:** ADR 0032 (`underwriters`, `authorize_referral_override`, `referral_overrides`, the authority/active enforcement this UI drives), ADR 0038 (`update_underwriter`, wired into the roster UI), ADR 0029 (the `_auto=False` read-view pattern and the `luxauto_application_referral_view` this builds on), ADR 0010 (the wizard-over-`SECURITY DEFINER`-function write pattern the override/roster wizards follow)

## Scope

The override mechanism was fully built and tested at the DB layer but had **no Odoo surface** — a human underwriter could only use it via direct DB access. This ADR adds the UI: a review queue, an override wizard, and roster management. **No new write functions** (`authorize_referral_override`/`add_underwriter`/`update_underwriter` already exist, granted to `odoo`); the only new database surface is **two read-side views**, exactly the ADR 0029 pattern.

## What was built

**Two read views** (`schemas/db/postgresql_schema.sql`), each with a synthesized integer `id` (Odoo requires one over the UUID-keyed tables), `GRANT SELECT … TO odoo`:
- `luxauto_underwriter_view` — the roster (`underwriter_id`, `name`, `authority_level`, `is_active`, `created_at`).
- `luxauto_underwriter_review_view` — one row per application whose **current** disposition is overridable (`MANUAL_REVIEW_REQUIRED`/`MANUAL_REVIEW_SENIOR`/`DECLINE_RECOMMENDED` — the `referral_overrides` whitelist), with `override_status` (`pending`/`released`), authorizer, and reason. Built **on top of** `luxauto_application_referral_view` and left-joined to `referral_overrides` on the same `(application_id, overridden_action, evaluated_at)` triple `create_quote()`'s gate uses — so a re-evaluation that moves `evaluated_at` flips a row back to `pending`, exactly as the gate would re-block it.

**Odoo module `odoo/addons/luxauto_policy`** (confirmed path: the repo is cloned to `/opt/odoo-custom-addons/luxauto`, addons under `odoo/addons/`, module technical name `luxauto_policy`):
- **(a) Review queue** — `luxauto.underwriter.review` read model, list (pending rows decorated, an "Authorize Override" button) + form + a search view defaulting to **pending**. This is the actionable screen and the "see it reflected" demo transition (pending → released on one screen).
- **(b) Override wizard** — `luxauto.override.wizard` (transient), launched from a review row's button which **pre-fills `application_id` + `overridden_action`** (the function rejects a disposition mismatch, so pre-filling is both correct and friendly); the authorizing underwriter is picked from the roster (`Many2one`, active-only), a rationale is required, and `action_authorize` calls `authorize_referral_override(...)` catching `psycopg2.Error → UserError` so `OVERRIDE_SENIOR_AUTHORITY_REQUIRED`/`OVERRIDE_AUTHORIZER_INACTIVE`/`OVERRIDE_DISPOSITION_MISMATCH` surface as clean messages, not tracebacks.
- **(c) Roster management** — `luxauto.underwriter` read model (list + form) plus an **Add** wizard (`add_underwriter`) and an **Update** wizard (`update_underwriter`: promote/demote via authority, (de)activate via a tri-state, rename), both calling the DB functions the same wizard way.

## Identity: no Odoo-login → underwriter link (pick from roster)

`underwriters` has **no `res_users`/login column** — there is no mapping from an Odoo login to an `underwriter_id`. So the override wizard has the user **pick the authorizing underwriter from the roster** (active-only `Many2one`), the case the investigation anticipated. A `res_users ↔ underwriter` link is a clean future refinement, out of scope here.

## Access control: `base.group_user` is a demo-speed decision, not the final posture

All new models (read views + wizards) are open to **`base.group_user`** for this pass. This is a **deliberate demo-speed tradeoff, explicitly not the final access-control posture** — a dedicated **`group_underwriting`** security group restricting who can authorize overrides (and gating the review/roster screens) is a **tracked follow-up, out of scope for this ADR**. It is defensible for tonight because the **database is the real enforcement boundary**: the `enforce_referral_override_authority` trigger refuses a standard underwriter overriding a `MANUAL_REVIEW_SENIOR`, and an inactive authorizer, regardless of any Odoo group. The Odoo group would be UI gating on top of that, not the control itself.

## The `is_active` gotcha (headed off)

The roster view exposes `underwriters.active` **as `is_active`**, and the Odoo field is `is_active`, deliberately not `active`: an Odoo field literally named `active` triggers archive magic (inactive rows hidden by default), which would hide deactivated underwriters from the very screen meant to see and reactivate them. Renaming avoids that entirely — a real demo footgun caught before it shipped.

## Confirming this is UI + two views, no core write surface

`verify_schema.py`: **views 13 → 15** (the two read views); **functions/tables/types/triggers unchanged** (no new write function — the three exist). `scripts/lib/smoke_test.py`: `MODELS` **13 → 15** (the two new read models added), so deploy actually validates they are queryable by name.

## Testing & the Odoo-side sanity check

- `tests/0040_underwriter_review_views.sql` (3 cases): a flagged application shows **pending**, flips to **released** with the authorizer and reason after `authorize_referral_override()`, a clean (`AUTO_PROCEED`) application never enters the queue, and the roster view exposes a stable integer id and reflects `add_underwriter`/`update_underwriter`. The write/authority behavior itself is already covered by `tests/0032`/`tests/0038`.
- **Odoo-load validation:** beyond the SQL, the module was static-checked locally (Python compiles; all view XML well-formed; access CSV shape valid; view field/action refs cross-checked against the models; syntax matches the module's existing Odoo 19 conventions — `<list>`, `invisible="…"` expressions, `type="object"` buttons, the `action_open_*_wizard` context-passing pattern). The authoritative check is the **`deploy-vm` module upgrade + smoke test**, which upgrades `luxauto_policy` against the live Odoo and `search_read`s every model including the two new ones — a view XML validation error (a bad field ref, a bad `attrs`) fails that step, not any SQL test, so it is verified there explicitly.

## Consequences

- The override mechanism is now usable end to end in Odoo: see a flagged application, authorize an override as a named underwriter, see it flip to released; manage the roster (add + full update).
- Two read views added; no new write surface. The DB remains the system of record and the real enforcement boundary; every Odoo write goes through a `SECURITY DEFINER` function via a wizard, never to a base table.
- **Two tracked follow-ups, deliberately deferred:** a `group_underwriting` security group (real access control vs. tonight's `base.group_user`), and a `res_users ↔ underwriter` identity link (so the authorizer need not be picked from a list).

## Addendum (2026-08-24): lock the underwriter UI to `group_underwriting`

**Status:** Decided; implemented. Targets `main`.

Closes the first of the two follow-ups above — the access-control gap this ADR
itself flagged as "a deliberate demo-speed tradeoff, explicitly not the final
access-control posture."

**What changed:**
- New `res.groups` record `group_underwriting` in
  `odoo/addons/luxauto_policy/security/luxauto_security.xml`, mirroring
  `group_settlement_viewer` (ADR 0013): excluded from `base.group_user`, no
  default members, an explicit comment stating membership is a business decision
  made elsewhere.
- The five underwriter-UI rows in `security/ir.model.access.csv`
  (`luxauto.underwriter`, `luxauto.underwriter.review`, `luxauto.override.wizard`,
  `luxauto.underwriter.add.wizard`, `luxauto.underwriter.update.wizard`) moved
  from `base.group_user` to `luxauto_policy.group_underwriting`. **This is the
  real enforcement boundary** — a non-member cannot read or act on these models
  regardless of the menu.
- The four underwriter menu items in `views/luxauto_menus.xml` gained
  `groups="luxauto_policy.group_underwriting"`. This is UX polish (hiding the
  items for non-members) layered on top of the CSV access rights — belt and
  suspenders, not a substitute — the same pattern the settlement menu uses.
- The stale "all open to base.group_user for now" comment in `luxauto_menus.xml`
  was replaced to say the group now gates these screens.
- `scripts/lib/smoke_test.py`: the disposable smoke-test user now also joins
  `group_underwriting` (it already joined `group_settlement_viewer` for the same
  reason). Without this the post-deploy `search_read` probe of
  `luxauto.underwriter`/`luxauto.underwriter.review` would fail an access check
  and break the deploy — exactly mirroring how the settlement group is handled.

**Why:** the DB triggers (`enforce_referral_override_authority`, the active-
authorizer check) were always the true control, but any logged-in user could see
and drive the override/roster screens. Gating the Odoo surface to a dedicated
group brings the UI posture in line with the sensitivity of the action.

**Still open — NOT fixed here (`res_users` ↔ `underwriter` link):** `underwriters`
still has no `res_users`/login column (see "Identity" above). So
`group_underwriting` **membership is assigned manually**, per user, and is **not
derived from the roster** — being an `underwriter` row does not make you a group
member, and vice versa. Wiring group membership to the roster is deliberately out
of scope for this addendum and remains the second tracked follow-up.
