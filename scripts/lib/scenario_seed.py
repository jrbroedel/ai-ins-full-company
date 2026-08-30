"""
Scenario engine seed (ADR 0048) — the single, rebuild-safe source of the five
committed demo scenarios.

A scenario is a named row in `scenario_defs` controlling PACE (how the playback
driver advances the ADR 0047 cursor) + an optional generic OVERLAY (per-metric
per-month multipliers the exporter applies to displayed magnitudes at build time).
Reveal is ALWAYS chronological by submitted_at — a scenario changes pace + magnitude
only, never reorders.

  scenario_defs(name TEXT PK, pace JSONB, overlay JSONB, is_modeled BOOL, label TEXT,
                updated_at TIMESTAMPTZ)
    pace    : driver reads   - {"speed_scale":1.0,"mode":"linear"} |
              {"mode":"taper","late_factor":0.3}
    overlay : exporter reads - {"premium":[12],"loss":[12],"volume":[12]}; absent
              metric/month = 1.0; NULL/{} = pure pace (foots to the artifact).
    is_modeled: true iff overlay is non-identity -> drives the board's modeled marker.

SEED MODEL (a known, intended property): the five presets live HERE, in committed
code, so a DB rebuild recreates them. A scenario added later via a bare INSERT into
the running luxauto_demo lives ONLY in the demo DB and is NOT in git - a rebuild
recreates only these five unless this seed is updated. That is the data-driven /
no-deploy tradeoff by design.

This module is the WRITER's helper (the driver ensures + seeds it). The exporter only
READS scenario_defs, guarded, and treats its absence as "no overlay" (identity).
"""

# Per-month overlay factors (12 = the operating year 2025-08 .. 2026-07, index 0..11).
# premium_rising: the displayed rate/price firms up over the year (a PRICE line, not
# more-expensive cars) -> avg premium + GWP rise, and loss ratio eases (denominator up).
PREMIUM_RAMP = [1.00, 1.02, 1.05, 1.08, 1.10, 1.12, 1.15, 1.17, 1.20, 1.22, 1.24, 1.25]
# stress: incurred losses spike through the year -> loss ratio bends up (numerator up).
LOSS_SPIKE = [1.00, 1.10, 1.20, 1.35, 1.50, 1.65, 1.80, 1.95, 2.10, 2.25, 2.40, 2.50]

# (name, pace, overlay|None, is_modeled, label)
SEED_SCENARIOS = [
    ("steady",
     {"speed_scale": 1.0, "mode": "linear"}, None, False,
     "Steady state"),
    ("surge",
     {"speed_scale": 3.0, "mode": "linear"}, None, False,
     "Surge (fast reveal)"),
    ("volume_drying",
     {"speed_scale": 1.0, "mode": "taper", "late_factor": 0.3}, None, False,
     "Volume drying up"),
    ("premium_rising",
     {"speed_scale": 1.0, "mode": "linear"}, {"premium": PREMIUM_RAMP}, True,
     "Premium rising"),
    ("stress",
     {"speed_scale": 1.0, "mode": "linear"}, {"loss": LOSS_SPIKE}, True,
     "Stress (loss spike)"),
]

SCENARIO_DEFS_DDL = """
CREATE TABLE IF NOT EXISTS scenario_defs (
  name        TEXT PRIMARY KEY,
  pace        JSONB NOT NULL DEFAULT '{}'::jsonb,
  overlay     JSONB,
  is_modeled  BOOLEAN NOT NULL DEFAULT false,
  label       TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
)
"""


def ensure_scenarios(conn) -> None:
    """Create scenario_defs (idempotent) and seed the five committed scenarios.
    ON CONFLICT DO NOTHING: a scenario added/edited in the running DB is NOT clobbered
    by a later driver restart; only missing seed rows are (re)created. Rebuild-safe."""
    import json
    with conn.cursor() as cur:
        cur.execute(SCENARIO_DEFS_DDL)
        for name, pace, overlay, is_modeled, label in SEED_SCENARIOS:
            cur.execute(
                "INSERT INTO scenario_defs (name, pace, overlay, is_modeled, label) "
                "VALUES (%s, %s::jsonb, %s::jsonb, %s, %s) "
                "ON CONFLICT (name) DO NOTHING",
                (name, json.dumps(pace),
                 (json.dumps(overlay) if overlay is not None else None),
                 is_modeled, label),
            )
    conn.commit()
