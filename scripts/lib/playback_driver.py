"""
Playback driver for the investor demo (ADR 0047): reveal the frozen $71M canonical
book over demo-time, NEVER fabricate.

WHAT THIS IS
------------
The book lives in luxauto_demo as the source of truth (ADR 0046). This long-lived
loop advances a single "playback clock" - one timestamptz cursor in a tiny dedicated
table demo_playback_state - at the control-set speed. The read-only exporter reads
that cursor and reveals only rows whose authoritative time key (applications.
submitted_at, app-grain; lower(effective_range), policy-grain) is <= the cursor, so
the board fills in over the operating year 2025-08 -> 2026-07 and, at full playback,
IS the whole $71M book (foots to the artifact to the cent).

THIS RETIRES FABRICATION. It NEVER INSERTs into the book (applications/quotes/
policies/decision_log/canonical_*). Its ONLY write anywhere is UPDATE-ing the single
demo_playback_state row (plus the idempotent CREATE TABLE / one-row seed on startup).
So the frozen book can never be polluted and every tile foots at all times.

CONTROL (same intent flow as before, reinterpreted)
----------------------------------------------------
Reads the same local control file the agent maintains
(/home/azureuser/demo-control/generator-control.json):
    { "state": "running"|"paused", "preset": "<name>", "rate_per_min": <n> }
  - state running -> the clock advances; paused -> the clock freezes (board holds).
  - preset -> a base REVEAL SPEED (surge fast ... volume_drying slow).
  - rate_per_min -> scales that speed (the panel's rate slider still means something).
Reset (nonce, via the control agent) -> REWIND the cursor to the start (empty board),
NOT a DROP/reprovision (that would destroy the canonical load).

TARGET GUARD (non-negotiable): refuses unless PGDATABASE == 'luxauto_demo' and the
live current_database() == 'luxauto_demo'; refuses production 'luxauto' outright.
Creds via the wrapper's Key Vault path, same as every admin job here.

CONNECTION HEALTH: the old fabricator's failure mode was a long-lived connection that
died on rebuild and silently stopped writing. This loop treats ANY DB error as a
reconnect signal (OperationalError AND InterfaceError / "connection already closed")
and re-establishes the connection on the next tick, so a dropped connection can never
silently freeze the cursor.

Usage (via scripts/playback-driver.sh, which sets creds + PGDATABASE):
  scripts/playback-driver.sh              # the playback loop
  scripts/playback-driver.sh --rewind     # rewind the cursor to the start (one-shot)
"""
import json
import logging
import os
import signal
import sys
import time
from datetime import datetime, timedelta, timezone

import psycopg2

from scenario_seed import ensure_scenarios  # ADR 0048: create+seed the five scenarios

EXPECTED_DB = "luxauto_demo"
PROD_DB = "luxauto"

# The frozen operating year (the artifact's submitted_at span, verified 2025-08-01 ..
# 2026-07-31 across all 10,500 subs). Cursor >= WINDOW_END => whole book revealed.
WINDOW_START = datetime(2025, 8, 1, tzinfo=timezone.utc)
WINDOW_END = datetime(2026, 7, 31, 23, 59, 59, tzinfo=timezone.utc)
# Rewind target: just before the first submission -> an empty (but valid) board.
REWIND_POSITION = datetime(2025, 7, 31, 0, 0, 0, tzinfo=timezone.utc)

CONTROL_FILE = os.environ.get(
    "GEN_CONTROL_FILE", "/home/azureuser/demo-control/generator-control.json"
)
TICK_SECONDS = float(os.environ.get("PLAYBACK_TICK_SECONDS", "2.0"))

# PACE now comes from scenario_defs.pace (ADR 0048), read by the active scenario name -
# NOT a hardcoded per-preset map, so adding a scenario is one INSERT, no code. These are
# the reference knobs a scenario's pace JSON scales:
#   {"speed_scale": s}          -> reveal speed = BASE * s (surge s=3.0, steady s=1.0)
#   {"mode":"taper","late_factor":f} -> in the late window, advance slows to *f (volume dries)
# rate_per_min still scales speed (relative to DEFAULT_RATE) so the panel's rate slider bends pace.
# Demo-pacing knobs only - they reveal frozen rows faster/slower, never change the data.
BASE_DAYS_PER_MIN = 60.0            # 365-day year revealed in ~6 min at speed_scale 1.0, default rate
DEFAULT_RATE = 2.0                 # the rate at which speed_scale applies as-is
LATE_START_MONTH_INDEX = 6         # taper kicks in from the operating year's second half
DEFAULT_PRESET = "steady"
RATE_MIN_PER_MIN = 0.1
RATE_MAX_PER_MIN = 30.0
DEFAULT_PACE = {"speed_scale": 1.0, "mode": "linear"}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s playback-driver: %(message)s",
)
log = logging.getLogger("playback-driver")


# --------------------------------------------------------------------------- #
# Target guard - the one mistake this job must structurally refuse.
# --------------------------------------------------------------------------- #
def guard_target(cur=None) -> None:
    dbname = os.environ.get("PGDATABASE")
    if dbname == PROD_DB:
        raise SystemExit(f"REFUSING TO RUN: PGDATABASE is {dbname!r} (production).")
    if dbname != EXPECTED_DB:
        raise SystemExit(
            f"REFUSING TO RUN: PGDATABASE is {dbname!r}, expected {EXPECTED_DB!r}. "
            f"Set PGDATABASE={EXPECTED_DB} explicitly (the wrapper does this)."
        )
    if cur is not None:
        cur.execute("SELECT current_database()")
        live = cur.fetchone()[0]
        if live == PROD_DB:
            raise SystemExit(f"REFUSING TO RUN: connected database is {live!r} (production).")
        if live != EXPECTED_DB:
            raise SystemExit(
                f"REFUSING TO RUN: connected database is {live!r}, expected {EXPECTED_DB!r}."
            )


def connect():
    guard_target()
    conn = psycopg2.connect()
    conn.autocommit = False
    with conn.cursor() as cur:
        guard_target(cur)
    return conn


# --------------------------------------------------------------------------- #
# The cursor table - the ONLY thing this driver writes. Never the book.
# --------------------------------------------------------------------------- #
def ensure_state(conn) -> datetime:
    """Create demo_playback_state (idempotent), including the ADR 0048 `scenario`
    column, and seed the single row if absent. Seeds to REWIND_POSITION (start-EMPTY,
    ADR 0048) so the board opens empty and plays UP. Returns current_position."""
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS demo_playback_state ("
            " id BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),"
            " current_position TIMESTAMPTZ NOT NULL,"
            " mode TEXT,"
            " scenario TEXT,"
            " updated_at TIMESTAMPTZ NOT NULL DEFAULT now())"
        )
        # ADR 0048: the exporter reads the active scenario off this row; add the column
        # if an ADR-0047-era table pre-exists.
        cur.execute("ALTER TABLE demo_playback_state ADD COLUMN IF NOT EXISTS scenario TEXT")
        cur.execute(
            "INSERT INTO demo_playback_state (id, current_position, mode, scenario) "
            "VALUES (true, %s, 'rewound', %s) ON CONFLICT (id) DO NOTHING",
            (REWIND_POSITION, DEFAULT_PRESET),
        )
        cur.execute("SELECT current_position FROM demo_playback_state WHERE id")
        pos = cur.fetchone()[0]
    conn.commit()
    return pos


def set_position(conn, pos: datetime, mode: str, scenario: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE demo_playback_state SET current_position = %s, mode = %s, "
            "scenario = %s, updated_at = now() WHERE id",
            (pos, mode, scenario),
        )
    conn.commit()


def scenario_pace(conn, name: str) -> dict:
    """Read the active scenario's pace JSON from scenario_defs; default if absent."""
    with conn.cursor() as cur:
        cur.execute("SELECT pace FROM scenario_defs WHERE name = %s", (name,))
        row = cur.fetchone()
    if not row or not row[0]:
        return dict(DEFAULT_PACE)
    return row[0]


# --------------------------------------------------------------------------- #
# Control file (the same local file the agent maintains).
# --------------------------------------------------------------------------- #
def load_control():
    default = {"state": "running", "preset": DEFAULT_PRESET, "rate_per_min": DEFAULT_RATE}
    try:
        with open(CONTROL_FILE) as f:
            raw = json.load(f)
    except FileNotFoundError:
        return default
    except Exception as exc:
        log.warning("control file %s unreadable (%s); using default", CONTROL_FILE, exc)
        return default
    if not isinstance(raw, dict):
        return default
    state = raw.get("state") if raw.get("state") in ("running", "paused") else "running"
    # The scenario NAME is not validated against a hardcoded list (ADR 0048): the driver
    # looks its pace up in scenario_defs, and an unknown name falls back to the default
    # pace. So a scenario added by INSERT is honored with no code change.
    preset = raw.get("preset") or DEFAULT_PRESET
    try:
        rate = float(raw.get("rate_per_min", DEFAULT_RATE))
    except (TypeError, ValueError):
        rate = DEFAULT_RATE
    rate = min(max(rate, RATE_MIN_PER_MIN), RATE_MAX_PER_MIN)
    return {"state": state, "preset": str(preset), "rate_per_min": rate}


def days_per_second(pace: dict, rate_per_min: float, pos: datetime) -> float:
    """Reveal speed in demo-days per REAL second from the scenario's pace + rate.
    Taper (volume_drying) slows the advance once the cursor reaches the late window."""
    speed_scale = float(pace.get("speed_scale", 1.0) or 1.0)
    rate_scale = (rate_per_min / DEFAULT_RATE) if DEFAULT_RATE else 1.0
    taper = 1.0
    if pace.get("mode") == "taper":
        month_index = (pos.year - 2025) * 12 + (pos.month - 8)
        if month_index >= LATE_START_MONTH_INDEX:
            taper = float(pace.get("late_factor", 1.0) or 1.0)
    return (BASE_DAYS_PER_MIN * speed_scale * rate_scale * taper) / 60.0


# --------------------------------------------------------------------------- #
# Rewind (one-shot) - reset == rewind, NEVER reprovision.
# --------------------------------------------------------------------------- #
def rewind() -> int:
    conn = connect()
    try:
        ensure_scenarios(conn)
        ensure_state(conn)
        # Preserve the active scenario across a rewind; the control file names it.
        scenario = load_control().get("preset", DEFAULT_PRESET)
        set_position(conn, REWIND_POSITION, "rewound", scenario)
        log.info("REWIND: cursor set to %s (empty board; playback will re-reveal). scenario=%s",
                 REWIND_POSITION.date(), scenario)
    finally:
        conn.close()
    return 0


# --------------------------------------------------------------------------- #
# The playback loop.
# --------------------------------------------------------------------------- #
_STOP = False


def _handle_stop(signum, _frame):
    global _STOP
    _STOP = True
    log.info("received signal %s - will exit after this tick", signum)


def _sleep(seconds: float) -> None:
    slept = 0.0
    while slept < seconds and not _STOP:
        time.sleep(min(0.5, seconds - slept))
        slept += 0.5


def run_loop() -> int:
    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    conn = connect()
    ensure_scenarios(conn)     # ADR 0048: create + seed the five committed scenarios (idempotent)
    pos = ensure_state(conn)
    log.info("playback driver up: db=%s cursor=%s control_file=%s window=%s..%s",
             EXPECTED_DB, pos.isoformat(), CONTROL_FILE,
             WINDOW_START.date(), WINDOW_END.date())

    last_state = None
    last_preset = None
    last_tick = time.monotonic()
    while not _STOP:
        ctrl = load_control()
        scenario = ctrl["preset"]
        pace = scenario_pace(conn, scenario)
        if scenario != last_preset:
            log.info("scenario -> %s (pace=%s, rate=%.2f)", scenario, pace, ctrl["rate_per_min"])
            last_preset = scenario

        now = time.monotonic()
        elapsed = now - last_tick
        last_tick = now

        if ctrl["state"] == "paused":
            if last_state != "paused":
                log.info("state -> paused: clock frozen at %s (board holds; nothing written)",
                         _fmt(pos))
            last_state = "paused"
            # Keep the scenario name current even while paused, so the exporter's overlay
            # follows a preset switch without waiting for the clock to advance.
            try:
                set_position(conn, pos, "paused", scenario)
            except Exception:
                pass
            _sleep(TICK_SECONDS)
            continue
        if last_state != "running":
            log.info("state -> running: revealing from %s", _fmt(pos))
        last_state = "running"

        # Advance the cursor by elapsed real-time * speed, clamped at the window end.
        try:
            if pos < WINDOW_END:
                pos = min(pos + timedelta(days=days_per_second(pace, ctrl["rate_per_min"], pos) * elapsed), WINDOW_END)
                mode = "full" if pos >= WINDOW_END else "playing"
                set_position(conn, pos, mode, scenario)
                if mode == "full":
                    log.info("reached window end -> full book revealed; idling until rewind")
            else:
                # Already full; keep the scenario name current (overlay follows a switch).
                set_position(conn, pos, "full", scenario)
        except (psycopg2.OperationalError, psycopg2.InterfaceError) as exc:
            # Connection dropped (the old fabricator's silent-freeze failure mode).
            # Reconnect on the next tick; NEVER let the cursor silently stall.
            log.error("DB connection error (%s); reconnecting next tick", exc)
            try:
                conn.close()
            except Exception:
                pass
            conn = None
        except Exception as exc:
            log.error("tick error (continuing): %s", exc)

        _sleep(TICK_SECONDS)

        if conn is None and not _STOP:
            try:
                conn = connect()
                pos = ensure_state(conn)
                log.info("reconnected; resumed at cursor %s", _fmt(pos))
            except Exception as rexc:
                log.error("reconnect failed (will retry): %s", rexc)
                _sleep(TICK_SECONDS)

    log.info("exiting; cursor at %s", _fmt(pos))
    try:
        if conn is not None:
            conn.close()
    except Exception:
        pass
    return 0


def _fmt(pos) -> str:
    try:
        return pos.date().isoformat()
    except Exception:
        return str(pos)


def main(argv) -> int:
    if "--rewind" in argv:
        return rewind()
    return run_loop()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
