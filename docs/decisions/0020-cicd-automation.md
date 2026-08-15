# ADR 0020: CI/CD automation - self-hosted runner and push-triggered workflows

**Status:** Decided and implemented
**Date:** 2026-08-14
**Follows from:** ADR 0015 (built both scripts and explicitly declined to decide what triggers them), ADR 0012 (declined to pick a CI/CD tool under time pressure), ADR 0009 (established the managed-identity credential pattern this inherits and, as section 4 records, now exposes more widely)

## What this ADR decides

ADR 0015 section 3 closed with a deliberate non-decision: "what triggers either script - manual invocation, a cron job, or real CI/CD" was left open, consistent with ADR 0012's own refusal to pick a CI/CD tool under time pressure. Both scripts were made trustworthy to run; neither was given a trigger. This ADR supplies the trigger and nothing else - it does not revisit what the scripts do, which ADR 0015 settled.

Four things are decided here: where the automation executes and why it cannot be GitHub-hosted, what the two workflows are and why they are deliberately not chained, what privileges the runner needs on this host, and what new attack surface all of that introduces. Section 5 is not a decision but a record of the reboot test that shows the resulting path survives a restart of the host it runs on.

## 1. A self-hosted runner on `luxauto-odoo`, not a GitHub-hosted runner

**Decision: a self-hosted GitHub Actions runner (v2.336.0) installed on `luxauto-odoo`, registered to this repository, running as a dedicated non-root service user `ghrunner` (uid 999) under systemd as `actions.runner.jrbroedel-ai-ins-full-company.luxauto-odoo.service`.**

This is not a preference for self-hosting; both scripts are structurally host-bound and a GitHub-hosted runner cannot execute either one:

- `apply-and-verify-schema.sh` authenticates to Key Vault by calling the IMDS endpoint at `169.254.169.254` for a token belonging to *this VM's* managed identity - the pattern ADR 0009 established specifically so that no Postgres credential is ever stored in the repo or passed through an operator's shell history. That endpoint exists only on the Azure VM. A GitHub-hosted runner would have to be handed a long-lived secret instead, which is the exact practice ADR 0009 decided against.
- `deploy-vm.sh` drives the local Odoo systemd unit and the local addons clone at `/opt/odoo-custom-addons/luxauto`. There is nothing for it to do anywhere else.

So the choice was never "self-hosted or hosted" - it was "self-hosted or keep running these by hand." The security cost of that, which is real and is the point of section 4, is the price of not reintroducing the stored-secret pattern ADR 0009 rejected.

`ghrunner` is a dedicated, password-locked system account, deliberately not `azureuser` (which holds unrestricted `NOPASSWD: ALL` sudo via `/etc/sudoers.d/waagent`) and not root. Running the runner as either would have meant every workflow step implicitly held full root on the production host.

## 2. Two independent workflows, and the ordering hazard that creates

**Decision: two workflows, both `on: push` to `main`, with no dependency between them - `.github/workflows/schema-apply.yml` runs `scripts/apply-and-verify-schema.sh`, `.github/workflows/deploy-vm.yml` runs `scripts/deploy-vm.sh`.**

**This is an accepted tradeoff, recorded here rather than fixed.** Chaining deploy behind schema verification (`needs:`) is the more conservative design and was not chosen. The consequence, stated plainly: a commit that changes both the schema and the module code starts both workflows with no ordering guarantee, so `deploy-vm.sh` can reach its smoke test before `apply-and-verify-schema.sh` has confirmed the schema it depends on. The realistic failure is a commit adding a column plus the model field that reads it - the deploy upgrades modules against the old schema and fails its smoke test.

Two things sharpen this, both established by observation during implementation rather than assumed:

**The race is real but currently manifests as nondeterministic ordering, not true parallelism.** A single self-hosted runner executes one job at a time, so the two workflows queue and serialize rather than running concurrently. On the first real trigger (commit `8f5337c`) schema-apply ran 16:08:35-16:08:40 and deploy started at 16:08:40 - the correct order, by luck, not by construction. Nothing schedules them that way and the reverse order is equally available. **Registering a second runner would silently convert this from arbitrary serialization into genuine parallelism**, which is worth knowing before anyone adds one for throughput.

**The failure mode is loud, not silent.** ADR 0015 section 3 made `deploy-vm.sh` end in a real smoke test rather than a `systemctl is-active` check, precisely so a deploy that completes into a broken state exits non-zero. A deploy that races ahead of its schema fails visibly and does not report success. That is what makes deferring this defensible: the hazard produces a red workflow run, not a quietly wrong production state.

**Deferred, not solved.** The fix, when it is worth doing, is `needs:` plus a shared `concurrency` group, or folding both into one workflow with ordered jobs. Not done here.

**Per-workflow `concurrency` groups were added** (`group: schema-apply` and `group: deploy-vm`, `cancel-in-progress: false`). These are separate groups and do **not** couple the two workflows - each only serializes against itself, so two rapid pushes cannot run two deploys at once. This matters more on the deploy side, where `deploy-vm.sh` stops the Odoo service, upgrades modules and starts it again; two overlapping runs would fight over the service. This is self-protection, not the ordering fix above, and must not be mistaken for it.

Both jobs also set `permissions: contents: read`, scoping the automatic `GITHUB_TOKEN` to the read access they actually use, and pin `runs-on: [self-hosted, linux, luxauto-odoo]` so a future second runner cannot silently pick up these jobs.

## 3. The privileges the runner needs, and the one that could not be narrowed

Investigation before implementation found the thing that would have broken this outright: **`deploy-vm.sh` cannot run as a non-root user without an explicit sudoers grant.** It makes eight `sudo` calls (lines 34, 48, 77, 84, 97, 104, 106, 114). Only `azureuser` had passwordless sudo. A workflow job has no TTY, so a `sudo` password prompt does not wait for anyone - it fails the step immediately. Running the two scripts by hand as `azureuser`, which is how every deploy had been done until now, had concealed this dependency entirely.

**Decision: `/etc/sudoers.d/10-ghrunner-deploy` grants `ghrunner` exactly the six distinct commands `deploy-vm.sh` invokes, and nothing else.** Three exact `systemctl` verbs (`stop`, `start`, `is-active --quiet`) against the `odoo` unit only, as root; two fully-pinned `git` invocations against the addons clone, as `odoo`; and `/usr/bin/odoo *`, as `odoo`.

**That last rule is a wildcard, and this ADR records it as such rather than disguising it.** It cannot be pinned honestly: line 84's module list is computed at run time from whatever manifests exist in the clone, and line 114 pipes `smoke_test.py` into `odoo shell` on standard input - and `odoo shell` executes arbitrary Python by design, on a channel sudoers cannot inspect. A narrower-looking rule pinning the exact argument vector would grant identical power while appearing tighter, which is worse than stating the truth: **any grant sufficient to run this deploy is a grant of code execution as the `odoo` user, and therefore of full access to the application database.**

What the grant does still bound is root. `ghrunner` cannot start, stop, mask or edit any unit other than `odoo`, and cannot read `/etc/shadow` - both verified, not assumed.

~~**Deferred hardening item:** the wildcard can be removed by making `deploy-vm.sh` call a root-owned, fixed-path wrapper that hardcodes the config, database and smoke-test payload, with sudoers pinned to the wrapper. That is a change to an ADR 0015 artifact and is left for a deliberate task rather than smuggled in here.~~ **Done - see the addendum below.** The wrapper exists, the wildcard is gone, and the addendum is explicit about which half of the threat it closes and which half it structurally cannot.

## 4. What this exposes, stated plainly

A self-hosted runner means GitHub Actions holds code execution on the production host. Consistent with how ADR 0009 treated credential handling as a first-class decision, this is recorded as a decision with a cost, not as incidental setup.

**The blast radius is larger than "it can run a deploy."** Two things compound:

1. **The runner inherits the VM's managed identity.** Any job on this runner can query IMDS and obtain a Key Vault token - that is precisely how `apply-and-verify-schema.sh` authenticates. Arbitrary code on this runner therefore yields the Postgres admin credentials, not merely the ability to restart Odoo.
2. **The sudoers grant yields code execution as `odoo`** (section 3), and therefore full application-database access.

**This repository is public.** GitHub's own guidance is that self-hosted runners belong on private repositories, because a fork can otherwise propose a workflow that executes on the runner host. The current exposure is latent rather than active: both workflows trigger only on `push` to `main`, and `push` events do not fire for pull requests from forks. It becomes active the moment any workflow gains a `pull_request` trigger, or the fork-PR approval policy is loosened.

**Requirement, not a suggestion: the repository's Actions setting "Fork pull request workflows from outside collaborators" must remain at "Require approval for all outside collaborators."** It was set to that value as part of this change. Reverting it to the public-repository default re-opens the path from an anonymous fork PR to code execution on the production VM, with the two amplifiers above attached. Any future workflow carrying a `pull_request` trigger needs to be reviewed against this section before it is merged.

**The residual, honestly stated:** push access to `main` is now equivalent to code execution on the production VM and to read access to the production database credentials. That was already partly true - the credential store on this host could push changes to the very scripts CI executes - but it is now a direct, automated path rather than a theoretical one.

One related decision followed from this. The credential on this host lacks the `workflow` scope, so it cannot create or modify anything under `.github/workflows/`. **That was left unchanged deliberately**: the workflow definitions were committed from outside the VM instead. It is a partial control - the same credential can still modify the scripts those workflows call - but it means the CI executor cannot rewrite its own CI definitions, and it costs only a manual step on the rare occasions the workflows change.

## 5. Reboot survival, demonstrated rather than asserted

An automation path that silently stops existing after the next unplanned reboot is not automation, and `systemctl is-enabled` reporting `enabled` is a claim about configuration, not evidence about behaviour. The host was therefore rebooted deliberately and the runner's return observed.

**Result: the runner reconnected unaided.** The host booted at 16:26 UTC; systemd started the service at 16:26:12, the listener reported `√ Connected to GitHub` at 16:26:18 and `Listening for Jobs` at 16:26:19 - seven seconds from boot, with `NRestarts=0`. Those log lines are from the current boot (`journalctl -b`), not carried over from the previous one.

Nothing started it by hand, and the test design is what makes that verifiable rather than merely claimed: Claude Code runs on `luxauto-odoo` itself, so the reboot destroyed the session that ordered it. The service was already connected and listening before any interactive login existed to intervene.

This closes the one dependency that the two workflows have on host state outside the workflow files themselves. It does not extend to the VM being deallocated and restarted by Azure, which was not tested; the systemd unit is the same either way, but only the in-guest reboot has been observed.

## Consequences

- ADR 0015's open question about triggers is closed. Both scripts now run on every push to `main`, in addition to remaining runnable by hand exactly as before - this adds a trigger, it does not remove one.
- ADR 0012's deferral of "which CI/CD tool" is closed by circumstance rather than by comparison: the scripts' dependence on this host's managed identity and local Odoo service made a host-bound runner the only option that does not reintroduce stored secrets.
- Push access to `main` is now a production-access boundary. It should be treated as one when branch protection or collaborator access is next considered.
- A second runner would convert the section 2 ordering hazard from arbitrary serialization into real parallelism. Do not add one for throughput without first chaining the workflows.
- ~~The `/usr/bin/odoo *` sudoers wildcard remains outstanding as a named hardening item (section 3)~~ **closed by the addendum below**, which replaced it with two exact-match entries against a root-owned wrapper. The workflow chaining in section 2 remains outstanding, recorded as accepted-and-deferred, which is the same treatment ADR 0011 and ADR 0012 gave the gaps ADR 0015 eventually closed.
- The runner survives a host reboot without intervention (section 5), so no manual step is needed to restore CI after a restart or a patch cycle. An Azure-side deallocate/start was not tested.
- Odoo is restarted on every push to `main` that reaches the deploy workflow, including documentation-only commits - `deploy-vm.sh` upgrades all first-party modules unconditionally by ADR 0015's own design. Path filtering was considered and not added, on the grounds that a deploy that only ever runs on "relevant" paths is a second thing that has to be right about which files imply a change, which is the failure mode ADR 0015 section 3 explicitly avoided when it chose to upgrade every module every deploy.

---

# Addendum: the `/usr/bin/odoo *` wildcard is closed, and exactly half the threat with it (2026-08-15)

**Status:** Decided; implemented
**Amends:** section 3's deferred hardening item and the Consequences line that carried it.
**Not in scope:** the section 2 workflow-chaining hazard, and the five other sudoers rules (`systemctl` ×3, `git` ×2), which section 3 already scoped correctly.

## What replaced it

`ghrunner`'s `(odoo) NOPASSWD: /usr/bin/odoo *` is gone. In its place, two exact-match entries against a new root-owned script at `/usr/local/sbin/luxauto-odoo-deploy-ctl` (mode 0755, `root:root`), **deliberately outside the git clone**:

```
(odoo) NOPASSWD: /usr/local/sbin/luxauto-odoo-deploy-ctl upgrade,
                 /usr/local/sbin/luxauto-odoo-deploy-ctl smoketest
```

The wrapper takes exactly one of two literal words and passes nothing through. `upgrade` recomputes the module list itself from `$CLONE_DIR/odoo/addons/*/__manifest__.py` and runs the upgrade against a hardcoded clone path, config and database. `smoketest` pipes exactly `$CLONE_DIR/scripts/lib/smoke_test.py` into `odoo shell` against the same hardcoded config and database. Any other argument, or none, exits 2 with a usage message.

Provisioned by hand as `azureuser`, the same way ADR 0020 provisioned the original sudoers file. Nothing in CI, and nothing running from the clone, creates or edits either file - a workflow able to write them would hand back precisely the privilege they remove.

**No setuid, and that was checked rather than assumed.** Linux ignores the setuid bit on `#!` scripts entirely, so it was never available; it is also unnecessary, because sudo's `(odoo)` target already performs the transition exactly as it did for the old rule. The load-bearing property is not the invocation shape but the ownership: the wrapper is unwritable by `ghrunner` **and** by `odoo` - both verified, not inferred from the mode bits.

## What this actually narrows - and the hole that turned out to be worse than recorded

Section 3 argued the wildcard was "not a meaningful widening" because `odoo shell` already executes an arbitrary Python payload. That reasoning was sound for the threat it considered - a malicious commit - and it obscured a second one.

**The smoke-test payload was being read from `ghrunner`'s own workspace.** `deploy-vm.sh` piped `$SCRIPT_DIR/lib/smoke_test.py`, and under CI `SCRIPT_DIR` is the Actions checkout at `/opt/actions-runner/_work/.../scripts/lib/`, owned `ghrunner:ghrunner` and writable by it. So anything executing as `ghrunner` - a future workflow step, a runner-software vulnerability, anything at all - could write that file and pipe arbitrary Python into `odoo shell` as the `odoo` user **without touching the repository**. That is not the push-to-main boundary section 4 accepted; it is a separate path that did not require repo access, and it is the one this addendum closes.

After the change, `ghrunner` cannot invoke `/usr/bin/odoo` at all, cannot choose the database or config, and cannot choose the payload: the wrapper performs the redirection itself, so whatever the caller has on stdin is discarded, and the payload is resolved inside the clone, which `ghrunner` cannot write (it is not in the `odoo` group - checked).

## What this does NOT narrow, stated plainly

**Push access to `main` is still code execution as the `odoo` user.** That is section 4's boundary, it is unchanged, and it is not a gap this addendum failed to close:

- `upgrade` loads module code out of the clone. A commit adding an addon directory gets that module's Python executed by `odoo -u`.
- `smoketest` executes the repository's own `smoke_test.py`, live, on purpose.

**Freezing a copy of the smoke test inside the wrapper would close that second path and is deliberately not done.** The frozen copy would then have to be updated by hand every time the smoke test grows - and it grows: `luxauto.policy.cancellation` was added to it two commits ago. Nothing would fail loudly when someone forgot, so the privileged path would quietly stop covering new models while continuing to report `SMOKE_TEST_RESULT=PASS`. A smoke test that silently tests less than it claims is a worse outcome than the residual it would buy, given that push-to-main already grants the same access by a shorter route.

So the honest summary is: **this narrows what a compromised `ghrunner` runtime can do, and does not narrow what a malicious commit can do.** The sudoers rule is genuinely tighter, not merely narrower-looking - which is the distinction section 3 said it refused to blur, applied in the other direction now that a wrapper makes the tighter rule real.

## Changes to `deploy-vm.sh`

Two invocations changed and nothing else in the control flow. Three consequences of that were worth handling rather than leaving implicit:

- **`ODOO_CONF`, `ODOO_DB`, `ODOO_BIN` and `LUXAUTO_MODULES` now refuse instead of being ignored.** They are pinned in the wrapper, so honouring them is impossible - and silently ignoring `LUXAUTO_MODULES` would upgrade every module against production while telling the operator it had limited the scope. The script exits 1 naming the wrapper. `LUXAUTO_ADDONS_CLONE` still works; it feeds the git calls, which are pinned separately and unchanged.
- **The module scan stayed in `deploy-vm.sh` as a preflight**, duplicating the wrapper's. The duplication buys ordering: the empty-list refusal fires *before* `systemctl stop odoo`, so a bad clone does not take the service down on the way to an upgrade that was never going to run. The wrapper echoes the list it actually used, so the two disagreeing would be visible rather than silent.
- **The smoke-test payload now comes from the clone, not from the caller's checkout.** In CI these are the same commit. For a by-hand run from a working copy they are not: `scripts/deploy-vm.sh` run from `~/ai-ins-full-company` now smoke-tests the clone's copy. That is the correct source - it is the code Odoo actually loaded - but it is a behaviour change worth knowing before someone debugs a local edit that appears not to take effect.

## Verified, not assumed

Reproduce-before-trust, the same discipline the test suites use:

| Check | Result |
|---|---|
| Wildcard present before the change | `sudo -l -U ghrunner` listed `/usr/bin/odoo *` |
| Wildcard gone after | `sudo -l -U ghrunner` lists exactly the two wrapper entries; the five `systemctl`/`git` rules unchanged |
| `ghrunner` can still reach `odoo shell` | **No** - `sudo -u odoo /usr/bin/odoo shell --config … -d luxauto` as `ghrunner` returns `sudo: a password is required`, and the account is password-locked with no TTY in CI |
| `ghrunner` can reach `/usr/bin/odoo` at all | **No** - `--version` and `-d luxauto --stop-after-init` both refused |
| Wrapper reachable only in its two forms | `upgrade` and `smoketest` authorised; `restart`, no-argument, `smoketest --db-filter=x`, and `(root)` instead of `(odoo)` all refused by sudo |
| Wrapper's own validation | `restart`, empty, and `smoketest extra` each exit 2 with the usage message - two independent layers, sudoers and the script |
| Wrapper is tamper-proof | not writable by `ghrunner` or by `odoo`; `/usr/local/sbin` is `root:root 0755` |
| Sudoers file is valid | `visudo -c -f` on the candidate before installing, and a full `visudo -c` after |
| Real deploy end to end | run through the wrapper; both `LUXAUTO_DEPLOY_CTL=upgrade …` and `LUXAUTO_DEPLOY_CTL=smoketest …` banners appear in the output, and all seven models pass |

The `LUXAUTO_DEPLOY_CTL=` banner exists for that last row specifically: it prints the pinned database, config and (for `upgrade`) the module list the wrapper actually computed, so a future reader of a deploy log can see the pinned path ran rather than inferring it from a sudoers file they would have to go and read.

## Consequences

- The `/usr/bin/odoo *` wildcard is closed. Section 3's deferred item is done; section 2's chaining hazard is not, and remains the outstanding item from this ADR.
- **The deploy now depends on host state that is not in version control.** `/usr/local/sbin/luxauto-odoo-deploy-ctl` exists only on this VM, like the runner installation and the sudoers file. A rebuilt host needs it provisioned before `deploy-vm.sh` can run, and `sudo` will refuse loudly rather than fall back if it is missing. That is the price of the wrapper being outside the repo, which is the entire mechanism - but it is a real new dependency and belongs on the list of things this host carries that a `git clone` does not.
- `deploy-vm.yml`'s checkout step still carries a comment describing "its `scripts/lib/smoke_test.py` payload", which is now inaccurate - the payload comes from the clone. **It is deliberately not fixed here:** this host's credential lacks the `workflow` scope (section 4), so nothing on this VM can modify `.github/workflows/`. Correcting the comment needs a commit from outside, which is exactly the control section 4 chose to keep.
- Anyone adding a third privileged Odoo operation to the deploy must add a third literal subcommand to the wrapper and a third sudoers line. That friction is intentional: it is what stops the wildcard growing back one convenience at a time.
