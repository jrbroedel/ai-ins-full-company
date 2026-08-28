"""
Canonical 12-month demo dataset generator (ADR 0043, Build 1: generate-and-freeze).

WHAT THIS IS
------------
A DETERMINISTIC, seeded generator that produces the single frozen source of
truth for the investor demo: one 12-month synthetic operating year (~2,400 bound
policies / ~$23M GWP) from which BOTH Kent's Excel deliverables AND the live-demo
replay derive, so they cannot disagree ("generate-once, freeze, derive-
everything" - ADR 0043).

It is a SEPARATE entrypoint from the live preset-driven random generator
(scripts/lib/synthetic_generator.py). It imports NOTHING from that module and
shares no mutable state with it; the live generator is left byte-for-byte
unchanged. This one never runs a loop, never reacts to the control file, and -
critically - performs NO writes to luxauto_demo. Build 1 is generate-and-freeze;
feeding the frozen submissions through the real pipeline (submit_application ->
create_quote) on the demo timeline is the SEPARATE replay build.

WHY IT STILL TOUCHES THE DB (read-only)
---------------------------------------
"Nothing may look fake": premiums must be the REAL rating engine's numbers, not
invented. So at start-up this connects READ-ONLY to luxauto_demo and snapshots
the three rating tables (rating_base_rates, vehicle_category_rating_class,
territory_factors) plus the onboarded-state list, and cross-checks a premium
sample against the live compute_indicative_premium(). Premiums are then computed
in Python with the identical formula
    premium = round(agreed_value / 100 * base_rate * territory_factor / 0.53, 2)
so the dataset is self-contained and reproducible, and every premium traces to
the rater's own base rates and territory factors (recorded in the artifact).

DECLINE RATING (ADR 0043 + approved guardrail)
----------------------------------------------
create_quote() gates on the referral disposition and REFUSES to rate a decline.
Kent wants a "what it would have cost" figure on declines, so we rate declines
through the SAME rating primitive create_quote uses internally
(compute_indicative_premium's formula) - the identical number, just outside the
decline gate. HARD GUARDRAIL: a decline's premium is INDICATIVE only
(is_bound=false, earned_premium=0). Revenue, the BDX, commission income and the
loss ratio use BOUND premium ONLY; a decline contributes a quote figure and zero
earned premium.

TARGET GUARD (non-negotiable)
-----------------------------
Read-only, but still refuses to run unless PGDATABASE == 'luxauto_demo', refuses
if the name is (or resolves to) production 'luxauto', and re-checks the LIVE
current_database() after connecting - matching the live generator's guard.

DETERMINISM
-----------
All randomness flows from a single random.Random(seed). All ids are uuid5 of a
fixed namespace + a running key (never uuid4). No wall-clock value is ever
written into the artifact. The dataset JSON is serialized with sorted keys and
fixed separators, so a given seed produces byte-identical output every run (the
sha256 in the manifest is the determinism check).

Usage (via the wrapper scripts/generate-canonical-dataset.sh, which sets creds):
  python3 canonical_generator.py                       # full year, default seed
  CANON_SEED=20260827 python3 canonical_generator.py   # explicit seed
  CANON_SUBMISSIONS=120 CANON_MONTHS=2 python3 canonical_generator.py --out-dir /tmp/small
  python3 canonical_generator.py --out-dir sample-data/canonical

Env knobs (all optional; defaults produce the ADR 0043 full year):
  CANON_SEED            master seed (default 20260827)
  CANON_SUBMISSIONS     target total submissions (default 3300)
  CANON_MONTHS          number of months (default 12; smaller = scaled test run)
  CANON_START_YM        operating-year start as YYYY-MM (default 2025-08)
  CANON_VALUE_SCALE     global multiplier on agreed values (GWP tuning; default 1.0)
"""
import argparse
import hashlib
import json
import os
import sys
import uuid
from datetime import date, timedelta

import psycopg2

# --------------------------------------------------------------------------- #
# Target guard (read-only variant of the live generator's).
# --------------------------------------------------------------------------- #
EXPECTED_DB = "luxauto_demo"
PROD_DB = "luxauto"

# Fixed namespace for deterministic uuid5 ids (never uuid4). Stable across runs.
CANON_NS = uuid.UUID("6d1f2c9e-0a44-5b77-9c31-canonical0000".replace("canonical", "a1b2c3d4"))

GROSS_UP_DIVISOR = 0.53  # matches compute_indicative_premium (ADR 0028)
AGREED_VALUE_FLOOR = 100_000  # below this the rater declines; we keep declines above it


def guard_target(cur=None) -> None:
    dbname = os.environ.get("PGDATABASE")
    if dbname == PROD_DB:
        raise SystemExit(
            f"REFUSING TO RUN: PGDATABASE is {dbname!r} (production). This job only "
            f"ever targets {EXPECTED_DB!r} (read-only)."
        )
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


def connect_readonly():
    guard_target()
    conn = psycopg2.connect()
    conn.autocommit = True  # read-only; no transaction to manage
    with conn.cursor() as cur:
        guard_target(cur)
        # Belt-and-braces: make the whole session read-only so this can never
        # write, even by mistake.
        cur.execute("SET default_transaction_read_only = on")
    return conn


# --------------------------------------------------------------------------- #
# Rating snapshot (read-only) + Python reimplementation of the rater's formula.
# --------------------------------------------------------------------------- #
def snapshot_rating(conn) -> dict:
    """Pull the three rating tables + onboarded states, read-only. Returns a
    self-contained snapshot embedded in the artifact for provenance."""
    snap = {"gross_up_divisor": GROSS_UP_DIVISOR}
    with conn.cursor() as cur:
        cur.execute(
            "SELECT rating_vehicle_class, rating_class_label, value_band_lower, "
            "value_band_upper, base_rate FROM rating_base_rates "
            "WHERE effective_range @> now() ORDER BY rating_vehicle_class, value_band_lower"
        )
        snap["base_rates"] = [
            {
                "rating_vehicle_class": int(c),
                "rating_class_label": label,
                "value_band_lower": float(lo),
                "value_band_upper": (float(hi) if hi is not None else None),
                "base_rate": float(rate),
            }
            for c, label, lo, hi, rate in cur.fetchall()
        ]
        cur.execute(
            "SELECT vehicle_category, rating_vehicle_class FROM vehicle_category_rating_class "
            "ORDER BY vehicle_category"
        )
        snap["category_rating_class"] = {cat: int(cls) for cat, cls in cur.fetchall()}
        cur.execute(
            "SELECT state, pd_territory_factor FROM territory_factors "
            "WHERE effective_range @> now() AND state <> 'T0' ORDER BY state"
        )
        snap["territory_factors"] = {st.strip(): float(f) for st, f in cur.fetchall()}
        cur.execute(
            "SELECT DISTINCT state FROM state_rating_table_versions "
            "WHERE superseded_by IS NULL AND effective_range @> now() ORDER BY state"
        )
        snap["onboarded_states"] = [r[0].strip() for r in cur.fetchall()]
    return snap


class Rater:
    """Pure-Python reimplementation of compute_indicative_premium, driven by the
    snapshot. Verified against the live SQL function in verification."""

    def __init__(self, snap: dict):
        self.divisor = snap["gross_up_divisor"]
        self.cat_class = snap["category_rating_class"]
        self.terr = snap["territory_factors"]
        # index base rates by class -> list of (lo, hi, rate)
        self.bands = {}
        for row in snap["base_rates"]:
            self.bands.setdefault(row["rating_vehicle_class"], []).append(
                (row["value_band_lower"], row["value_band_upper"], row["base_rate"])
            )

    def base_rate_for(self, cls: int, value: float) -> float:
        for lo, hi, rate in self.bands[cls]:
            if value >= lo and (hi is None or value < hi):
                return rate
        raise ValueError(f"no base rate band for class {cls} at value {value}")

    def indicative_premium(self, category: str, value: float, state: str) -> dict:
        """Returns the indicative premium plus the auditable basis. Raises below
        the floor exactly as the rater does (we never rate below-floor risks)."""
        if value < AGREED_VALUE_FLOOR:
            raise ValueError(f"value {value} below agreed-value floor {AGREED_VALUE_FLOOR}")
        cls = self.cat_class[category]
        base_rate = self.base_rate_for(cls, value)
        terr = self.terr[state]
        base_loss_cost = value / 100 * base_rate
        adjusted = base_loss_cost * terr
        premium = round(adjusted / self.divisor, 2)
        return {
            "model": "indicative_premium_v1",
            "agreed_value": value,
            "rating_vehicle_class": cls,
            "base_rate_per_100": base_rate,
            "territory_state": state,
            "territory_factor": terr,
            "gross_up_divisor": self.divisor,
            "indicative_premium": premium,
        }


# --------------------------------------------------------------------------- #
# Synthetic PII helpers - obviously fake, carrying the demo markers.
# --------------------------------------------------------------------------- #
FIRST_NAMES = [
    "Marisol", "Everett", "Ingrid", "Desmond", "Priya", "Lorenzo", "Beatrix",
    "Callum", "Saoirse", "Thaddeus", "Noor", "Emiliano", "Fenwick", "Ottilie",
    "Ramona", "Cassius", "Delphine", "Horace", "Anouk", "Sunniva", "Leopold",
    "Mireille", "Aurelio", "Wilhelmina", "Fitzgerald",
]
LAST_NAMES = [
    "Ashcombe", "Vandermeer", "Kingsford", "Thistlewood", "Bellandi", "Rourke",
    "Chattopadhyay", "Fairweather", "Montoya", "Blackwood", "Nakashima",
    "Pennington", "Larsson", "Okonkwo", "Delacroix", "Harrington", "Vasquez",
    "Whitlock", "Farkas", "Underwood", "Castellanos", "Merriweather",
]
OCCUPATIONS = [
    "Orthopedic Surgeon", "Retired Executive", "Software Architect", "Cardiologist",
    "Portfolio Manager", "Law Firm Partner", "Anesthesiologist", "Founder / CEO",
]
_VIN_ALPHABET = "ABCDEFGHJKLMNPRSTUVWXYZ0123456789"  # no I/O/Q, matches live gen

# The ten Lloyd's syndicates, 10% each of the 75% market share = 7.5% of premium each
# (ADR 0043). Order fixed for determinism.
SYNDICATES = [
    "Beazley", "Hiscox", "Chaucer", "Ark", "Brit",
    "Canopius", "Apollo", "Antares", "MS Amlin", "Ascot",
]

# Money math constants (ADR 0042 / 0043).
COMMISSION_TOTAL_RATE = 0.25
BROKER_RATE = 0.125
TORQUE_RATE = 0.125
MARKETS_RATE = 0.75
PER_SYNDICATE_RATE = 0.075  # 10% of the 75% = 7.5% of premium, x10 = 75%
POLICY_FEE = 350.0
INSPECTION_FEE = 250.0
INSPECTION_FEE_AV_THRESHOLD = 1_000_000

# Policy-period claim frequency: the share of BOUND policies that incur >=1 loss
# during the year. Deliberately low (garaged HNW collector cars are barely
# driven) AND tuned so the fat-tailed severity distribution lands the aggregate
# loss ratio near target with only a gentle scale (see the scale clamp below).
CLAIM_FREQUENCY = 0.04

# Loss-ratio target (Kent's technical LR) and PC sliding scale (ADR 0043).
TARGET_LOSS_RATIO = 0.56
PC_BANDS = [  # (lr_lower_inclusive, lr_upper_exclusive, pct_of_profit)
    (0.00, 0.40, 30),
    (0.40, 0.45, 25),
    (0.45, 0.50, 20),
    (0.50, 0.55, 15),
    (0.55, 0.60, 10),
    (0.60, 9.99, 0),
]


def pc_band_for(lr: float) -> int:
    for lo, hi, pct in PC_BANDS:
        if lo <= lr < hi:
            return pct
    return 0


# --------------------------------------------------------------------------- #
# Vehicle category + agreed-value distribution (HNW collector book).
# Median agreed value per category; a seeded lognormal spread around it, clamped
# to [floor, 2M] so every risk is within the CP-02 $2M authority and quotable.
# --------------------------------------------------------------------------- #
CATEGORY_MIX = [  # (category, weight, median_value, sigma, sample vehicles)
    ("production_luxury", 60, 280_000, 0.55,
     [("Porsche", "911 Turbo S"), ("Mercedes-Benz", "AMG GT"), ("BMW", "M8 Competition"),
      ("Aston Martin", "DB12"), ("Bentley", "Continental GT"), ("Maserati", "GranTurismo")]),
    ("exotic", 20, 430_000, 0.60,
     [("Lamborghini", "Huracan EVO"), ("Ferrari", "296 GTB"), ("McLaren", "750S"),
      ("Ferrari", "SF90 Stradale")]),
    ("classic_collector", 13, 360_000, 0.65,
     [("Ferrari", "275 GTB/4"), ("Jaguar", "E-Type Series 1"), ("Aston Martin", "DB5"),
      ("Mercedes-Benz", "280SL Pagoda")]),
    ("restomod_coachbuilt", 4, 320_000, 0.55,
     [("Singer", "911 Reimagined"), ("Icon", "Derelict"), ("Ringbrothers", "Mustang")]),
    ("pre_war_vintage", 3, 520_000, 0.60,
     [("Bugatti", "Type 57"), ("Alfa Romeo", "8C 2900"), ("Bentley", "4.5 Litre")]),
]
VALUE_CLAMP_MIN = 105_000  # just above the floor so declines still carry an indicative premium
VALUE_CLAMP_MAX = 1_950_000  # below the $2M CP-02 authority cap

# Populous-state boost so the national map skews plausibly (same spirit as the
# live generator's POPULOUS_BOOST).
POPULOUS_BOOST = {"CA": 4, "NY": 3, "TX": 3, "FL": 3, "IL": 2, "PA": 2, "OH": 2,
                  "MI": 2, "MA": 2, "NJ": 2, "WA": 2, "CO": 2}


# --------------------------------------------------------------------------- #
# Loss-run patterns -> disposition (Kent's Claims History factor table, ADR 0043).
# The disposition is DERIVED from the loss run, never imposed. Weighted to land
# the annual ~72% bind / ~20% decline / ~8% refer mix.
#
#   PREFERRED   no prior claims                         -> bind
#   ACCEPTABLE  1 claim <$100k, comprehensive/not-fault -> bind
#   REFER       1 claim >$100k | theft-total | 2 claims | prior non-renewal -> refer
#   DECLINE     3+ at-fault claims                       -> decline
# --------------------------------------------------------------------------- #
# (pattern_key, disposition, annual_weight)
# Weights honor BOTH ADR 0043 anchors at once: ~72% clean loss runs AND a ~72/
# 20/8 bind/decline/refer mix. Clean (no prior claims) is the bulk of the bind
# bucket at 70%; the small Acceptable tier (1 benign comp claim <$100k) keeps
# that rule alive for texture without pushing "clean" below ~72%. "The rest carry
# prior claims" (ADR record-4) = the decline + refer patterns (28%).
LOSS_RUN_PATTERNS = [
    ("clean",            "bind",    70),   # no prior claims -> Preferred
    ("minor_comp",       "bind",     2),   # 1 comp claim <$100k -> Acceptable
    ("one_large",        "refer",    2),   # 1 claim >$100k
    ("theft_total",      "refer",    2),   # theft / total loss
    ("two_claims",       "refer",    2),   # 2 prior claims
    ("prior_nonrenewal", "refer",    2),   # prior carrier non-renewal
    ("three_plus_fault", "decline", 20),   # 3+ at-fault claims -> Decline
]
# bind = 70 + 2 = 72; refer = 2+2+2+2 = 8; decline = 20  -> 72/20/8 exactly.
# clean loss runs ~= 70% (~72% with the tilde), Acceptable ~2%.


def years_ago(rng, min_y, max_y):
    days = int(rng.uniform(min_y, max_y) * 365.25)
    return days


def build_loss_run(rng, pattern: str, ref_date: date) -> dict:
    """Materialize a synthetic loss run (PRIOR claims, backward-looking) that
    genuinely matches its pattern - this causality is the anti-fake mechanism."""
    def prior(days_min, days_max, ctype, at_fault, amt_lo, amt_hi, desc):
        d = ref_date - timedelta(days=years_ago(rng, days_min, days_max))
        return {
            "claim_date": d.isoformat(),
            "claim_type": ctype,
            "at_fault": at_fault,
            "paid_amount": rng.randint(amt_lo, amt_hi),
            "description": desc,
        }

    claims = []
    prior_nonrenewal = False
    if pattern == "clean":
        pass
    elif pattern == "minor_comp":
        claims = [prior(0.5, 4.5, "comprehensive", False, 3_000, 90_000,
                        "Minor comprehensive claim (not at fault)")]
    elif pattern == "one_large":
        claims = [prior(0.5, 4.5, "collision", False, 105_000, 280_000,
                        "Single large loss over $100k")]
    elif pattern == "theft_total":
        claims = [prior(0.5, 4.5, "theft", False, 180_000, 650_000,
                        "Theft / total loss")]
    elif pattern == "two_claims":
        claims = [
            prior(0.5, 2.5, "collision", rng.random() < 0.5, 8_000, 60_000, "Prior claim 1"),
            prior(2.5, 4.8, "comprehensive", False, 4_000, 45_000, "Prior claim 2"),
        ]
    elif pattern == "prior_nonrenewal":
        prior_nonrenewal = True
        # may carry a modest claim too, but the non-renewal is the referring fact
        if rng.random() < 0.5:
            claims = [prior(0.5, 4.5, "collision", False, 6_000, 70_000, "Prior claim")]
    elif pattern == "three_plus_fault":
        n = rng.choice([3, 3, 4])  # 3+ at-fault
        for i in range(n):
            claims.append(prior(0.4, 4.8, "collision", True, 7_000, 45_000,
                                 f"At-fault collision #{i + 1}"))
    else:
        raise ValueError(f"unknown loss-run pattern {pattern}")

    at_fault_count = sum(1 for c in claims if c["at_fault"])
    over_100k = sum(1 for c in claims if c["paid_amount"] > 100_000)
    return {
        "pattern": pattern,
        "lookback_years": 5,
        "prior_carrier_nonrenewal": prior_nonrenewal,
        "claim_count": len(claims),
        "at_fault_count": at_fault_count,
        "claims_over_100k": over_100k,
        "claims": claims,
    }


# --------------------------------------------------------------------------- #
# Deterministic id + date helpers.
# --------------------------------------------------------------------------- #
def det_id(kind: str, seq) -> str:
    return str(uuid.uuid5(CANON_NS, f"{kind}:{seq}"))


def month_start(start_ym: tuple, m_index: int) -> date:
    y, mo = start_ym
    mo0 = (mo - 1) + m_index
    return date(y + mo0 // 12, (mo0 % 12) + 1, 1)


def month_days(d: date) -> int:
    nxt = date(d.year + (1 if d.month == 12 else 0), (d.month % 12) + 1, 1)
    return (nxt - d).days


# --------------------------------------------------------------------------- #
# The generation model.
# --------------------------------------------------------------------------- #
def weighted_choice(rng, items_weights):
    items, weights = zip(*items_weights)
    return rng.choices(items, weights=weights, k=1)[0]


def pick_state(rng, states):
    weights = [POPULOUS_BOOST.get(s, 1) for s in states]
    return rng.choices(states, weights=weights, k=1)[0]


def draw_agreed_value(rng, median, sigma, value_scale):
    # lognormal around the median, clamped into the bindable/rateable window.
    import math
    v = median * math.exp(rng.gauss(0.0, sigma))
    v *= value_scale
    v = max(VALUE_CLAMP_MIN, min(VALUE_CLAMP_MAX, v))
    # round to a tidy appraisal-looking figure
    return int(round(v / 5000.0) * 5000)


def monthly_submission_counts(rng, total, months):
    """Distribute `total` submissions across `months` with a gentle upward ramp
    (established-and-scaling) plus seeded wobble. Sums EXACTLY to total."""
    # base ramp weight 1.0 -> ~1.6 across the year, times per-month noise
    weights = []
    for m in range(months):
        ramp = 1.0 + 0.6 * (m / max(1, months - 1))
        noise = rng.uniform(0.85, 1.15)
        weights.append(ramp * noise)
    s = sum(weights)
    raw = [total * w / s for w in weights]
    counts = [int(round(x)) for x in raw]
    # fix rounding drift so it sums exactly to total
    drift = total - sum(counts)
    i = 0
    while drift != 0:
        counts[i % months] += 1 if drift > 0 else -1
        drift += -1 if drift > 0 else 1
        i += 1
    return counts


def softening_index(rng, months):
    """Market-rate softening: a modeled index falling ~25% month 1 -> month 12
    with monthly noise, so the rate-trend graph reads as clearly-falling but not
    artificially smooth. Layered ON TOP of the real rater; recorded per month in
    the artifact (transparent). Month 0 == 1.0 (the anchor)."""
    idx = []
    drop = 0.25
    for m in range(months):
        base = 1.0 - drop * (m / max(1, months - 1))
        noise = 0.0 if m == 0 else rng.uniform(-0.02, 0.02)
        idx.append(round(max(0.5, base + noise), 4))
    return idx


def money_split(bound_premium: float, agreed_value: float) -> dict:
    """ADR 0042/0043 money math on a BOUND premium P. Modeled the workbook way:
    full 25% is commission income; broker's 12.5% is a distribution expense; 75%
    to the markets, split 10% each (7.5% of P) across the ten syndicates. Fees
    added as fee income."""
    p = bound_premium
    # broker + torque tie EXACTLY to commission_total (no independent-rounding
    # gap), and the ten equal syndicate shares tie EXACTLY to markets_total, so
    # the BDX subdivision reconciles line-for-line (the whole point of ADR 0043).
    broker = round(p * BROKER_RATE, 2)
    torque = round(p * TORQUE_RATE, 2)
    commission_total = round(broker + torque, 2)
    per_syndicate = round(p * PER_SYNDICATE_RATE, 2)
    markets_total = round(per_syndicate * len(SYNDICATES), 2)
    inspection = INSPECTION_FEE if agreed_value >= INSPECTION_FEE_AV_THRESHOLD else 0.0
    return {
        "bound_premium": p,
        "commission_total": commission_total,
        "commission_broker": broker,
        "commission_torque": torque,
        "markets_total": markets_total,
        "syndicate_shares": {name: per_syndicate for name in SYNDICATES},
        "policy_fee": POLICY_FEE,
        "inspection_fee": inspection,
        "fee_income_total": round(POLICY_FEE + inspection, 2),
    }


def generate(seed, total_submissions, months, start_ym, value_scale, rating_snapshot):
    rng = __import__("random").Random(seed)
    rater = Rater(rating_snapshot)
    states = rating_snapshot["onboarded_states"]

    counts = monthly_submission_counts(rng, total_submissions, months)
    soft = softening_index(rng, months)

    submissions = []
    policy_period_claims = []  # filled after we know the bound book (LR targeting)
    monthly = []
    seq = 0

    for m in range(months):
        m0 = month_start(start_ym, m)
        ndays = month_days(m0)
        month_binds = 0
        month_declines = 0
        month_refers = 0
        month_gwp = 0.0
        month_bound_prem_list = []
        for _ in range(counts[m]):
            seq += 1
            # ----- disposition derived from the loss run -----
            pattern = weighted_choice(rng, [(p, w) for p, _, w in LOSS_RUN_PATTERNS])
            disposition = next(d for p, d, _ in LOSS_RUN_PATTERNS if p == pattern)
            day = rng.randint(0, ndays - 1)
            submitted_at = m0 + timedelta(days=day)
            loss_run = build_loss_run(rng, pattern, submitted_at)

            # ----- vehicle + agreed value -----
            cat, _w, median, sigma, vehicles = weighted_choice(
                rng, [(row, row[1]) for row in CATEGORY_MIX]
            )
            make, model = rng.choice(vehicles)
            agreed_value = draw_agreed_value(rng, median, sigma, value_scale)
            state = pick_state(rng, states)

            # ----- rate EVERY submission (bind AND decline) via the real formula -----
            basis = rater.indicative_premium(cat, agreed_value, state)
            base_premium = basis["indicative_premium"]
            month_soft = soft[m]
            final_premium = round(base_premium * month_soft, 2)

            is_bound = disposition == "bind"
            quote = {
                "quote_id": det_id("quote", seq),
                "rating_basis": basis,
                "base_premium": base_premium,
                "softening_index": month_soft,
                "premium": final_premium,
                # GUARDRAIL: only a bound quote is earned premium. Declines and
                # refers carry an INDICATIVE "what it would have cost" figure with
                # earned_premium=0 and is_bound=false - never counted as actuals.
                "is_bound": is_bound,
                "premium_kind": "bound" if is_bound else "indicative",
                "earned_premium": final_premium if is_bound else 0.0,
            }

            policy = None
            if is_bound:
                policy_id = det_id("policy", seq)
                policy = {
                    "policy_id": policy_id,
                    "policy_number": f"CANON-{m0.year}{m0.month:02d}-{seq:06d}",
                    "effective_date": submitted_at.isoformat(),
                    "bound_premium": final_premium,
                    "money": money_split(final_premium, agreed_value),
                }
                month_binds += 1
                month_gwp += final_premium
                month_bound_prem_list.append((policy_id, submitted_at, final_premium, agreed_value))
            elif disposition == "decline":
                month_declines += 1
            else:
                month_refers += 1

            submissions.append({
                "submission_id": det_id("submission", seq),
                "seq": seq,
                "submitted_at": submitted_at.isoformat(),
                "month_index": m,
                "garaging_state": state,
                "applicant": {
                    "first_name": rng.choice(FIRST_NAMES),
                    "last_name": rng.choice(LAST_NAMES),
                    "email": f"canon.{seq}@example.com",
                    "occupation": rng.choice(OCCUPATIONS),
                },
                "vehicle": {
                    "make": make,
                    "model": model,
                    "year": rng.randint(1955, 2024),
                    "vehicle_category": cat,
                    "vin": "".join(rng.choice(_VIN_ALPHABET) for _ in range(17)),
                    "agreed_value": agreed_value,
                },
                "loss_run": loss_run,
                "disposition": disposition,
                "quote": quote,
                "policy": policy,
            })

        n_sub = counts[m]
        monthly.append({
            "month_index": m,
            "month": m0.isoformat()[:7],
            "submissions": n_sub,
            "binds": month_binds,
            "declines": month_declines,
            "refers": month_refers,
            "bind_pct": round(100 * month_binds / n_sub, 2) if n_sub else 0.0,
            "decline_pct": round(100 * month_declines / n_sub, 2) if n_sub else 0.0,
            "refer_pct": round(100 * month_refers / n_sub, 2) if n_sub else 0.0,
            "softening_index": soft[m],
            "gwp": round(month_gwp, 2),
            "avg_bound_premium": round(month_gwp / month_binds, 2) if month_binds else 0.0,
            "_bound_list": month_bound_prem_list,  # transient, removed below
        })

    # ----------------------------------------------------------------------- #
    # Policy-period claims (forward-looking, on the BOUND book only), sized so
    # aggregate loss ratio lands ~0.56. Generate raw heavy-tailed severities,
    # then apply one bounded global scale to hit the target LR precisely while
    # preserving relative texture (the large/near-$1M losses stay large).
    # ----------------------------------------------------------------------- #
    all_bound = []
    for mo in monthly:
        all_bound.extend(mo["_bound_list"])
    total_bound_premium = sum(p for _, _, p, _ in all_bound)

    raw_claims = []
    for policy_id, eff_date, premium, agreed_value in all_bound:
        # low frequency (realistic for barely-driven garaged HNW collector cars).
        # Deliberately low so a genuinely fat-tailed severity distribution (with
        # rare near-$1M+ losses) lands the aggregate LR near target NATURALLY -
        # the gentle global scale below then only fine-tunes, so the tail is
        # preserved rather than crushed.
        if rng.random() < CLAIM_FREQUENCY:
            n = 1 if rng.random() < 0.88 else 2
            for _k in range(n):
                r = rng.random()
                if r < 0.68:
                    sev = rng.uniform(5_000, 40_000)       # small
                elif r < 0.90:
                    sev = rng.uniform(40_000, 200_000)     # moderate
                elif r < 0.965:
                    sev = rng.uniform(200_000, 600_000)    # large
                elif r < 0.99:
                    sev = rng.uniform(600_000, 1_200_000)  # major
                else:
                    sev = rng.uniform(1_200_000, 2_000_000)  # rare catastrophic (near-$1M+ post-scale)
                # a loss cannot exceed the agreed value of the car it is on
                sev = min(sev, float(agreed_value))
                # date of loss within the policy year, after inception
                dol = eff_date + timedelta(days=rng.randint(5, 330))
                raw_claims.append([policy_id, dol.isoformat(), sev])

    raw_incurred = sum(c[2] for c in raw_claims)
    target_incurred = TARGET_LOSS_RATIO * total_bound_premium
    scale = (target_incurred / raw_incurred) if raw_incurred > 0 else 1.0
    # Tight clamp: the frequency is tuned so raw LR is already ~target, so the
    # scale should sit near 1.0 and the fat tail is preserved. A scale that would
    # need to leave this band signals a mis-tuned frequency (fail loud rather than
    # silently distort the tail or miss the LR target).
    if not (0.75 <= scale <= 1.35):
        raise SystemExit(
            f"LR-SCALE OUT OF BAND: scale={scale:.3f} (raw_incurred=${raw_incurred:,.0f}, "
            f"target=${target_incurred:,.0f}). Re-tune CLAIM_FREQUENCY so raw LR is near target."
        )

    total_incurred = 0.0
    for i, (policy_id, dol, sev) in enumerate(raw_claims, start=1):
        incurred = round(sev * scale, 2)
        total_incurred += incurred
        policy_period_claims.append({
            "claim_id": det_id("ppclaim", i),
            "policy_id": policy_id,
            "date_of_loss": dol,
            "incurred": incurred,
            "status": rng.choice(["open", "closed", "closed", "closed"]),
        })

    loss_ratio = round(total_incurred / total_bound_premium, 4) if total_bound_premium else 0.0

    # cumulative loss ratio month over month (incurred by loss-month / cumulative
    # bound premium) - a monotone-ish curve that settles near the target.
    incurred_by_month = {}
    for c in policy_period_claims:
        ym = c["date_of_loss"][:7]
        incurred_by_month[ym] = incurred_by_month.get(ym, 0.0) + c["incurred"]
    cum_prem = 0.0
    cum_inc = 0.0
    for mo in monthly:
        cum_prem += mo["gwp"]
        cum_inc += incurred_by_month.get(mo["month"], 0.0)
        mo["cumulative_loss_ratio"] = round(cum_inc / cum_prem, 4) if cum_prem else 0.0
        del mo["_bound_list"]  # drop transient field before freezing

    # ----------------------------------------------------------------------- #
    # Summary + commission/fee rollups (BOUND book only).
    # ----------------------------------------------------------------------- #
    n_sub = len(submissions)
    n_bind = sum(1 for s in submissions if s["disposition"] == "bind")
    n_decline = sum(1 for s in submissions if s["disposition"] == "decline")
    n_refer = sum(1 for s in submissions if s["disposition"] == "refer")
    gwp = round(sum(s["policy"]["bound_premium"] for s in submissions if s["policy"]), 2)
    commission_income = round(gwp * COMMISSION_TOTAL_RATE, 2)
    broker_expense = round(gwp * BROKER_RATE, 2)
    fee_income = round(
        sum(s["policy"]["money"]["fee_income_total"] for s in submissions if s["policy"]), 2
    )
    per_syndicate_total = round(gwp * PER_SYNDICATE_RATE, 2)

    summary = {
        "submissions": n_sub,
        "binds": n_bind,
        "declines": n_decline,
        "refers": n_refer,
        "bind_pct": round(100 * n_bind / n_sub, 2) if n_sub else 0.0,
        "decline_pct": round(100 * n_decline / n_sub, 2) if n_sub else 0.0,
        "refer_pct": round(100 * n_refer / n_sub, 2) if n_sub else 0.0,
        "gwp_bound": gwp,
        "avg_bound_premium": round(gwp / n_bind, 2) if n_bind else 0.0,
        "commission_income_25pct": commission_income,
        "broker_distribution_expense_12_5pct": broker_expense,
        "markets_total_75pct": round(gwp * MARKETS_RATE, 2),
        "per_syndicate_total_7_5pct": per_syndicate_total,
        "syndicate_count": len(SYNDICATES),
        "fee_income_total": fee_income,
        "policy_period_claim_count": len(policy_period_claims),
        "total_incurred_losses": round(total_incurred, 2),
        "loss_ratio": loss_ratio,
        "loss_ratio_target": TARGET_LOSS_RATIO,
        "pc_band_pct": pc_band_for(loss_ratio),
        "indicative_only_quotes": n_decline + n_refer,
        "earned_premium_from_non_bound": 0.0,  # guardrail invariant
    }

    return {
        "submissions": submissions,
        "policy_period_claims": policy_period_claims,
        "monthly_aggregates": monthly,
        "summary": summary,
    }


# --------------------------------------------------------------------------- #
# Serialization - canonical (sorted keys, fixed separators) so a seed -> bytes
# is stable. No wall-clock anywhere in the artifact.
# --------------------------------------------------------------------------- #
def canonical_json(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def main(argv) -> int:
    ap = argparse.ArgumentParser(description="Canonical 12-month demo dataset generator (ADR 0043).")
    ap.add_argument("--out-dir", default=os.environ.get("CANON_OUT_DIR", "sample-data/canonical"))
    args = ap.parse_args(argv)

    seed = int(os.environ.get("CANON_SEED", "20260827"))
    total = int(os.environ.get("CANON_SUBMISSIONS", "3300"))
    months = int(os.environ.get("CANON_MONTHS", "12"))
    # Default tuned so the full year lands ~$23M GWP / ~$9,500 avg bound premium
    # (ADR 0043 book size), given the rater's base rates + territory factors and
    # the modeled softening trend. Override for scaled test runs.
    value_scale = float(os.environ.get("CANON_VALUE_SCALE", "1.90"))
    start_ym_raw = os.environ.get("CANON_START_YM", "2025-08")
    sy, sm = start_ym_raw.split("-")
    start_ym = (int(sy), int(sm))

    conn = connect_readonly()
    try:
        snap = snapshot_rating(conn)
        # Cross-check: our Python rater must match the live SQL rater on a sample.
        _crosscheck_rater(conn, snap)
    finally:
        conn.close()

    dataset = generate(seed, total, months, start_ym, value_scale, snap)

    artifact = {
        "schema_version": "canonical-dataset-v1",
        "adr": "0043",
        "generator": "scripts/lib/canonical_generator.py",
        "seed": seed,
        "operating_year_start": f"{start_ym[0]:04d}-{start_ym[1]:02d}",
        "months": months,
        "parameters": {
            "target_submissions": total,
            "value_scale": value_scale,
            "target_loss_ratio": TARGET_LOSS_RATIO,
            "commission_total_rate": COMMISSION_TOTAL_RATE,
            "markets_rate": MARKETS_RATE,
            "per_syndicate_rate": PER_SYNDICATE_RATE,
            "syndicates": SYNDICATES,
        },
        "rating_snapshot": snap,
        "submissions": dataset["submissions"],
        "policy_period_claims": dataset["policy_period_claims"],
        "monthly_aggregates": dataset["monthly_aggregates"],
        "summary": dataset["summary"],
    }

    body = canonical_json(artifact)
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()

    manifest = {
        "schema_version": "canonical-manifest-v1",
        "adr": "0043",
        "seed": seed,
        "months": months,
        "operating_year_start": f"{start_ym[0]:04d}-{start_ym[1]:02d}",
        "dataset_file": "canonical_dataset.json",
        "dataset_sha256": digest,
        "summary": dataset["summary"],
    }

    os.makedirs(args.out_dir, exist_ok=True)
    ds_path = os.path.join(args.out_dir, "canonical_dataset.json")
    mf_path = os.path.join(args.out_dir, "canonical_manifest.json")
    with open(ds_path, "w", encoding="utf-8") as f:
        f.write(body)
    with open(mf_path, "w", encoding="utf-8") as f:
        f.write(canonical_json(manifest))

    s = dataset["summary"]
    print(f"canonical dataset written: {ds_path}")
    print(f"  sha256={digest}")
    print(f"  submissions={s['submissions']} binds={s['binds']} declines={s['declines']} "
          f"refers={s['refers']} ({s['bind_pct']}/{s['decline_pct']}/{s['refer_pct']})")
    print(f"  GWP(bound)=${s['gwp_bound']:,.2f} avg_bound_premium=${s['avg_bound_premium']:,.2f}")
    print(f"  loss_ratio={s['loss_ratio']} (target {s['loss_ratio_target']}) "
          f"PC band={s['pc_band_pct']}%")
    print(f"  indicative-only quotes(decline+refer)={s['indicative_only_quotes']} "
          f"earned_from_non_bound={s['earned_premium_from_non_bound']}")
    return 0


def _crosscheck_rater(conn, snap):
    """Assert the Python rater reproduces the live compute_indicative_premium on
    a representative sample. Fails loud on any mismatch (drift guard)."""
    rater = Rater(snap)
    states = snap["onboarded_states"]
    samples = [
        ("production_luxury", 150_000, states[0]),
        ("production_luxury", 300_000, "TX" if "TX" in states else states[1]),
        ("exotic", 350_000, "FL" if "FL" in states else states[2]),
        ("exotic", 700_000, "CA" if "CA" in states else states[0]),
        ("classic_collector", 900_000, "NY" if "NY" in states else states[-1]),
    ]
    with conn.cursor() as cur:
        for cat, val, st in samples:
            cur.execute(
                "SELECT (compute_indicative_premium(%s::vehicle_category_t, %s::numeric, %s::char(2))).indicative_premium",
                (cat, val, st),
            )
            db_prem = float(cur.fetchone()[0])
            py_prem = rater.indicative_premium(cat, val, st)["indicative_premium"]
            if abs(db_prem - py_prem) > 0.01:
                raise SystemExit(
                    f"RATER DRIFT: {cat}/{val}/{st} db={db_prem} python={py_prem} - refusing to "
                    f"generate an artifact whose premiums disagree with the live rater."
                )
    print(f"rater cross-check OK: python rater matches compute_indicative_premium on "
          f"{len(samples)} samples")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
