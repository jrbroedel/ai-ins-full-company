# ADR 0022: Behavioural test suites, in the repository and in CI

**Status:** Decided; implemented
**Date:** 2026-08-14
**Follows from:** ADR 0015 (built the schema-apply script and its verifier), ADR 0020 (gave that script a trigger and a runner), ADR 0017 and ADR 0021 (both established the test discipline this makes permanent, and both named its absence as a problem)
**Not in scope:** unit tests for the Odoo module, any test of the referral/rating logic, and an isolated test database - the last is named as this ADR's principal open item rather than solved.

## What this ADR decides

Since ADR 0017 this project has had a real testing discipline: reproduce a failure mode against the live database before writing the code that fixes it, then prove the fix, then prove the neighbouring behaviours did not regress. That discipline produced genuine findings - the `LIMIT 1` probe defect in ADR 0021 section 2, the reachable over-100% at widen time in its addendum - that no amount of reading the code had surfaced.

What the project did not have was anywhere to put the resulting suites. They lived in a scratchpad directory, were deleted during cleanup, and were reconstructed by hand from a session transcript twice in order to satisfy a re-run request. A test that has to be rebuilt from prose before it can be run is not a regression test; it is a memory of one.

This ADR decides four things: where suites live and what one is, how a suite is written now that it has to fail loudly instead of being read by a person, what makes CI red, and where the database credentials come from.

**ADR 0015's verifier baseline does not move.** Nothing here adds a schema object; `verify_schema.py` and the counts it guards are untouched.

## 1. `tests/`, one file per ADR

**Decision: suites live in `tests/`, one `.sql` file per ADR, named to mirror `docs/decisions/`.**

Three files exist as of this ADR:

| File | Cases |
|---|---|
| `tests/0017_program_participant_temporal_integrity.sql` | 12 |
| `tests/0021_participant_removal_and_coverage_gaps.sql` | 16 |
| `tests/0021_addendum_widen_gap_suppression.sql` | 10 |

Pairing a suite with an ADR rather than with a table or a function is the choice worth explaining. The unit of work in this project is a decision, and what a suite is actually protecting is the *reasoning* an ADR recorded - "over-100% is never suppressible", "the term's own lower bound must be probed" - not the incidental shape of whatever function currently implements it. A file named after the decision keeps the case and its justification findable from each other. Several cases here would be unmotivated read on their own; `0017-T7` is only interesting once you know ADR 0017 argued the probe set must include the program term's lower bound.

**The ADR 0021 addendum got its own file, and that was decided rather than defaulted.** The argument for appending it to the parent was that an addendum is not a new decision. The argument that won: its cases are about range algebra on `insurance_programs`, not about participant removal, and two of them exist purely to pin down *which range comparison is correct* - a question the parent suite never asks. Interleaving them would have obscured both halves. The rule going forward is that an addendum appends to its parent unless its cases are about a different thing, which is a judgement each addendum has to make explicitly.

## 2. How a suite is written, and what changed when a human stopped reading the output

Every suite is one transaction that ends in `ROLLBACK`. Nothing is ever committed, on success or on failure. That was already the manual pattern, for two reasons that both still hold: these run against `luxauto-pg` itself (section 5), and `program_participants` is append-only, so a committed test row could not be deleted afterwards - not even by cascading from `insurance_programs`, whose delete the trigger also rejects.

The deferred share-sum trigger is forced with `SET CONSTRAINTS ALL IMMEDIATE` rather than by committing. This is what makes a rolled-back suite able to test a constraint that only fires at commit.

**What did change is that assertions now have to raise.** When a person ran these by hand, "expected" and "actual" were compared by eye against printed output. Under `ON_ERROR_STOP=1` in CI nobody reads the output unless something is already wrong, so every case ends in an `IF ... RAISE EXCEPTION` that states what it expected and what it got.

That inverts the awkward half. A case asserting that something is *rejected* cannot simply run the offending statement - the error would stop psql and fail the suite, which is the opposite of the intent. So those cases catch it and assert on it:

```sql
BEGIN
  <the statement that must fail>;
  SET CONSTRAINTS ALL IMMEDIATE;
EXCEPTION WHEN OTHERS THEN
  v_ok := true; v_err := SQLERRM;
END;
IF NOT v_ok THEN RAISE EXCEPTION '... expected X, but it succeeded'; END IF;
IF v_err NOT LIKE '%X%' THEN RAISE EXCEPTION '... wrong error: %', v_err; END IF;
```

Checking the *message* and not merely that something failed is deliberate: a case that only asserts "an error happened" passes for the wrong reason the moment a typo makes the setup fail first. Several of these assert on the error token (`PROGRAM_SHARES_NOT_100_AT_INSTANT`) and, where the number carries the meaning, on the number too (`%130%`).

**Cases that assert success unwind themselves.** Each ends by raising a `ROLLBACK_CASE` sentinel its own handler swallows, so the case's rows never reach the next case:

```sql
BEGIN
  <setup, action, assertions>;
  RAISE EXCEPTION 'ROLLBACK_CASE';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
END;
```

A real assertion failure carries a different message, so the `RAISE` re-raises it and the suite stops. Without this, one case's leftover panel is visible to the next case's probes and to any later `SET CONSTRAINTS ALL IMMEDIATE` - a contamination that would show up as an unrelated case failing, which is the worst kind of test failure to debug.

That plpgsql could do all of this was verified before the suites were written rather than assumed. Three things needed checking and all three hold: `SET CONSTRAINTS` is permitted inside a `DO` block, a deferred constraint trigger's error is catchable by an exception handler, and the subtransaction rollback that a caught exception performs really does discard the case's rows.

## 3. Refusing to run a suite that could commit

**Decision: `scripts/run-tests.sh` statically checks every file before executing any of them, and refuses one that does not have a top-level `BEGIN;` and `ROLLBACK;`, or that contains a bare `COMMIT;`.**

The rollback discipline is the only thing standing between these suites and rows in production tables. It is currently maintained by everyone who writes a suite remembering it. A grep is a cheap net under that, and this project's habit is to check rather than trust.

The patterns are line-anchored, which matters in both directions and was tested in both: a plpgsql `BEGIN` opening a block body does not satisfy the `BEGIN;` requirement, and the word "committed" sitting in a comment - which appears in all three suites - does not trip the `COMMIT;` check. A refusal is a failure, not a skip.

An empty `tests/` directory is also a failure. A test run that finds nothing to do prints success and exits 0, which is indistinguishable in a CI log from a run that passed.

## 4. Failing CI, and why this one *is* chained

**Decision: the suites run as a step in the existing `apply-and-verify` job, immediately after "Apply and verify schema". A failure fails the job and therefore the push.**

ADR 0020 made a point of leaving `schema-apply` and `deploy-vm` uncoupled, and that reasoning does not transfer here, so it is worth saying why rather than letting the precedent do the work. Those two workflows were left independent because neither needs the other - the coupling would have been invented. These suites exercise the schema this job has just applied. Running them anywhere else would mean either duplicating the apply or racing it. The dependency is real, so it is expressed as ordering within one job, which is also the only way to guarantee it: a separate workflow has no way to wait.

The whole run reports before it exits. Every file is executed even after one fails, and the summary lists all of them, because "the first thing that broke" is frequently not the informative one - a single schema change that breaks four cases across two ADRs says something different from one that breaks one.

**The runner was proven to fail, not assumed to.** An assertion in a copy of the 0017 suite was deliberately corrupted; the run reported `ERROR: 0017-T2 FAILED: ...`, marked that file `FAIL` in the summary, reported `1 of 4 suite(s) FAILED`, and exited 1 - while still running and passing the other three. The safety check was proven the same way, against files missing `BEGIN;`, missing `ROLLBACK;`, and containing an indented `COMMIT;`.

## 5. One credential path, shared - with one deliberate exception

**Decision: the Key Vault fetch moves out of `apply-and-verify-schema.sh` into `scripts/lib/fetch-pg-credentials.sh`, which both that script and `run-tests.sh` source.**

Two copies of a managed-identity credential fetch is two places for a default to drift. The extraction preserves behaviour exactly, including the escape hatch that makes local runs possible: if `PGHOST`, `PGUSER` and `PGPASSWORD` are all already set, Key Vault is never contacted.

Whether sharing was safe was checked before doing it, and the check found something. **`expire-policies.sh` is deliberately not a consumer.** It connects as the `odoo` role with the password read from `odoo.conf` - a different identity from a different source, chosen for least privilege on a scheduled job. Folding it in would either widen it to the admin role or force this file to grow a second credential source. Two small paths that each do one thing is the better shape, and that is recorded here so the next person to notice the apparent duplication does not "fix" it.

Behaviour after the refactor was confirmed against a capture taken before it: with credentials pre-set the output is byte-identical, and with them unset the Key Vault path exits 0 and differs only by the line announcing the fetch.

## Consequences

- The two suites that previously existed only as prose are now runnable, and running them is no longer something a person has to remember to do. The next unrelated push proves 38 cases across three ADRs still hold.
- Any schema change that breaks a recorded decision now turns the push red. That is the point, and it is also the cost: a deliberate behaviour change (ADR 0021's addendum changed two of ADR 0021's own cases) now requires updating the suite in the same commit, which is the correct amount of friction.
- The backfilled suites were reconstructed from the ADRs and the sessions that produced them, so they encode *what those ADRs claim* plus the current behaviour, not a literal transcript of the original scripts. They were run against the current schema and pass; where the original wording is gone, the assertion is written against the ADR's stated reasoning.
- Every test UUID uses a namespaced prefix (`00000017-…`, `00000021-…`, `21ADD000-…`) so a leak would be identifiable rather than anonymous. Checked after a full run: all three tables hold zero rows and no such row exists.

## Open items

- **The suites run against `luxauto-pg` itself, the production database.** This is the significant one. It is currently safe for reasons that are true today and will not always be: the tables involved hold zero rows, every suite rolls back, and the runner refuses a file that could commit. None of that survives contact with real data - a suite that rolls back still takes locks, still consumes transaction ids, and a bug in a future suite that manages to commit lands in production. This should be revisited before there is anything in these tables worth losing. The likely shape is a separate database on the same server that `apply-and-verify-schema.sh` also applies to, which is more infrastructure than this ADR is taking on.
- **No test isolation between suites beyond the rollback.** Two suites cannot run concurrently against the same database without interfering; the runner is serial, which is currently enough and is not enforced.
- **Coverage is only what ADR 0017 and ADR 0021 decided.** ADRs 0010, 0013, 0014, 0016, 0018 and 0019 all made behavioural decisions with no suite here. Backfilling them is worth doing and is not done; this ADR establishes where they would go.
- **Nothing covers the Odoo module**, the referral matrices, or the rating tables. This is a database test harness, not a project-wide one.
- **A suite can only test what a transaction can reach.** `expire_policies()` runs from a systemd timer (ADR 0019) and the deploy smoke test runs under `deploy-vm.sh`; neither is exercised here.
