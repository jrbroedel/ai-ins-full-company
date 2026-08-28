"""
Replay Mode engine (ADR 0043, Build 3 — Slice 1: engine only, headless).

WHAT THIS IS
------------
A PURE PLAYBACK engine over the frozen canonical artifact
(sample-data/canonical/canonical_dataset.json). Given a timeline position
(month 1..12, fraction 0..1), it emits a replay_state.json describing the demo
funnel cumulative-to-position. It is the deterministic source of "where are we
now" for the live investor board.

WHAT THIS IS NOT (bright line)
------------------------------
It reads the frozen artifact and NOTHING ELSE. It performs NO database access
of any kind: no connection, no read, no write — not to luxauto_demo and, above
all, never to production luxauto. It does not call submit_application(),
create_quote(), the rating engine, or any RPC. Premiums, losses and
dispositions come STRAIGHT from the artifact and are NEVER re-rated. This is the
whole safety property of replay: it plays back a committed number, it does not
recompute one.

Scope note (Slice 1): this module is the headless engine + a reconciliation
dump only. The exporter/snapshot.json wiring, the control panel, and the
systemd unit are Slices 2–3 and are deliberately NOT touched here. The engine is
directly invocable so the full 12-month timeline can be dumped and reconciled
before any of that is built.

CONTRACT (STEP 0) — replay_state.json, atomically written:
  provenance { mode:"replay", artifact_sha256, seed, adr }
  position   { month:1..12, fraction:0..1, wallclock_ts }
  premium_series  [ {month, avg_premium} ]  m1..current (per-month avg bound premium)
  loss_ratio_to_date   cumulative incurred / earned through current month
  per_state  [ {state, bound_count} ]  through current month
  headline   { gwp_to_date, bound_to_date, submissions_to_date, bind_ratio, avg_premium }
  declines   indicative-only, labeled, EXCLUDED from earned premium
  (audit)    incurred_losses_to_date, earned_premium_to_date — supporting the LR

SEMANTICS
---------
Cumulative-to-position. Aggregates cover complete months [m1 .. current] (all
records with month_index <= month-1). `fraction` is carried in position as
pacing metadata for the UI; in v1 it does NOT partially include the current
month's records (within-month interpolation is a later UI concern). At every
whole-month boundary the emitted aggregates equal exact record-level sums, which
is what the reconciliation gate checks.

Loss ratio is the ADR 0043 "bound book" definition: Σ(policy-period incurred)
÷ Σ(bound/earned premium), cumulative. A policy-period claim is attributed to
the month its POLICY was BOUND (its cohort month), NOT its calendar date of loss
— loss dates run forward past the 12-month window, so cohort attribution is the
only one that captures the full incurred by month 12. Each bound quote's
earned_premium equals its bound premium in the artifact, so incurred/earned ==
incurred/GWP == 0.5600 at year end. Declines carry an INDICATIVE premium only
and contribute ZERO earned premium.

DETERMINISM / NO WALL-CLOCK IN THE DUMP
---------------------------------------
The engine is pure. The reconciliation dump sets wallclock_ts to null so it is
byte-reproducible. A live single-state emit may stamp an ISO-8601 UTC timestamp
into position.wallclock_ts; that is the only non-deterministic field and it
lives only in the runtime state, never in the frozen artifact.

Usage:
  python3 replay_engine.py --reconcile            # headless full 12-month dump + gate
  python3 replay_engine.py --month 6 --out /tmp/replay_state.json
  python3 replay_engine.py --reconcile --dump-out /tmp/replay_reconciliation.json
"""

import argparse
import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Fixed contract constants
# ---------------------------------------------------------------------------
# Repo-relative: this file lives at scripts/lib/ ; repo root is two levels up.
ROOT = Path(__file__).resolve().parents[2]
CANON_DIR = ROOT / "sample-data" / "canonical"
DEFAULT_ARTIFACT = CANON_DIR / "canonical_dataset.json"

# The one frozen artifact this engine is allowed to play back. Fail-closed.
EXPECT_SHA = "965b986a29d24a4c33685af599c8be4eeb503fb21200251766a5ba0d9611427f"
ADR = "0043"
SEED = 20260827
MODE = "replay"

# Prod-name guard (bright line). This engine never opens a DB, but we refuse
# loudly if the environment even looks pointed at production, matching the
# discipline of the live generator / exporter guards.
PROD_DB_NAME = "luxauto"


# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
def _assert_no_prod_db() -> None:
    """Defense in depth. We connect to nothing; this makes that explicit and
    refuses if anyone wired a production DB name into the environment expecting
    this process to use it."""
    for var in ("PGDATABASE", "REPLAY_PGDATABASE", "DATABASE"):
        val = os.environ.get(var)
        if val is not None and val.strip().lower() == PROD_DB_NAME:
            raise SystemExit(
                f"REFUSED: {var}={val!r} names production '{PROD_DB_NAME}'. "
                "The replay engine touches no database; production is off limits."
            )
    # Belt-and-suspenders: this module must never import a DB driver.
    for banned in ("psycopg2", "psycopg"):
        if banned in sys.modules:
            raise SystemExit(
                f"REFUSED: {banned} is imported in this process; the replay "
                "engine must perform no database access."
            )


def _load_artifact(path: Path) -> dict:
    """Fail-closed sha256 verify against the one frozen artifact, then load."""
    raw = path.read_bytes()
    got = hashlib.sha256(raw).hexdigest()
    if got != EXPECT_SHA:
        raise SystemExit(
            f"REFUSED: artifact sha256 {got} != expected {EXPECT_SHA} "
            f"({path}). The engine only plays back the frozen canonical dataset."
        )
    data = json.loads(raw)
    if data.get("adr") != ADR or int(data.get("seed", -1)) != SEED:
        raise SystemExit(
            f"REFUSED: artifact adr/seed mismatch: adr={data.get('adr')} "
            f"seed={data.get('seed')} (expected {ADR}/{SEED})."
        )
    return data


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------
class ReplayEngine:
    """Pure playback over the frozen canonical dataset. No DB, no re-rating."""

    def __init__(self, artifact_path: Path = DEFAULT_ARTIFACT):
        _assert_no_prod_db()
        self.artifact_path = Path(artifact_path)
        self.data = _load_artifact(self.artifact_path)
        self.artifact_sha256 = EXPECT_SHA
        self.months = int(self.data["months"])
        self.subs = self.data["submissions"]
        self.claims = self.data["policy_period_claims"]

        # policy_id -> cohort month_index (the month the policy was BOUND).
        self._pid_to_month = {
            s["policy"]["policy_id"]: s["month_index"]
            for s in self.subs
            if s.get("policy")
        }
        # Every policy-period claim must map to a bound policy in the artifact.
        unmatched = [c for c in self.claims if c["policy_id"] not in self._pid_to_month]
        if unmatched:
            raise SystemExit(
                f"REFUSED: {len(unmatched)} policy-period claim(s) reference a "
                "policy_id not present as a bound submission; artifact is "
                "internally inconsistent."
            )

        self._precompute()
        self._self_check()

    # -- per-month record-level rollups (single source of truth) -----------
    def _precompute(self) -> None:
        n = self.months
        self.m_submissions = [0] * n
        self.m_binds = [0] * n
        self.m_bound_premium = [0.0] * n     # Σ bound premium in month
        self.m_earned_premium = [0.0] * n     # Σ earned_premium of bound quotes
        self.m_declines = [0] * n
        self.m_decline_indicative = [0.0] * n  # Σ indicative premium of declines
        self.m_incurred = [0.0] * n            # by policy COHORT month
        self.m_state_binds = [dict() for _ in range(n)]  # {state: count}

        for s in self.subs:
            mi = s["month_index"]
            q = s["quote"]
            self.m_submissions[mi] += 1
            if q["is_bound"]:
                self.m_binds[mi] += 1
                self.m_bound_premium[mi] += q["premium"]
                self.m_earned_premium[mi] += q.get("earned_premium", 0.0)
                st = s["garaging_state"]
                self.m_state_binds[mi][st] = self.m_state_binds[mi].get(st, 0) + 1
            if s["disposition"] == "decline":
                self.m_declines[mi] += 1
                # A decline's premium is INDICATIVE only and never earned.
                self.m_decline_indicative[mi] += q["premium"]

        for c in self.claims:
            cohort = self._pid_to_month[c["policy_id"]]
            self.m_incurred[cohort] += c["incurred"]

    # -- cross-check against the artifact's own summary/aggregates ----------
    def _self_check(self) -> None:
        S = self.data["summary"]
        assert sum(self.m_submissions) == S["submissions"], "submission total drift"
        assert sum(self.m_binds) == S["binds"], "bind total drift"
        assert sum(self.m_declines) == S["declines"], "decline total drift"
        gwp = round(sum(self.m_bound_premium), 2)
        assert abs(gwp - S["gwp_bound"]) < 0.01, f"gwp drift {gwp} vs {S['gwp_bound']}"
        inc = round(sum(self.m_incurred), 2)
        assert abs(inc - S["total_incurred_losses"]) < 0.01, "incurred drift"
        # Per-month avg bound premium must match monthly_aggregates.
        for ma in self.data["monthly_aggregates"]:
            mi = ma["month_index"]
            if self.m_binds[mi]:
                avg = round(self.m_bound_premium[mi] / self.m_binds[mi], 2)
                assert abs(avg - ma["avg_bound_premium"]) < 0.01, (
                    f"month {mi} avg premium drift {avg} vs {ma['avg_bound_premium']}"
                )

    # -- the state emitter --------------------------------------------------
    def state_at(self, month: int, fraction: float = 1.0, wallclock_ts=None) -> dict:
        """Emit the cumulative-to-position replay state.

        month:    1..months (1-indexed timeline position).
        fraction: 0..1, pacing metadata for the UI; does NOT partially include
                  the current month's records in v1 (see module docstring).
        """
        if not (1 <= month <= self.months):
            raise ValueError(f"month {month} out of range 1..{self.months}")
        if not (0.0 <= fraction <= 1.0):
            raise ValueError(f"fraction {fraction} out of range 0..1")
        top = month  # inclusive count of complete months, 1-indexed
        idx = range(top)  # month_index 0..top-1

        subs_td = sum(self.m_submissions[i] for i in idx)
        bound_td = sum(self.m_binds[i] for i in idx)
        gwp_td = round(sum(self.m_bound_premium[i] for i in idx), 2)
        earned_td = round(sum(self.m_earned_premium[i] for i in idx), 2)
        incurred_td = round(sum(self.m_incurred[i] for i in idx), 2)
        declines_td = sum(self.m_declines[i] for i in idx)
        decline_indic_td = round(sum(self.m_decline_indicative[i] for i in idx), 2)

        avg_premium = round(gwp_td / bound_td, 2) if bound_td else 0.0
        bind_ratio = round(bound_td / subs_td, 4) if subs_td else 0.0
        loss_ratio = round(incurred_td / earned_td, 4) if earned_td else 0.0

        # premium_series: per-month avg bound premium, m1..current.
        premium_series = [
            {
                "month": i + 1,
                "avg_premium": round(self.m_bound_premium[i] / self.m_binds[i], 2)
                if self.m_binds[i]
                else 0.0,
            }
            for i in idx
        ]
        change_pct = None
        if len(premium_series) >= 2 and premium_series[0]["avg_premium"]:
            a = premium_series[0]["avg_premium"]
            b = premium_series[-1]["avg_premium"]
            change_pct = round((b - a) / a * 100.0, 1)

        # per_state bound counts, cumulative, sorted by state.
        state_counts = {}
        for i in idx:
            for st, c in self.m_state_binds[i].items():
                state_counts[st] = state_counts.get(st, 0) + c
        per_state = [
            {"state": st, "bound_count": state_counts[st]}
            for st in sorted(state_counts)
        ]

        return {
            "provenance": {
                "mode": MODE,
                "artifact_sha256": self.artifact_sha256,
                "seed": SEED,
                "adr": ADR,
            },
            "position": {
                "month": month,
                "fraction": fraction,
                "wallclock_ts": wallclock_ts,
            },
            "premium_series": premium_series,
            "premium_change_pct_m1_to_current": change_pct,
            "loss_ratio_to_date": loss_ratio,
            "per_state": per_state,
            "headline": {
                "gwp_to_date": gwp_td,
                "bound_to_date": bound_td,
                "submissions_to_date": subs_td,
                "bind_ratio": bind_ratio,
                "avg_premium": avg_premium,
            },
            "declines": {
                "count_to_date": declines_td,
                "indicative_premium_to_date": decline_indic_td,
                "label": "indicative_only",
                "excluded_from_earned_premium": True,
            },
            "audit": {
                "incurred_losses_to_date": incurred_td,
                "earned_premium_to_date": earned_td,
                "artifact_months": self.months,
            },
        }

    def run_headless(self):
        """The full timeline at whole-month boundaries (fraction=1.0), m1..m12.
        Deterministic (wallclock_ts=None). Used for the reconciliation dump."""
        return [self.state_at(m, fraction=1.0, wallclock_ts=None)
                for m in range(1, self.months + 1)]


# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------
def atomic_write_json(obj, out_path: Path) -> None:
    """Write JSON to a temp file in the same directory, fsync, then os.replace.
    A reader either sees the old file or the whole new one, never a partial."""
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(out_path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, sort_keys=True, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, out_path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


# ---------------------------------------------------------------------------
# Reconciliation gate
# ---------------------------------------------------------------------------
# ADR 0043 targets, reconciled EXACTLY (to the cent / stated precision) at m12.
RECON_TARGETS = {
    "submissions_to_date": 3300,
    "bound_to_date": 2414,
    "gwp_to_date": 23020114.17,
    "avg_premium": 9536.09,
    "loss_ratio_to_date": 0.5600,
    "incurred_losses_to_date": 12891263.97,
    "premium_change_pct_m1_to_current": -23.5,
}


def reconcile(engine: ReplayEngine):
    """Run headless over all 12 months and check the final state EXACTLY against
    the ADR 0043 targets. Returns (ok, checks, series)."""
    series = engine.run_headless()
    final = series[-1]
    h = final["headline"]
    a = final["audit"]
    got = {
        "submissions_to_date": h["submissions_to_date"],
        "bound_to_date": h["bound_to_date"],
        "gwp_to_date": h["gwp_to_date"],
        "avg_premium": h["avg_premium"],
        "loss_ratio_to_date": final["loss_ratio_to_date"],
        "incurred_losses_to_date": a["incurred_losses_to_date"],
        "premium_change_pct_m1_to_current": final["premium_change_pct_m1_to_current"],
    }
    checks = []
    ok = True
    for k, want in RECON_TARGETS.items():
        g = got[k]
        if isinstance(want, float):
            passed = abs(g - want) < 0.005  # to the cent / 0.1pt
        else:
            passed = g == want
        ok = ok and passed
        checks.append({"metric": k, "expected": want, "got": g, "pass": passed})

    # Declines must be present, indicative-only, labeled, excluded from earned.
    d = final["declines"]
    decl_ok = (
        d["count_to_date"] > 0
        and d["label"] == "indicative_only"
        and d["excluded_from_earned_premium"] is True
    )
    # And the earned-premium base must exclude decline indicative premium:
    #   earned == GWP (bound only), declines contribute zero earned.
    earned_excludes_declines = abs(a["earned_premium_to_date"] - h["gwp_to_date"]) < 0.01
    checks.append({"metric": "declines_indicative_only_labeled",
                   "expected": True, "got": decl_ok, "pass": decl_ok})
    checks.append({"metric": "earned_excludes_decline_premium",
                   "expected": True, "got": earned_excludes_declines,
                   "pass": earned_excludes_declines})
    ok = ok and decl_ok and earned_excludes_declines
    return ok, checks, series


def _fmt_money(x):
    return f"${x:,.2f}"


def cmd_reconcile(engine: ReplayEngine, dump_out: Path | None) -> int:
    ok, checks, series = reconcile(engine)
    print("=== Replay engine reconciliation (headless, 12 months) ===")
    print(f"artifact: {engine.artifact_path}")
    print(f"sha256:   {engine.artifact_sha256}")
    print()
    print("Per-month cumulative-to-position:")
    print("  m  subs  bound        gwp     avgPrem   LR      incurred      decl")
    for st in series:
        h = st["headline"]; a = st["audit"]; p = st["position"]
        print(f"  {p['month']:2d} {h['submissions_to_date']:5d} "
              f"{h['bound_to_date']:5d} {_fmt_money(h['gwp_to_date']):>14} "
              f"{h['avg_premium']:9.2f} {st['loss_ratio_to_date']:.4f} "
              f"{_fmt_money(a['incurred_losses_to_date']):>14} "
              f"{st['declines']['count_to_date']:5d}")
    print()
    print("Gate checks (against ADR 0043 targets):")
    for c in checks:
        mark = "PASS" if c["pass"] else "FAIL"
        print(f"  [{mark}] {c['metric']:38s} expected={c['expected']} got={c['got']}")
    print()

    if dump_out is not None:
        dump = {
            "provenance": series[-1]["provenance"],
            "reconciliation": {
                "ok": ok,
                "targets": RECON_TARGETS,
                "checks": checks,
            },
            "series": series,
        }
        atomic_write_json(dump, dump_out)
        print(f"reconciliation dump written: {dump_out}")

    if ok:
        print("RECONCILED: all targets match exactly. ✓")
        return 0
    print("DISCREPANCY: reconciliation FAILED — not clean. ✗")
    return 1


def cmd_emit(engine: ReplayEngine, month: int, fraction: float,
             out: Path, live_ts: bool) -> int:
    ts = datetime.now(timezone.utc).isoformat() if live_ts else None
    state = engine.state_at(month, fraction=fraction, wallclock_ts=ts)
    atomic_write_json(state, out)
    print(f"replay_state.json written (month={month}, fraction={fraction}): {out}")
    print(json.dumps(state["headline"], indent=2))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="ADR 0043 Replay Mode engine (Slice 1)")
    ap.add_argument("--artifact", default=str(DEFAULT_ARTIFACT),
                    help="path to the frozen canonical_dataset.json")
    ap.add_argument("--reconcile", action="store_true",
                    help="run headless over all 12 months and check the gate")
    ap.add_argument("--dump-out", default=None,
                    help="write the full reconciliation dump JSON here")
    ap.add_argument("--month", type=int, default=None,
                    help="emit a single replay_state at this month (1..12)")
    ap.add_argument("--fraction", type=float, default=1.0,
                    help="within-month pacing fraction (0..1), position metadata")
    ap.add_argument("--out", default=None,
                    help="output path for --month single-state emit")
    ap.add_argument("--live-ts", action="store_true",
                    help="stamp position.wallclock_ts with now() (non-deterministic)")
    args = ap.parse_args(argv)

    engine = ReplayEngine(Path(args.artifact))

    if args.reconcile:
        rc = cmd_reconcile(engine, Path(args.dump_out) if args.dump_out else None)
        if args.month is None:
            return rc

    if args.month is not None:
        if not args.out:
            ap.error("--month requires --out")
        return cmd_emit(engine, args.month, args.fraction, Path(args.out), args.live_ts)

    if not args.reconcile:
        ap.error("nothing to do: pass --reconcile and/or --month/--out")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
