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

# Preset -> base reveal speed in DEMO-DAYS per REAL-MINUTE. The 365-day year at each
# base: surge ~2 min, stress ~4 min, steady/premium_rising ~6 min, volume_drying ~20
# min. rate_per_min scales this relative to the preset's canonical rate below, so the
# panel's rate override still bends the pace. These are demo-pacing knobs only - they
# reveal frozen rows faster/slower, they never change the data.
PRESET_SPEED_DAYS_PER_MIN = {
    "steady": 60.0,
    "surge": 180.0,
    "stress": 90.0,
    "premium_rising": 60.0,
    "volume_drying": 18.0,
}
# Canonical per-preset rate (mirrors the control API / former generator) - the rate at
# which the mapped base speed applies; other rates scale it proportionally.
PRESET_CANON_RATE = {
    "steady": 2.0, "surge": 6.0, "stress": 4.0, "premium_rising": 2.5, "volume_drying": 0.5,
}
DEFAULT_PRESET = "steady"
RATE_MIN_PER_MIN = 0.1
RATE_MAX_PER_MIN = 30.0

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
    """Create demo_playback_state (idempotent) and seed the single row if absent.
    Seeds to WINDOW_END (full book) so INSTALLING the driver never blanks the board;
    an operator explicitly rewinds to start playback. Returns current_position."""
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS demo_playback_state ("
            " id BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),"
            " current_position TIMESTAMPTZ NOT NULL,"
            " mode TEXT,"
            " updated_at TIMESTAMPTZ NOT NULL DEFAULT now())"
        )
        cur.execute(
            "INSERT INTO demo_playback_state (id, current_position, mode) "
            "VALUES (true, %s, 'full') ON CONFLICT (id) DO NOTHING",
            (WINDOW_END,),
        )
        cur.execute("SELECT current_position FROM demo_playback_state WHERE id")
        pos = cur.fetchone()[0]
    conn.commit()
    return pos


def set_position(conn, pos: datetime, mode: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE demo_playback_state SET current_position = %s, mode = %s, "
            "updated_at = now() WHERE id",
            (pos, mode),
        )
    conn.commit()


# --------------------------------------------------------------------------- #
# Control file (the same local file the agent maintains).
# --------------------------------------------------------------------------- #
def load_control():
    default = {"state": "running", "preset": DEFAULT_PRESET,
               "rate_per_min": PRESET_CANON_RATE[DEFAULT_PRESET]}
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
    preset = raw.get("preset") if raw.get("preset") in PRESET_SPEED_DAYS_PER_MIN else DEFAULT_PRESET
    try:
        rate = float(raw.get("rate_per_min", PRESET_CANON_RATE[preset]))
    except (TypeError, ValueError):
        rate = PRESET_CANON_RATE[preset]
    rate = min(max(rate, RATE_MIN_PER_MIN), RATE_MAX_PER_MIN)
    return {"state": state, "preset": preset, "rate_per_min": rate}


def days_per_second(ctrl) -> float:
    """Reveal speed in demo-days per REAL second from preset + rate scaling."""
    base = PRESET_SPEED_DAYS_PER_MIN.get(ctrl["preset"], PRESET_SPEED_DAYS_PER_MIN[DEFAULT_PRESET])
    canon = PRESET_CANON_RATE.get(ctrl["preset"], 2.0)
    scale = ctrl["rate_per_min"] / canon if canon else 1.0
    return (base * scale) / 60.0


# --------------------------------------------------------------------------- #
# Rewind (one-shot) - reset == rewind, NEVER reprovision.
# --------------------------------------------------------------------------- #
def rewind() -> int:
    conn = connect()
    try:
        ensure_state(conn)
        set_position(conn, REWIND_POSITION, "rewound")
        log.info("REWIND: cursor set to %s (empty board; playback will re-reveal).",
                 REWIND_POSITION.date())
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
    pos = ensure_state(conn)
    log.info("playback driver up: db=%s cursor=%s control_file=%s window=%s..%s",
             EXPECTED_DB, pos.isoformat(), CONTROL_FILE,
             WINDOW_START.date(), WINDOW_END.date())

    last_state = None
    last_preset = None
    last_tick = time.monotonic()
    while not _STOP:
        ctrl = load_control()
        if ctrl["preset"] != last_preset:
            log.info("preset -> %s (%.1f demo-days/real-min base, rate=%.2f)",
                     ctrl["preset"], PRESET_SPEED_DAYS_PER_MIN[ctrl["preset"]], ctrl["rate_per_min"])
            last_preset = ctrl["preset"]

        now = time.monotonic()
        elapsed = now - last_tick
        last_tick = now

        if ctrl["state"] == "paused":
            if last_state != "paused":
                log.info("state -> paused: clock frozen at %s (board holds; nothing written)",
                         _fmt(pos))
            last_state = "paused"
            _sleep(TICK_SECONDS)
            continue
        if last_state != "running":
            log.info("state -> running: revealing from %s", _fmt(pos))
        last_state = "running"

        # Advance the cursor by elapsed real-time * speed, clamped at the window end.
        try:
            if pos < WINDOW_END:
                pos = min(pos + timedelta(days=days_per_second(ctrl) * elapsed), WINDOW_END)
                mode = "full" if pos >= WINDOW_END else "playing"
                set_position(conn, pos, mode)
                if mode == "full":
                    log.info("reached window end -> full book revealed; idling until rewind")
            # else: already full; idle (cursor stays >= end -> exporter serves full book).
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
