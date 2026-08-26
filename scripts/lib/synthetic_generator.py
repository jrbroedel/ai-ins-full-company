"""
Autonomous synthetic-application generator for the investor demo (demo only).

WHAT THIS IS
------------
A long-lived loop that, on a modest cadence, materializes a synthetic luxury-auto
application and drives it through the REAL luxauto_demo pipeline:

    build the draft application graph (applicant + application + vehicle + the
    enrichment-shaped inputs a profile needs)  ->  submit_application()  ->
    (for a cleared app) create_quote()

Every disposition, decision_log row and quote is produced by the real SECURITY
DEFINER functions evaluating the input data - nothing about the outcome is
fabricated. The generator only supplies INPUT (a DUI in the violation history, a
salvage/sanctions flag, an authority-exceeding value); the referral rules decide
what happens. This is the same honest "simulated input" the dashboard marks with
enrichment_simulated=true.

WHAT THIS IS NOT
----------------
  - It is NOT a writer of decision_log / quotes / dashboard events. Those rows
    appear only as a side effect of the real RPCs. The generator never INSERTs
    into decision_log or quotes, and never UPDATEs applications.status by hand.
  - It stands up NO fake enrichment service. sanctions_screen_result etc. are
    seeded as input columns exactly as the demo seed does; the real (placeholder)
    PC-02 rule reads them.

TARGET GUARD (non-negotiable)
-----------------------------
This job writes, so pointing it at production would be irreversible. It refuses
to run unless PGDATABASE == 'luxauto_demo', refuses if the target name is (or
resolves to) production 'luxauto', and re-checks the LIVE current_database()
after connecting - a belt-and-braces guard matching the read-only exporter's.

CREDENTIALS (reused VM pattern, nothing hardcoded)
--------------------------------------------------
The wrapper (scripts/synthetic-generator.sh) sources scripts/lib/
fetch-pg-credentials.sh - the same managed-identity -> IMDS -> Key Vault path the
exporter and every other admin job on this box use - and exports
PGHOST/PGUSER/PGPASSWORD/PGSSLMODE plus PGDATABASE=luxauto_demo. psycopg2 reads
those from the environment; no secret is passed on a command line.

RESET / REPROVISION - two commands, both never automatic
---------------------------------------------------------
luxauto_demo's decision_log is APPEND-ONLY (BEFORE DELETE/UPDATE triggers reject
any mutation, with no bypass flag), and applications.application_id cascades into
it - so a submitted application can never be row-deleted. A "scoped delete of
synthetic rows" is therefore architecturally impossible without disabling the
audit trigger, which this project forbids. Hence two commands:

  --reset                Non-destructive STATUS report only. Prints synthetic
                         (marker/prefix) vs curated (seed) counts. Deletes nothing.

  --reprovision --yes    The one destructive path, deliberately behind its own
                         flag so it can never be the default. It returns the book
                         to known-good the only faithful way an append-only DB
                         allows: a full re-provision of luxauto_demo using the
                         EXISTING sanctioned scripts, verbatim -
                           DROP SCHEMA public CASCADE; CREATE SCHEMA public;
                           -> scripts/apply-and-verify-schema.sh   (schema + verify)
                           -> sample-data/demo/onboard_demo_states.sql
                           -> sample-data/demo/onboard_demo_states_tier_bc.sql
                           -> sample-data/demo/seed_demo_applications.sql
                         then VERIFIES: schema applied, 50 states re-onboarded,
                         curated book exactly 5 applicants / 5 applications /
                         0 quotes, decision_log repopulated by the seed - failing
                         loudly otherwise. It authors NO new DDL (the DROP/CREATE
                         SCHEMA is the documented clear step, ADR 0008), never
                         disables an audit trigger, never uses
                         session_replication_role, and touches only luxauto_demo
                         (guarded immediately before the DROP).

SUPERVISION (systemd) - staged, not installed
---------------------------------------------
A sketch unit lives at infra/systemd/luxauto-synthetic-generator.service
(long-lived Service, Restart=always, User=azureuser), mirroring the exporter's.
It is intentionally NOT installed/enabled. Run this by hand first.

Usage:
  scripts/synthetic-generator.sh                        # continuous generation loop
  GEN_MAX_APPS=5 scripts/synthetic-generator.sh         # generate 5 then exit (testing)
  scripts/synthetic-generator.sh --reset                # non-destructive status report
  scripts/synthetic-generator.sh --reprovision --yes    # destructive full rebuild

LIVE CONTROL (operator control panel)
-------------------------------------
The loop reads a small JSON control file at the START of each cycle:
    { "state": "running"|"paused", "preset": "<name>", "rate_per_min": <number> }
Five named presets (steady, surge, stress, premium_rising, volume_drying) bias
the SAME real profile builders + set the rate; premium_rising also scales clean
appraised values up so NEW quotes read richer. Every change is additive and
forward-only - it only alters the character/cadence of NEW apps, never touching
or deleting existing rows. "paused" idles the process (no new apps, stays alive).
A missing/invalid file falls back to steady/running, so a bare hand-run behaves
exactly as before. The file is written by the VM control agent (see control-swa/).

Env overrides (all optional):
  GEN_CONTROL_FILE       path to the live control file (default
                         /home/azureuser/demo-control/generator-control.json)
  GEN_INTERVAL_SECONDS   legacy cadence base (superseded by the control file's
                         rate_per_min when a control file is present)
  GEN_INTERVAL_JITTER    +/- jitter seconds cap around the paced base (default 12)
  GEN_MAX_APPS           stop after N applications (default 0 = run forever)
  GEN_PERFORMED_BY       decided_by / quoted_by label (default 'synthetic-generator')
"""
import json
import logging
import os
import random
import signal
import string
import subprocess
import sys
import uuid
from datetime import date, datetime, timedelta, timezone

import psycopg2

# --------------------------------------------------------------------------- #
# Configuration - named constants, trivially tunable.
# --------------------------------------------------------------------------- #
# Modest cadence: roughly one new application every 20-45s by default (base +/-
# jitter). Kept deliberately slow - this is a demo trickle, not a load test.
DEFAULT_INTERVAL_SECONDS = 30.0
INTERVAL_SECONDS = float(os.environ.get("GEN_INTERVAL_SECONDS", DEFAULT_INTERVAL_SECONDS))
INTERVAL_JITTER = float(os.environ.get("GEN_INTERVAL_JITTER", "12"))
MAX_APPS = int(os.environ.get("GEN_MAX_APPS", "0"))  # 0 => unbounded
PERFORMED_BY = os.environ.get("GEN_PERFORMED_BY", "synthetic-generator")

EXPECTED_DB = "luxauto_demo"
PROD_DB = "luxauto"

# --------------------------------------------------------------------------- #
# LIVE CONTROL FILE (operator control panel, ADR: control-panel build)
# --------------------------------------------------------------------------- #
# A small JSON file the loop reads at the START of each cycle so an operator can
# bend the trend forward without a restart. It is written by the VM control
# agent (which reflects the Entra-gated control API's intent). A PERSISTENT path
# (survives reboot), NOT /tmp. Overridable for tests via GEN_CONTROL_FILE.
#
# Shape:  { "state": "running"|"paused", "preset": "<name>", "rate_per_min": <n> }
#
# Forward-only by construction: a preset/rate change only alters the CHARACTER
# and CADENCE of NEW applications. The generator's sole write path is
# "materialize a new app graph -> submit_application() -> maybe create_quote()";
# it never UPDATEs or DELETEs existing rows. Switching presets therefore never
# resets or shrinks the book - existing synthetic history stays put.
CONTROL_FILE = os.environ.get(
    "GEN_CONTROL_FILE", "/home/azureuser/demo-control/generator-control.json"
)
VALID_STATES = ("running", "paused")
DEFAULT_PRESET = "steady"

# Active knobs the CURRENT cycle applies. Defaults here mean a bare hand-run with
# no control file behaves exactly as before (steady mix, no premium bias).
_ACTIVE_WEIGHTS = None      # list[(builder, weight)] or None -> use PROFILE_MIX
_ACTIVE_PREMIUM_BIAS = 1.0  # multiplier on clean-spec appraised value (>=1.0)

# In-band marker stamped on every generator application (applications.
# state_specific_extensions). No referral rule reads this column, so it is
# behaviour-neutral; it is the primary scope key for --reset.
MARKER_KEY = "synthetic_generator"
# Every generator applicant email starts with this local-part prefix (secondary
# reset scope key, and it keeps synthetic applicants trivially greppable).
EMAIL_PREFIX = "syn."
EMAIL_DOMAIN = "example.com"

# AUTO_PROCEED_WITH_FLAG is reachable ONLY via PC-03 (garaging state with no
# active rating table), and the only such states are non-onboarded territories
# (DC/PR/VI/GU). Those are exactly the cells the dashboard's 50-state cartogram
# treats as out-of-program - garaging an app there would light up an off-program
# territory on the map (the map colours any grid cell whose garaging_state count
# is > 0, DC included). PC-03 keys on the SAME applications.garaging_state the map
# reads, so the flag cannot be produced without that side effect, and the map is
# out of scope to change. We therefore leave the flag OFF by default and exercise
# the other six dispositions. Flip this to True only once the map ignores
# off-program codes (then set FLAG_TERRITORY to a non-onboarded code).
INCLUDE_OUT_OF_TERRITORY_FLAG = False
FLAG_TERRITORY = "DC"

# The curated seed the reset restores to, and its known-good shape.
SEED_SQL_RELPATH = os.path.join("sample-data", "demo", "seed_demo_applications.sql")
CURATED_EMAILS = [
    "m.ostrander@example.com",
    "t.bianchi@example.com",
    "d.kirkwood@example.com",
    "p.nandakumar@example.com",
    "g.marchetti@example.com",
]
CURATED_APPLICANTS = 5
CURATED_APPLICATIONS = 5

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s synthetic-generator: %(message)s",
)
log = logging.getLogger("synthetic-generator")


# --------------------------------------------------------------------------- #
# Target guard - the one mistake this job must structurally refuse.
# --------------------------------------------------------------------------- #
def guard_target(cur=None) -> None:
    dbname = os.environ.get("PGDATABASE")
    if dbname == PROD_DB:
        raise SystemExit(
            f"REFUSING TO RUN: PGDATABASE is {dbname!r} (production). This job only "
            f"ever targets {EXPECTED_DB!r}."
        )
    if dbname != EXPECTED_DB:
        raise SystemExit(
            f"REFUSING TO RUN: PGDATABASE is {dbname!r}, expected {EXPECTED_DB!r}. "
            f"Set PGDATABASE={EXPECTED_DB} explicitly (the wrapper does this)."
        )
    if cur is not None:
        # Belt-and-braces: verify against the LIVE connection, not just the env,
        # in case anything downstream re-pointed it.
        cur.execute("SELECT current_database()")
        live = cur.fetchone()[0]
        if live == PROD_DB:
            raise SystemExit(
                f"REFUSING TO RUN: connected database is {live!r} (production)."
            )
        if live != EXPECTED_DB:
            raise SystemExit(
                f"REFUSING TO RUN: connected database is {live!r}, expected {EXPECTED_DB!r}."
            )


def connect():
    # Guard the env target BEFORE opening any connection, so a mis-set PGDATABASE
    # is refused without ever touching (or authenticating against) production.
    guard_target()
    # psycopg2 reads PGHOST/PGUSER/PGPASSWORD/PGSSLMODE/PGDATABASE from the env.
    conn = psycopg2.connect()
    conn.autocommit = False
    with conn.cursor() as cur:
        guard_target(cur)
    return conn


# --------------------------------------------------------------------------- #
# Synthetic PII helpers - all obviously fake, matching the seed's markers.
# --------------------------------------------------------------------------- #
FIRST_NAMES = [
    "Marisol", "Everett", "Ingrid", "Desmond", "Priya", "Lorenzo", "Beatrix",
    "Callum", "Saoirse", "Thaddeus", "Noor", "Emiliano", "Fenwick", "Ottilie",
    "Ramona", "Cassius", "Delphine", "Horace", "Anouk", "Bartholomew", "Sunniva",
    "Leopold", "Mireille", " Signe", "Aurelio", "Wilhelmina", "Fitzgerald",
]
LAST_NAMES = [
    "Ashcombe", "Vandermeer", "Kingsford", "Thistlewood", "Bellandi", "Rourke",
    "Chattopadhyay", "Fairweather", "Montoya", "Blackwood", "Nakashima",
    "Pennington", "Larsson", "Okonkwo", "Delacroix", "Harrington", "Vasquez",
    "Whitlock", "Farkas", "Underwood", "Castellanos", "Merriweather",
]
# (make, model, category) triples that read as luxury/exotic/classic.
VEHICLES_LUX = [  # production_luxury
    ("Porsche", "911 Turbo S"), ("Mercedes-Benz", "AMG GT"),
    ("BMW", "M8 Competition"), ("Aston Martin", "DB12"),
    ("Bentley", "Continental GT"), ("Maserati", "GranTurismo"),
]
VEHICLES_EXOTIC = [
    ("Lamborghini", "Huracan EVO"), ("Ferrari", "296 GTB"),
    ("McLaren", "750S"), ("Ferrari", "SF90 Stradale"),
]
VEHICLES_CLASSIC = [
    ("Ferrari", "275 GTB/4"), ("Jaguar", "E-Type Series 1"),
    ("Mercedes-Benz", "300SL Gullwing"), ("Aston Martin", "DB5"),
]
OCC_CLEAN = [
    "Orthopedic Surgeon", "Retired Executive", "Software Architect",
    "Cardiologist", "Portfolio Manager", "Law Firm Partner", "Anesthesiologist",
]
OCC_BUSINESS = ["Real Estate Agent", "Realtor / Broker"]  # trips CP-01 occupation limb
CREDIT_BANDS = ["excellent", "good", "fair"]

_VIN_ALPHABET = "".join(c for c in string.ascii_uppercase + string.digits if c not in "IOQ")


def rand_vin() -> str:
    return "".join(random.choice(_VIN_ALPHABET) for _ in range(17))


def rand_phone() -> str:
    # 555-010-xxxx pattern, matching the seed. Curated seed used 0001-0005, so
    # draw from 1000-9999 to avoid colliding with those.
    return f"555-010-{random.randint(1000, 9999)}"


def rand_email(run_id: str, seq: int) -> str:
    return f"{EMAIL_PREFIX}{run_id}.{seq}@{EMAIL_DOMAIN}"


def rand_street() -> str:
    return f"{random.randint(100, 9999)} {random.choice(['Camino', 'Highland', 'Ridgeline', 'Meridian', 'Carriage', 'Belvedere'])} {random.choice(['Ave', 'Dr', 'Ct', 'Way', 'Ln'])}"


def years_ago_date(min_y: float, max_y: float) -> date:
    days = int(random.uniform(min_y, max_y) * 365.25)
    return (datetime.now(timezone.utc) - timedelta(days=days)).date()


# --------------------------------------------------------------------------- #
# Profiles - each returns a fully-formed synthetic application spec. A base
# CLEAN spec is built first (clears every implemented rule), then a profile
# mutates exactly the fields its target rule keys on, so that rule's action is
# the most-severe one and the disposition is deterministic. The generator still
# reads back the REAL returned disposition and logs that.
# --------------------------------------------------------------------------- #
def base_clean_spec(state: str) -> dict:
    """A spec that clears all 13 implemented rules -> AUTO_PROCEED."""
    make, model = random.choice(VEHICLES_LUX)
    value = random.randint(120_000, 900_000)  # >= EL-01 floor, <= CP-02 cap
    # premium_rising preset only: scale the appraised value UP so NEW quotes read
    # richer (avg_premium & TIV drift up over subsequent cycles). Clamped below
    # the CP-02 $2M authority cap so the app stays a genuine AUTO_PROCEED and is
    # quotable - this raises premiums via new high-value quotes, and NEVER
    # rewrites an existing quote.
    if _ACTIVE_PREMIUM_BIAS and _ACTIVE_PREMIUM_BIAS != 1.0:
        value = min(int(value * _ACTIVE_PREMIUM_BIAS), 1_900_000)
    return {
        "profile": "clean_auto_proceed",
        "expected_action": "AUTO_PROCEED",
        "quote_if_cleared": True,
        "garaging_state": state,
        "applicant": {
            "date_of_birth": years_ago_date(35, 70),
            "license_status": "valid",
            "years_licensed": random.randint(12, 45),
            "occupation": random.choice(OCC_CLEAN),
            "credit_band": random.choice(CREDIT_BANDS),
            # mailing_state == garaging_state so PC-01 does not fire.
            "mailing_state": state,
        },
        "vehicle": {
            "year": random.randint(2019, 2024),
            "make": make,
            "model": model,
            "vehicle_category": "production_luxury",
            "current_appraised_value": value,
            "primary_use": random.choice(["pleasure", "commute"]),
            "annual_mileage": random.randint(2_000, 9_000),  # < CP-01 20k threshold
            "agreed_value_requested": False,  # keeps VV-03 out of scope
            "appraisal_date": years_ago_date(0.2, 1.0),
            "modifications": None,  # keeps VV-04 out of scope
        },
        "claims": [],
        "prior_insurance": None,
        "person_violations": [],
        "enrichment": None,
    }


def profile_prior_nonrenewal(state):  # AL-02 -> MANUAL_REVIEW_REQUIRED
    s = base_clean_spec(state)
    s.update(profile="prior_nonrenewal", expected_action="MANUAL_REVIEW_REQUIRED",
             quote_if_cleared=False)
    s["prior_insurance"] = {
        "current_carrier": random.choice(["Progressive", "Travelers", "Allstate"]),
        "any_nonrenewal_or_cancellation_history": True,
        "cancellation_reason": "Non-renewed by prior carrier",
    }
    return s


def profile_adverse_loss(state):  # AL-01 (2+ at-fault) -> MANUAL_REVIEW_REQUIRED
    s = base_clean_spec(state)
    s.update(profile="adverse_loss_history", expected_action="MANUAL_REVIEW_REQUIRED",
             quote_if_cleared=False)
    s["claims"] = [
        {"claim_date": years_ago_date(0.5, 2.0), "claim_type": "collision",
         "at_fault": True, "paid_amount": random.randint(8_000, 20_000),
         "description": "At-fault collision"},
        {"claim_date": years_ago_date(2.0, 4.0), "claim_type": "liability",
         "at_fault": True, "paid_amount": random.randint(5_000, 15_000),
         "description": "At-fault liability claim"},
    ]
    return s


def profile_business_use(state):  # CP-01 (mileage) -> MANUAL_REVIEW_REQUIRED
    s = base_clean_spec(state)
    s.update(profile="suspected_business_use", expected_action="MANUAL_REVIEW_REQUIRED",
             quote_if_cleared=False)
    s["vehicle"]["primary_use"] = "pleasure"
    s["vehicle"]["annual_mileage"] = random.randint(22_000, 40_000)  # >= CP-01 20k
    return s


def profile_dui(state):  # DH-01 -> MANUAL_REVIEW_SENIOR
    s = base_clean_spec(state)
    s.update(profile="dui_within_lookback", expected_action="MANUAL_REVIEW_SENIOR",
             quote_if_cleared=False)
    # subject_driver_id stays NULL -> the applicant's own conviction; no
    # additional_drivers row is created (keeps reset's cascade shallow).
    s["person_violations"] = [{
        "violation_date": years_ago_date(0.5, 4.5),  # within 5yr lookback
        "violation_type": "DUI",
        "conviction": True,
        "bac_level": round(random.uniform(0.09, 0.18), 3),
        "source": "MVR (synthetic input)",
    }]
    return s


def profile_suspended_license(state):  # DH-03 -> MANUAL_REVIEW_SENIOR
    s = base_clean_spec(state)
    s.update(profile="suspended_license", expected_action="MANUAL_REVIEW_SENIOR",
             quote_if_cleared=False)
    s["applicant"]["license_status"] = random.choice(["suspended", "revoked"])
    return s


def profile_high_tiv(state):  # CP-02 (> $2M) -> MANUAL_REVIEW_SENIOR
    s = base_clean_spec(state)
    s.update(profile="authority_limit_exceeded", expected_action="MANUAL_REVIEW_SENIOR",
             quote_if_cleared=False)
    make, model = random.choice(VEHICLES_CLASSIC)
    s["vehicle"].update(make=make, model=model, vehicle_category="classic_collector",
                        current_appraised_value=random.randint(2_200_000, 4_500_000),
                        year=random.randint(1955, 1973),
                        primary_use="show_display",
                        annual_mileage=random.randint(200, 1_500))
    return s


def profile_stale_appraisal(state):  # VV-03 -> INFORMATION_REQUEST
    s = base_clean_spec(state)
    s.update(profile="stale_agreed_value", expected_action="INFORMATION_REQUEST",
             quote_if_cleared=False)
    make, model = random.choice(VEHICLES_EXOTIC)
    s["vehicle"].update(make=make, model=model, vehicle_category="exotic",
                        current_appraised_value=random.randint(180_000, 600_000),
                        agreed_value_requested=True,
                        # Missing OR older than the 3yr national default cadence.
                        appraisal_date=random.choice([None, years_ago_date(4, 9)]))
    return s


def profile_below_floor(state):  # EL-01 (< $100k) -> DECLINE_RECOMMENDED
    s = base_clean_spec(state)
    s.update(profile="below_agreed_value_floor", expected_action="DECLINE_RECOMMENDED",
             quote_if_cleared=False)
    s["vehicle"]["current_appraised_value"] = random.randint(45_000, 95_000)
    return s


def profile_sanctions(state):  # PC-02 -> HARD_DECLINE_COMPLIANCE
    s = base_clean_spec(state)
    s.update(profile="sanctions_hit", expected_action="HARD_DECLINE_COMPLIANCE",
             quote_if_cleared=False)
    make, model = random.choice(VEHICLES_EXOTIC)
    s["vehicle"].update(make=make, model=model, vehicle_category="exotic",
                        current_appraised_value=random.randint(180_000, 400_000))
    # Enrichment-shaped INPUT only: the (placeholder) PC-02 rule reads it. No
    # real vendor is called - identical to the curated seed's Profile 5.
    s["enrichment"] = {"sanctions_screen_result": "positive_hit"}
    return s


def profile_out_of_territory(state):  # PC-03 -> AUTO_PROCEED_WITH_FLAG (gated off)
    s = base_clean_spec(FLAG_TERRITORY)
    s.update(profile="out_of_licensed_territory", expected_action="AUTO_PROCEED_WITH_FLAG",
             quote_if_cleared=False)  # no rating table -> not quotable anyway
    s["applicant"]["mailing_state"] = FLAG_TERRITORY
    return s


# (builder, weight). Weighted so the book reads realistically: a large majority
# clean/auto-proceed, referrals and declines the minority.
PROFILE_MIX = [
    (base_clean_spec,           60),
    (profile_prior_nonrenewal,   8),
    (profile_adverse_loss,       6),
    (profile_business_use,       4),
    (profile_dui,                5),
    (profile_suspended_license,  3),
    (profile_high_tiv,           3),
    (profile_stale_appraisal,    4),
    (profile_below_floor,        3),
    (profile_sanctions,          2),
]
if INCLUDE_OUT_OF_TERRITORY_FLAG:
    PROFILE_MIX.append((profile_out_of_territory, 3))

# Stable name -> builder registry (the name matches spec['profile']). Used by the
# GEN_ONLY_PROFILES testing lever below and for readable diagnostics.
NAME_TO_BUILDER = {
    "clean_auto_proceed": base_clean_spec,
    "prior_nonrenewal": profile_prior_nonrenewal,
    "adverse_loss_history": profile_adverse_loss,
    "suspected_business_use": profile_business_use,
    "dui_within_lookback": profile_dui,
    "suspended_license": profile_suspended_license,
    "authority_limit_exceeded": profile_high_tiv,
    "stale_agreed_value": profile_stale_appraisal,
    "below_agreed_value_floor": profile_below_floor,
    "sanctions_hit": profile_sanctions,
    "out_of_licensed_territory": profile_out_of_territory,
}

# GEN_ONLY_PROFILES (optional): comma-separated profile names to restrict the mix
# to, at equal weight. This is a deterministic testing/demo lever - e.g. to prove
# the rarer decline dispositions on demand without waiting for the weighted draw.
# It never invents behaviour; it only narrows which real profiles are generated.
_only = [p.strip() for p in os.environ.get("GEN_ONLY_PROFILES", "").split(",") if p.strip()]
if _only:
    unknown = [p for p in _only if p not in NAME_TO_BUILDER]
    if unknown:
        raise SystemExit(
            f"GEN_ONLY_PROFILES contains unknown profile(s): {unknown}. "
            f"Valid: {sorted(NAME_TO_BUILDER)}"
        )
    PROFILE_MIX = [(NAME_TO_BUILDER[p], 1) for p in _only]
# When the explicit testing lever is set it WINS over any control-file preset:
# a preset must never silently re-broaden a deliberately narrowed mix.
_ONLY_LOCKED = bool(_only)


# --------------------------------------------------------------------------- #
# Named presets - the five the control panel switches between. Each is a bias
# over the SAME real profile builders (by name) plus a rate and an optional
# premium bias. Nothing here invents a disposition: the referral rules still
# decide every outcome; a preset only reweights which real inputs are generated
# and how fast. All five are additive/forward-only.
#
#   steady          moderate rate; realistic mix (majority AUTO_PROCEED)
#   surge           high rate; skew hard to AUTO_PROCEED ("healthy growth")
#   stress          moderate/high rate; skew to MANUAL_REVIEW_* + DECLINE_*
#   premium_rising  moderate rate; higher-value clean vehicles + more high-TIV
#                   -> avg_premium & TIV drift UP via NEW quotes only
#   volume_drying   LOW rate; same realistic mix, pipeline visibly quiets
# --------------------------------------------------------------------------- #
_REALISTIC_MIX = {
    "clean_auto_proceed": 60, "prior_nonrenewal": 8, "adverse_loss_history": 6,
    "suspected_business_use": 4, "dui_within_lookback": 5, "suspended_license": 3,
    "authority_limit_exceeded": 3, "stale_agreed_value": 4,
    "below_agreed_value_floor": 3, "sanctions_hit": 2,
}
PRESETS = {
    "steady": {
        "rate_per_min": 2.0, "premium_bias": 1.0, "weights": dict(_REALISTIC_MIX),
    },
    "surge": {
        "rate_per_min": 6.0, "premium_bias": 1.0, "weights": {
            "clean_auto_proceed": 85, "prior_nonrenewal": 3, "adverse_loss_history": 2,
            "suspected_business_use": 2, "dui_within_lookback": 2, "suspended_license": 1,
            "authority_limit_exceeded": 1, "stale_agreed_value": 2,
            "below_agreed_value_floor": 1, "sanctions_hit": 1,
        },
    },
    "stress": {
        "rate_per_min": 4.0, "premium_bias": 1.0, "weights": {
            "clean_auto_proceed": 25, "prior_nonrenewal": 12, "adverse_loss_history": 14,
            "suspected_business_use": 8, "dui_within_lookback": 12, "suspended_license": 8,
            "authority_limit_exceeded": 6, "stale_agreed_value": 5,
            "below_agreed_value_floor": 8, "sanctions_hit": 2,
        },
    },
    "premium_rising": {
        "rate_per_min": 2.5, "premium_bias": 2.1, "weights": {
            "clean_auto_proceed": 68, "prior_nonrenewal": 6, "adverse_loss_history": 4,
            "suspected_business_use": 2, "dui_within_lookback": 4, "suspended_license": 2,
            "authority_limit_exceeded": 5, "stale_agreed_value": 4,
            "below_agreed_value_floor": 1, "sanctions_hit": 1,
        },
    },
    "volume_drying": {
        "rate_per_min": 0.5, "premium_bias": 1.0, "weights": dict(_REALISTIC_MIX),
    },
}
# Clamp bounds for a rate read off the control file (defensive; the API also
# validates). 0.1/min (one every 10 min) .. 30/min (one every 2s).
RATE_MIN_PER_MIN = 0.1
RATE_MAX_PER_MIN = 30.0


def _weights_to_mix(weight_map):
    """Turn a {profile_name: weight} map into the [(builder, weight)] shape
    pick_profile expects, skipping zero/unknown names."""
    mix = []
    for name, w in weight_map.items():
        if w and w > 0 and name in NAME_TO_BUILDER:
            mix.append((NAME_TO_BUILDER[name], w))
    return mix


def apply_control(preset_name):
    """Set the module-global knobs the current cycle uses from a preset name.
    Unknown preset -> the default. Honors _ONLY_LOCKED (the GEN_ONLY_PROFILES
    testing lever wins, so a preset never re-broadens a narrowed mix)."""
    global _ACTIVE_WEIGHTS, _ACTIVE_PREMIUM_BIAS
    preset = PRESETS.get(preset_name) or PRESETS[DEFAULT_PRESET]
    _ACTIVE_WEIGHTS = None if _ONLY_LOCKED else _weights_to_mix(preset["weights"])
    _ACTIVE_PREMIUM_BIAS = 1.0 if _ONLY_LOCKED else float(preset.get("premium_bias", 1.0))
    return preset


def load_control():
    """Read the live control file at the start of a cycle. Missing or invalid ->
    a safe default (steady / running), matching the pre-control-file behaviour of
    a bare hand-run. NEVER raises: a bad control file must not crash the loop or,
    worse, silently stop generation."""
    default = {
        "state": "running",
        "preset": DEFAULT_PRESET,
        "rate_per_min": PRESETS[DEFAULT_PRESET]["rate_per_min"],
    }
    try:
        with open(CONTROL_FILE) as f:
            raw = json.load(f)
    except FileNotFoundError:
        return default
    except Exception as exc:  # unreadable / malformed JSON
        log.warning("control file %s unreadable (%s); using default", CONTROL_FILE, exc)
        return default
    if not isinstance(raw, dict):
        return default

    state = raw.get("state")
    if state not in VALID_STATES:
        state = "running"
    preset = raw.get("preset")
    if preset not in PRESETS:
        preset = DEFAULT_PRESET
    try:
        rate = float(raw.get("rate_per_min", PRESETS[preset]["rate_per_min"]))
    except (TypeError, ValueError):
        rate = PRESETS[preset]["rate_per_min"]
    rate = min(max(rate, RATE_MIN_PER_MIN), RATE_MAX_PER_MIN)
    return {"state": state, "preset": preset, "rate_per_min": rate}


# --------------------------------------------------------------------------- #
# State selection - spread across the onboarded 50 so the national map populates.
# Uniform draw over all onboarded states with a light boost to a few populous
# ones for a plausible skew; over a burst this touches many states.
# --------------------------------------------------------------------------- #
POPULOUS_BOOST = {"CA": 4, "NY": 3, "TX": 3, "FL": 3, "IL": 2, "PA": 2, "OH": 2,
                  "MI": 2, "MA": 2, "NJ": 2, "WA": 2, "CO": 2}


def load_onboarded_states(cur) -> list:
    cur.execute(
        "SELECT DISTINCT state FROM state_rating_table_versions "
        "WHERE superseded_by IS NULL AND effective_range @> now() ORDER BY state"
    )
    return [r[0].strip() for r in cur.fetchall()]


def rating_record_for_state(cur, state: str):
    cur.execute(
        "SELECT record_id FROM state_rating_table_versions "
        "WHERE state = %s AND superseded_by IS NULL AND effective_range @> now() "
        "LIMIT 1",
        (state,),
    )
    row = cur.fetchone()
    return row[0] if row else None


def pick_state(states: list) -> str:
    weights = [POPULOUS_BOOST.get(s, 1) for s in states]
    return random.choices(states, weights=weights, k=1)[0]


def pick_profile():
    # Use the active preset's weights when set; otherwise the module default mix.
    mix = PROFILE_MIX if (_ONLY_LOCKED or not _ACTIVE_WEIGHTS) else _ACTIVE_WEIGHTS
    builders, weights = zip(*mix)
    return random.choices(builders, weights=weights, k=1)[0]


# --------------------------------------------------------------------------- #
# Materialize one synthetic application graph via the base tables (input only),
# then return the new application_id. This is exactly what the curated seed does
# before calling submit_application(); the rows are draft INPUT, not pipeline
# output.
# --------------------------------------------------------------------------- #
def materialize(cur, spec: dict, run_id: str, seq: int) -> str:
    a = spec["applicant"]
    email = rand_email(run_id, seq)
    cur.execute(
        """
        INSERT INTO applicants
          (first_name, last_name, date_of_birth, ssn_last4, email, phone,
           mailing_street, mailing_city, mailing_state, mailing_zip, occupation,
           years_licensed, license_number_state, license_status,
           credit_based_insurance_score_band)
        VALUES (%s,%s,%s,'0000',%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
        RETURNING applicant_id
        """,
        (
            random.choice(FIRST_NAMES), random.choice(LAST_NAMES),
            a["date_of_birth"], email, rand_phone(),
            rand_street(), "Springfield", a.get("mailing_state"), "00000",
            a["occupation"], a["years_licensed"], a.get("mailing_state"),
            a["license_status"], a["credit_band"],
        ),
    )
    applicant_id = cur.fetchone()[0]

    marker = {
        MARKER_KEY: True,
        "run_id": run_id,
        "profile": spec["profile"],
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }
    cur.execute(
        "INSERT INTO applications (applicant_id, status, garaging_state, "
        "state_specific_extensions) VALUES (%s,'draft',%s,%s) RETURNING application_id",
        (applicant_id, spec["garaging_state"], json.dumps(marker)),
    )
    app_id = cur.fetchone()[0]

    v = spec["vehicle"]
    cur.execute(
        """
        INSERT INTO vehicles
          (application_id, year, make, model, vin, vehicle_category,
           current_appraised_value, appraisal_date, agreed_value_requested,
           annual_mileage, primary_use, modifications,
           garaging_street, garaging_city, garaging_state, garaging_zip, garage_type)
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
        """,
        (
            app_id, v["year"], v["make"], v["model"], rand_vin(),
            v["vehicle_category"], v["current_appraised_value"], v.get("appraisal_date"),
            v.get("agreed_value_requested", False), v.get("annual_mileage"),
            v.get("primary_use", "pleasure"), v.get("modifications"),
            rand_street(), "Springfield", spec["garaging_state"], "00000",
            random.choice(["attached_locked", "gated_community", "climate_controlled_storage"]),
        ),
    )

    for c in spec.get("claims", []):
        cur.execute(
            "INSERT INTO claims_history (application_id, claim_date, claim_type, "
            "at_fault, paid_amount, description) VALUES (%s,%s,%s,%s,%s,%s)",
            (app_id, c["claim_date"], c["claim_type"], c["at_fault"],
             c.get("paid_amount"), c.get("description")),
        )

    pi = spec.get("prior_insurance")
    if pi:
        cur.execute(
            "INSERT INTO prior_insurance (application_id, current_carrier, "
            "any_nonrenewal_or_cancellation_history, cancellation_reason) "
            "VALUES (%s,%s,%s,%s)",
            (app_id, pi.get("current_carrier"),
             pi.get("any_nonrenewal_or_cancellation_history"),
             pi.get("cancellation_reason")),
        )

    for pv in spec.get("person_violations", []):
        cur.execute(
            "INSERT INTO person_violations (application_id, subject_driver_id, "
            "violation_date, violation_type, conviction, bac_level, source) "
            "VALUES (%s, NULL, %s, %s, %s, %s, %s)",
            (app_id, pv["violation_date"], pv["violation_type"], pv["conviction"],
             pv.get("bac_level"), pv["source"]),
        )

    en = spec.get("enrichment")
    if en:
        cur.execute(
            "INSERT INTO applicant_enrichment (application_id, "
            "sanctions_screen_result, enriched_at) VALUES (%s,%s, now())",
            (app_id, en["sanctions_screen_result"]),
        )

    return app_id


def generate_one(conn, states: list, run_id: str, seq: int) -> str:
    """One full cycle in its own transaction: materialize -> submit -> maybe quote.
    Returns a short human summary. Rolls back this app on any error (caller keeps
    the loop alive)."""
    builder = pick_profile()
    state = FLAG_TERRITORY if builder is profile_out_of_territory else pick_state(states)
    spec = builder(state)

    # Transaction 1: materialize the input graph + run the real submit path. If
    # anything here fails, roll back and lose nothing (no half-app is committed).
    try:
        with conn.cursor() as cur:
            app_id = materialize(cur, spec, run_id, seq)
            # THE real pipeline entry point. Returns the most-severe disposition.
            cur.execute("SELECT submit_application(%s, %s)", (app_id, PERFORMED_BY))
            action = cur.fetchone()[0]
        conn.commit()
    except Exception:
        conn.rollback()
        raise

    # Transaction 2 (separate, so a quote failure never loses the committed
    # submission): create_quote() is its own real RPC and self-gates on the
    # disposition. We only attempt it for a genuinely cleared app.
    quoted = None
    if spec.get("quote_if_cleared") and action == "AUTO_PROCEED":
        try:
            with conn.cursor() as cur:
                rating_id = rating_record_for_state(cur, spec["garaging_state"])
                if rating_id is not None:
                    cur.execute(
                        "SELECT create_quote(%s, %s, %s, %s, NULL, %s)",
                        (app_id, random.choice(["retail", "wholesale"]),
                         random.randint(6, 12), rating_id, PERFORMED_BY),
                    )
                    quoted = cur.fetchone()[0]
            conn.commit()
        except Exception as qexc:
            conn.rollback()
            # The application is already committed and correctly dispositioned;
            # only the quote is missing. Log and carry on.
            log.warning("quote failed for %s (app remains submitted): %s", app_id, qexc)

    exp = spec["expected_action"]
    flag = "" if action == exp else f"  (expected {exp})"
    qtxt = f"  quote={quoted}" if quoted else ""
    return f"app={app_id} state={spec['garaging_state']} profile={spec['profile']} -> {action}{flag}{qtxt}"


# --------------------------------------------------------------------------- #
# The generation loop.
# --------------------------------------------------------------------------- #
_STOP = False


def _handle_stop(signum, _frame):
    global _STOP
    _STOP = True
    log.info("received signal %s - will exit after this cycle", signum)


def _interruptible_sleep(seconds: float) -> None:
    slept = 0.0
    step = 0.5
    while slept < seconds and not _STOP:
        import time
        time.sleep(min(step, seconds - slept))
        slept += step


def run_loop() -> int:
    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    conn = connect()
    with conn.cursor() as cur:
        states = load_onboarded_states(cur)
    run_id = uuid.uuid4().hex[:8]
    log.info(
        "connected read-write to %s; run_id=%s; %d onboarded states; "
        "control_file=%s; flag_disposition=%s; max_apps=%s",
        EXPECTED_DB, run_id, len(states), CONTROL_FILE,
        "on" if INCLUDE_OUT_OF_TERRITORY_FLAG else "off",
        MAX_APPS or "unbounded",
    )
    if _ONLY_LOCKED:
        log.info("GEN_ONLY_PROFILES is set - control-file presets will NOT change "
                 "the profile mix (the testing lever wins); state/rate still apply.")

    made = 0
    seq = 0
    last_state = None
    last_preset = None
    while not _STOP:
        # Read the LIVE control file at the start of every cycle. This is the one
        # seam that lets an operator bend the trend forward mid-run.
        ctrl = load_control()
        apply_control(ctrl["preset"])
        if ctrl["preset"] != last_preset:
            log.info("preset -> %s (rate=%.2f/min, premium_bias=%.2f)",
                     ctrl["preset"], ctrl["rate_per_min"], _ACTIVE_PREMIUM_BIAS)
            last_preset = ctrl["preset"]

        if ctrl["state"] == "paused":
            if last_state != "paused":
                log.info("state -> paused: idling (process stays alive, no NEW apps; "
                         "existing rows untouched)")
            last_state = "paused"
            _interruptible_sleep(2.0)  # stay responsive to un-pause / signals
            continue
        if last_state != "running":
            log.info("state -> running: generating per preset '%s'", ctrl["preset"])
        last_state = "running"

        seq += 1
        try:
            summary = generate_one(conn, states, run_id, seq)
            made += 1
            log.info("[%d] %s", made, summary)
        except psycopg2.OperationalError as exc:
            log.error("DB connection error, reconnecting next cycle: %s", exc)
            try:
                conn.close()
            except Exception:
                pass
            try:
                conn = connect()
            except Exception as rexc:
                log.error("reconnect failed: %s", rexc)
        except Exception as exc:
            # One bad app never crashes the loop.
            log.error("cycle error (skipping this app): %s", exc)

        if MAX_APPS and made >= MAX_APPS:
            log.info("reached GEN_MAX_APPS=%d, exiting", MAX_APPS)
            break
        if _STOP:
            break
        # Pace from the live rate (apps/min -> seconds/app), with light jitter so
        # the cadence reads organic. Re-read next cycle picks up any change.
        base = 60.0 / max(ctrl["rate_per_min"], RATE_MIN_PER_MIN)
        jit = min(INTERVAL_JITTER, base * 0.4)
        delay = max(1.0, base + random.uniform(-jit, jit))
        _interruptible_sleep(delay)

    log.info("exiting; generated %d applications this run", made)
    try:
        conn.close()
    except Exception:
        pass
    return 0


# --------------------------------------------------------------------------- #
# Reset - the one destructive path. Scoped, asserted, verified. Never TRUNCATE.
# --------------------------------------------------------------------------- #
def _counts(cur) -> dict:
    out = {}
    for label, sql in (
        ("applicants", "SELECT count(*) FROM applicants"),
        ("applications", "SELECT count(*) FROM applications"),
        ("vehicles", "SELECT count(*) FROM vehicles"),
        ("decision_log", "SELECT count(*) FROM decision_log"),
        ("quotes", "SELECT count(*) FROM quotes"),
    ):
        cur.execute(sql)
        out[label] = cur.fetchone()[0]
    return out


def _repo_root() -> str:
    # scripts/lib/synthetic_generator.py -> repo root is two dirs up.
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# Existing sanctioned provisioning artefacts the reprovision path drives verbatim
# (relative to repo root). This job authors NONE of them - it only orchestrates.
SCHEMA_APPLY_RELPATH = os.path.join("scripts", "apply-and-verify-schema.sh")
ONBOARD_TIER_A_RELPATH = os.path.join("sample-data", "demo", "onboard_demo_states.sql")
ONBOARD_TIER_BC_RELPATH = os.path.join("sample-data", "demo", "onboard_demo_states_tier_bc.sql")
EXPECTED_ONBOARDED_STATES = 50


def reset_report() -> int:
    """Non-destructive status report: synthetic vs curated. Deletes NOTHING.

    (A row-scoped delete is impossible here - decision_log is append-only and
    applications cascade into it - so the destructive path is the separate,
    more-guarded --reprovision --yes.)"""
    conn = connect()
    with conn.cursor() as cur:
        counts = _counts(cur)
        cur.execute(
            "SELECT count(*) FROM applications "
            "WHERE state_specific_extensions ->> %s = 'true'",
            (MARKER_KEY,),
        )
        synthetic_apps = cur.fetchone()[0]
        cur.execute(
            "SELECT count(*) FROM applicants WHERE email LIKE %s",
            (EMAIL_PREFIX.replace("%", r"\%") + "%@" + EMAIL_DOMAIN,),
        )
        synthetic_applicants = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM applicants WHERE email = ANY(%s)", (CURATED_EMAILS,))
        curated_present = cur.fetchone()[0]
    conn.close()

    log.info("STATUS target=%s", EXPECTED_DB)
    log.info("STATUS totals: %s", counts)
    log.info("STATUS synthetic (generator-created): applications=%d, applicants=%d",
             synthetic_apps, synthetic_applicants)
    log.info("STATUS curated (seed) applicants present: %d/%d", curated_present, CURATED_APPLICANTS)
    if synthetic_apps or synthetic_applicants:
        log.info(
            "STATUS to return to the curated book, run the guarded destructive "
            "rebuild:  scripts/synthetic-generator.sh --reprovision --yes"
        )
    else:
        log.info("STATUS no synthetic rows present - the book is already at the curated seed.")
    return 0


def _run(cmd, label) -> None:
    """Run one provisioning subprocess with the inherited PG* env; fail loudly."""
    log.info("REPROVISION step: %s  (%s)", label, " ".join(cmd))
    proc = subprocess.run(cmd, env=os.environ.copy(), capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(
            f"ABORTING REPROVISION at '{label}' (rc={proc.returncode}).\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    # Surface the tail so the operator sees what each sanctioned script did.
    tail = "\n".join((proc.stdout or "").strip().splitlines()[-6:])
    if tail:
        log.info("REPROVISION step '%s' output tail:\n%s", label, tail)


def reprovision(assume_yes: bool) -> int:
    """The one destructive path: a full re-provision of luxauto_demo from the
    existing sanctioned scripts, verbatim. Authors no new DDL, disables no audit
    trigger, uses no session_replication_role, touches only luxauto_demo."""
    if not assume_yes:
        raise SystemExit(
            "REFUSING: --reprovision is destructive (it DROPs and rebuilds all of "
            "luxauto_demo). Re-run with --reprovision --yes to confirm."
        )

    root = _repo_root()
    schema_apply = os.path.join(root, SCHEMA_APPLY_RELPATH)
    onboard_a = os.path.join(root, ONBOARD_TIER_A_RELPATH)
    onboard_bc = os.path.join(root, ONBOARD_TIER_BC_RELPATH)
    seed = os.path.join(root, SEED_SQL_RELPATH)
    for path in (schema_apply, onboard_a, onboard_bc, seed):
        if not os.path.isfile(path):
            raise SystemExit(f"ABORTING REPROVISION: required provisioning file missing: {path}")

    # Pre-flight snapshot + a printed plan naming the exact target and actions.
    conn = connect()  # guards env + live target
    with conn.cursor() as cur:
        cur.execute("SELECT current_database()")
        live_db = cur.fetchone()[0]
        before = _counts(cur)
    conn.close()

    log.warning("=" * 72)
    log.warning("REPROVISION PLAN - DESTRUCTIVE. Target database: %s", live_db)
    log.warning("  1. DROP SCHEMA public CASCADE; CREATE SCHEMA public;  (clears ALL data)")
    log.warning("  2. %s", SCHEMA_APPLY_RELPATH)
    log.warning("  3. psql -f %s", ONBOARD_TIER_A_RELPATH)
    log.warning("  4. psql -f %s", ONBOARD_TIER_BC_RELPATH)
    log.warning("  5. psql -f %s", SEED_SQL_RELPATH)
    log.warning("Current counts (all will be discarded and rebuilt): %s", before)
    log.warning("=" * 72)

    # Step 1: clear. The DROP is fenced with a same-statement guard so it can only
    # ever run inside luxauto_demo - the strongest "checked immediately before the
    # DROP" possible. This is the documented clear step (ADR 0008), not new schema.
    guarded_drop = (
        "DO $$ BEGIN "
        "IF current_database() <> 'luxauto_demo' THEN "
        "RAISE EXCEPTION 'REFUSING DROP: connected to %, not luxauto_demo', current_database(); "
        "END IF; END $$; "
        "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
    )
    _run(["psql", "-v", "ON_ERROR_STOP=1", "-c", guarded_drop], "DROP+CREATE SCHEMA public")

    # Steps 2-5: rebuild from the sanctioned scripts, verbatim.
    _run(["bash", schema_apply], "apply-and-verify-schema.sh")
    _run(["psql", "-v", "ON_ERROR_STOP=1", "-f", onboard_a], "onboard_demo_states.sql (Tier A)")
    _run(["psql", "-v", "ON_ERROR_STOP=1", "-f", onboard_bc], "onboard_demo_states_tier_bc.sql (Tier B+C)")
    _run(["psql", "-v", "ON_ERROR_STOP=1", "-f", seed], "seed_demo_applications.sql")

    # VERIFY the rebuilt book is exactly the known-good shape. Fail loudly if not.
    conn = connect()
    with conn.cursor() as cur:
        after = _counts(cur)
        cur.execute(
            "SELECT count(DISTINCT state) FROM state_rating_table_versions "
            "WHERE superseded_by IS NULL AND effective_range @> now()"
        )
        states = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM applicants WHERE email = ANY(%s)", (CURATED_EMAILS,))
        curated_after = cur.fetchone()[0]
        cur.execute(
            "SELECT count(*) FROM applications "
            "WHERE state_specific_extensions ->> %s = 'true'",
            (MARKER_KEY,),
        )
        synthetic_remaining = cur.fetchone()[0]
    conn.close()

    problems = []
    if states != EXPECTED_ONBOARDED_STATES:
        problems.append(f"onboarded states = {states}, expected {EXPECTED_ONBOARDED_STATES}")
    if after["applicants"] != CURATED_APPLICANTS:
        problems.append(f"applicants = {after['applicants']}, expected {CURATED_APPLICANTS}")
    if after["applications"] != CURATED_APPLICATIONS:
        problems.append(f"applications = {after['applications']}, expected {CURATED_APPLICATIONS}")
    if curated_after != CURATED_APPLICANTS:
        problems.append(f"curated applicants present = {curated_after}, expected {CURATED_APPLICANTS}")
    if after["quotes"] != 0:
        problems.append(f"quotes = {after['quotes']}, expected 0")
    if after["decision_log"] <= 0:
        problems.append("decision_log was not repopulated by the seed (0 rows)")
    if synthetic_remaining != 0:
        problems.append(f"{synthetic_remaining} synthetic application(s) still present")
    if problems:
        raise SystemExit("REPROVISION VERIFICATION FAILED: " + "; ".join(problems))

    log.info(
        "REPROVISION OK: luxauto_demo rebuilt to curated known-good - "
        "%d states onboarded, %d curated applicants / %d applications, %d quotes, "
        "decision_log repopulated to %d rows. before->after applications %d->%d.",
        states, after["applicants"], after["applications"], after["quotes"],
        after["decision_log"], before["applications"], after["applications"],
    )
    return 0


def main(argv) -> int:
    if "--reprovision" in argv:
        return reprovision(assume_yes=("--yes" in argv))
    if "--reset" in argv:
        return reset_report()
    return run_loop()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
