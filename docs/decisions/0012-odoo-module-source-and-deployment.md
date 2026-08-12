# ADR 0012: Odoo module source lives in the repo; deployment is still manual

**Status:** Decided; deployment mechanism is a known gap
**Date:** 2026-08-12
**Follows from:** ADR 0006 (Odoo read/write pattern), ADR 0009 (Odoo installed on `luxauto-odoo`), ADR 0010 (the models this module implements), ADR 0011 (the same category of process gap, for schema application)

## Decision

First-party Odoo modules live in the repo, under a new top-level `odoo/addons/` directory (sibling to `schemas/` and `infra/`) - not only on the VM. `luxauto_policy` (ADR 0010's read-only Insured/Policy/Premium Waterfall models) is the first one, at `odoo/addons/luxauto_policy`.

On `luxauto-odoo`, `/opt/odoo-custom-addons/luxauto` is conceptually a git clone (or checkout) of this repo, the same way `/opt/odoo-custom-addons/storage` and `/opt/odoo-custom-addons/server-env` are already git clones of the upstream OCA repos (ADR 0009). The difference is what's being cloned: those two are third-party code this project doesn't own; `luxauto_policy` is first-party code, and the repo - not the VM - is its source of truth. Moving it into version control means it gets code review, history, and a rollback path the same as everything else in this project, instead of being a one-off directory a previous session happened to create by hand.

Confirmed before writing this: the module as copied into `odoo/addons/luxauto_policy` matches the VM's already-installed, already-tested copy at `/opt/odoo-custom-addons/luxauto/luxauto_policy` byte-for-byte (`diff -rq` and a `sha256sum` comparison over every source file, both clean) - no changes to the code itself, only where it lives.

## Current deployment mechanism: manual, and a known gap

Getting a change from the repo onto `luxauto-odoo` today is: `git pull` on the VM, then restart the Odoo service. No CI/CD, no automated deploy step, no verification that the pull actually happened before someone assumes it did. This is the same category of gap ADR 0011 found for schema application - a manual, one-off step with nothing standing behind it to catch drift - and it's called out here for the same reason: better to say plainly "this is manual and that's a known limitation" than let it pass as more automated than it is.

Not solved here. A repeatable deploy script (pull, restart, verify the module still loads and the expected models are registered) is a reasonable next candidate, but building it isn't part of this decision.

**One consequence of that gap, worth stating plainly rather than glossing over:** the actual conversion of `/opt/odoo-custom-addons/luxauto` from the plain directory it is today into a real git clone happens *after* this commit is pushed, not before. A clone can't check out a commit that only exists locally, and repointing the VM's live `addons_path` at an empty or stale clone before the push would risk breaking the already-installed, already-verified module on a running service, for no benefit. So the immediate next step, once this is pushed, is exactly the manual mechanism described above: clone (first time) or pull (thereafter), restart. Until then, the VM's working copy stays as the plain directory it already was when it was tested in the previous task.

## `calculate_premium_waterfall`'s SECURITY DEFINER, and why it doesn't break ADR 0006's boundary

Worth a note here since it's the first time this project has granted elevated privilege on a *function* rather than a plain view grant, and it's directly relevant to whether Odoo's access to the pipeline stays inside the boundary ADR 0006 drew: "Odoo owns its own thin, integer-keyed models... the pipeline's UUID-keyed tables... are never written to directly by Odoo's default ORM save behavior," reading only through `_auto=False` views.

Discovered while installing this module: a plain Postgres view runs with its *owner's* table privileges for any role that only has `SELECT` on the view - which is how `luxauto_insured_view` and `luxauto_policy_view` work for the least-privilege `odoo` role (ADR 0009) with no direct grant on `applicants`, `applications`, `quotes`, or `policies`. But `luxauto_premium_waterfall_view` calls `calculate_premium_waterfall()`, and a *function* invoked from within a view does not inherit that owner-privilege substitution - it runs as whichever role actually queries it. So `odoo` needed either a direct grant on `quotes`/`program_participants`, or the function itself needed to run with elevated rights.

Direct table grants would have been the quieter fix, but it would have quietly widened `odoo`'s reach from "only through the view layer" to "the base tables too" - exactly the boundary ADR 0006 draws. `SECURITY DEFINER` on the function instead keeps that boundary intact: the function becomes a controlled read gateway, playing the same role a view already plays, without `odoo` ever getting a grant on the tables themselves. `search_path` is pinned (`SET search_path = public, pg_temp`) to close the standard SECURITY DEFINER search-path-injection gotcha. Tested live as the actual `odoo` role (not the Postgres admin) before and after this fix - it failed with `permission denied for table quotes` before, and returned correct data after.

## Consequences

- `odoo/addons/` is now a real directory in this repo with its own path conventions to keep - future Odoo modules (the bind/cancel server actions ADR 0010 deferred, for one) have an obvious home.
- The VM still has a plain, ungoverned copy of `luxauto_policy` until the post-push clone/pull step happens - a short-lived, known state, not a long-term arrangement.
- The `SECURITY DEFINER` pattern established here is the template for any future function that needs to be reachable from an Odoo view without widening `odoo`'s direct table grants - worth reusing rather than re-deriving next time this comes up.
- No CI/CD decision has been made. This ADR intentionally leaves that open rather than picking a tool under time pressure.
