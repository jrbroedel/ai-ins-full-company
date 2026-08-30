"""
Load the frozen canonical book (sample-data/canonical/canonical_dataset.json)
into luxauto_demo as the demo dashboard's true data source (ADR 0046, "Option B":
DB as demo source of truth). STEP ONE of the demo-dashboard refresh.

WHAT THIS DOES (run AFTER the wrapper has rebuilt the schema - see
scripts/load-canonical-to-demo.sh):
  A. RE-SEED the rating world FROM THE ARTIFACT's embedded rating_snapshot, so the
     DB rates are byte-identical to what produced the artifact's premiums. A fresh
     schema apply already seeds the 84 base rates, the 5 category->class mappings,
     T0, and CT@1.1200 via onboard_state(); this onboards the OTHER 49 states with
     their snapshot territory factors through the sanctioned onboard_state() path.
  B. SANITY: compute_indicative_premium() on a sample must reproduce the artifact's
     rating_basis to the cent (the same cross-check the generator runs).
  C. HYBRID LOAD (the approved design - re-rate collision isolated to create_quote):
       * EVERY submission: insert applicant/application/vehicle/claims/prior_insurance,
         then submit_application() -> the REAL referral engine writes decision_log.
       * BOUND submissions only: INSERT the quote row DIRECTLY carrying the artifact's
         SOFTENED premium + basis (create_quote would re-rate and strip the softening),
         then bind_policy() (reads premium off the quote, does NOT re-rate).
       * submitted_at is PRE-SET to the artifact's submission date so AL-01/VV-03's
         5-year look-back is anchored to the frozen operating year, not load day.
  D. FROZEN VERDICT: canonical_load_disposition (application_id -> bind/refer/decline)
     records the artifact's authoritative outcome ALONGSIDE the engine's real
     decision_log. The engine collapses refer+decline into MANUAL_REVIEW_REQUIRED and
     emits ZERO declines (STEP 0 finding, ADR 0046), so the board's disposition mix is
     sourced from THIS table, never re-derived from the engine - the same way the
     artifact's premium is authoritative over a re-rate (ADR 0043 freeze-and-derive).
  E. POLICY-PERIOD CLAIMS: canonical_policy_period_claims holds the artifact's 453
     forward-looking claims, joined to the bound policies by policy_number, so
     Sum(incurred)/GWP == 0.5600 is computable off the DB.

TARGET GUARD (non-negotiable): refuses to run unless PGDATABASE == 'luxauto_demo'
AND the live current_database() == 'luxauto_demo'; refuses production 'luxauto'
outright. Fail-closed sha256 verify of the artifact before any write. Creds via the
project's Key Vault path (the wrapper sources scripts/lib/fetch-pg-credentials.sh).
"""
import argparse
import hashlib
import json
import os
import sys
import time

import psycopg2

EXPECTED_DB = "luxauto_demo"
PROD_DB = "luxauto"
DEFAULT_ARTIFACT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "sample-data", "canonical", "canonical_dataset.json",
)
EXPECT_SHA = "faa3c9b7f4d50478223133535cb16904b63533f656f3a522176ef0d756814095"

PERFORMED_BY = "canonical-loader"
# Onboarding effective range for the 49 re-seeded states: contains now() so the
# rater picks them up, wide enough to also cover the frozen operating year.
ONBOARD_RANGE = "[2025-01-01 00:00:00+00,2100-01-01 00:00:00+00)"
# Quote commission defaults (ADR 0007 model: broker + MGA = 30). Wholesale MGA
# placement; broker 12.5% mirrors the artifact money-split BROKER_RATE. The
# commission tiles are a later step - these are faithful, not load-bearing here.
BROKER_CHANNEL = "wholesale"
BROKER_COMMISSION_RATE = 12.5


def guard_env():
    db = os.environ.get("PGDATABASE")
    if db == PROD_DB:
        raise SystemExit(f"REFUSING TO RUN: PGDATABASE is {db!r} (production).")
    if db != EXPECTED_DB:
        raise SystemExit(
            f"REFUSING TO RUN: PGDATABASE is {db!r}, expected {EXPECTED_DB!r}. "
            f"Set PGDATABASE={EXPECTED_DB} explicitly (the wrapper does this)."
        )


def guard_live(cur):
    cur.execute("SELECT current_database()")
    live = cur.fetchone()[0]
    if live == PROD_DB:
        raise SystemExit(f"REFUSING TO RUN: connected database is {live!r} (production).")
    if live != EXPECTED_DB:
        raise SystemExit(
            f"REFUSING TO RUN: connected database is {live!r}, expected {EXPECTED_DB!r}."
        )


def load_artifact(path):
    with open(path, "rb") as f:
        raw = f.read()
    got = hashlib.sha256(raw).hexdigest()
    if got != EXPECT_SHA:
        raise SystemExit(
            f"ARTIFACT SHA MISMATCH: got {got}, expected {EXPECT_SHA} - refusing to load."
        )
    print(f"artifact sha256 OK: {got}")
    return json.loads(raw)


# --------------------------------------------------------------------------- #
# A. Re-seed the rating world from the artifact snapshot.
# --------------------------------------------------------------------------- #
def reseed_rating_world(cur, snap):
    tf = snap["territory_factors"]
    onboarded = snap["onboarded_states"]

    # CT is onboarded by the schema apply at 1.1200; assert it matches the snapshot
    # rather than re-onboarding it (a second overlapping territory_factors row for CT
    # would violate the exclusion constraint).
    cur.execute(
        "SELECT pd_territory_factor FROM territory_factors "
        "WHERE state='CT' AND effective_range @> now()"
    )
    row = cur.fetchone()
    if row is None:
        raise SystemExit("RESEED: CT not onboarded by schema apply - unexpected.")
    if abs(float(row[0]) - float(tf["CT"])) > 1e-9:
        raise SystemExit(
            f"RESEED: schema CT factor {float(row[0])} != artifact CT factor {tf['CT']}."
        )

    n = 0
    for state in onboarded:
        if state == "CT":
            continue
        cur.execute(
            "SELECT onboard_state("
            " %s, %s, 'prior_approval'::filing_status_t, 'Private Passenger Auto', "
            " 'TBD-ILLUSTRATIVE', %s::tstzrange, %s, %s, "
            " p_rate_manual_reference := 'TBD - illustrative canonical load (ADR 0046)')",
            (
                state,
                f"{state} Insurance Department",
                ONBOARD_RANGE,
                float(tf[state]),
                "Illustrative PD territory factor from the canonical rating snapshot "
                "(ADR 0046 demo load); not a filed factor",
            ),
        )
        n += 1
    print(f"reseed: onboarded {n} states (+ CT from schema) = {n + 1} total")

    # Verify parity with the snapshot.
    cur.execute(
        "SELECT state, pd_territory_factor FROM territory_factors "
        "WHERE effective_range @> now() AND state <> 'T0'"
    )
    db_tf = {s.strip(): float(f) for s, f in cur.fetchall()}
    if set(db_tf) != set(tf):
        raise SystemExit(
            f"RESEED PARITY: states differ. db-only={set(db_tf)-set(tf)}, "
            f"snap-only={set(tf)-set(db_tf)}"
        )
    diffs = [(s, tf[s], db_tf[s]) for s in tf if abs(tf[s] - db_tf[s]) > 1e-9]
    if diffs:
        raise SystemExit(f"RESEED PARITY: territory factor diffs {diffs[:5]}")
    print(f"reseed parity OK: {len(db_tf)} territory factors match the snapshot")


# --------------------------------------------------------------------------- #
# B. Rating sanity: DB rater == artifact basis to the cent, on a sample.
# --------------------------------------------------------------------------- #
def rating_sanity(cur, subs, k=4):
    checked = 0
    for s in subs:
        if s["disposition"] != "bind":
            continue
        b = s["quote"]["rating_basis"]
        cur.execute(
            "SELECT indicative_premium, base_rate, territory_factor "
            "FROM compute_indicative_premium(%s::vehicle_category_t, %s::numeric, %s::char(2))",
            (s["vehicle"]["vehicle_category"], s["vehicle"]["agreed_value"], s["garaging_state"]),
        )
        prem, base_rate, terr = cur.fetchone()
        if abs(float(prem) - float(b["indicative_premium"])) > 0.01:
            raise SystemExit(
                f"RATING DRIFT seq={s['seq']}: db={float(prem)} artifact={b['indicative_premium']}"
            )
        if abs(float(base_rate) - float(b["base_rate_per_100"])) > 1e-9 or \
           abs(float(terr) - float(b["territory_factor"])) > 1e-9:
            raise SystemExit(f"RATING BASIS DRIFT seq={s['seq']}: db=({base_rate},{terr}) "
                             f"artifact=({b['base_rate_per_100']},{b['territory_factor']})")
        checked += 1
        if checked >= k:
            break
    print(f"rating sanity OK: {checked} samples reproduce the artifact basis to the cent")


# --------------------------------------------------------------------------- #
# C/D. Demo-load tables + the one-round-trip-per-submission server-side helper.
# --------------------------------------------------------------------------- #
CREATE_TABLES = """
CREATE TABLE IF NOT EXISTS canonical_load_disposition (
  application_id       UUID PRIMARY KEY REFERENCES applications(application_id) ON DELETE CASCADE,
  submission_id        UUID NOT NULL,
  seq                  INTEGER NOT NULL,
  artifact_disposition TEXT NOT NULL CHECK (artifact_disposition IN ('bind','refer','decline')),
  engine_action        referral_action_t NOT NULL,
  loaded_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_canon_disp_disposition ON canonical_load_disposition(artifact_disposition);

CREATE TABLE IF NOT EXISTS canonical_policy_period_claims (
  claim_id      UUID PRIMARY KEY,
  policy_id     UUID NOT NULL REFERENCES policies(policy_id) ON DELETE CASCADE,
  date_of_loss  DATE NOT NULL,
  incurred      NUMERIC(14,2) NOT NULL,
  status        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_canon_claims_policy ON canonical_policy_period_claims(policy_id);
"""

# Transient (pg_temp) helper: does ALL of one submission's work in a single call,
# so the load is ~10,500 round trips, not ~250,000. Returns the DB policy_id (NULL
# for non-bound) and the artifact policy_id, for the claims join afterwards.
CREATE_HELPER = """
CREATE FUNCTION pg_temp._canon_load_one(p jsonb, p_by text)
RETURNS TABLE (art_policy_id text, db_policy_id uuid) AS $fn$
DECLARE
  v_applicant uuid; v_app uuid; v_state text; v_submitted date;
  v_disp text; v_action referral_action_t; v_quote uuid; v_policy uuid;
  v_premium numeric; v_basis jsonb; v_rec uuid; c jsonb;
  v_cat text; v_value numeric;
BEGIN
  v_state    := p->>'garaging_state';
  v_submitted:= (p->>'submitted_at')::date;
  v_disp     := p->>'disposition';
  v_cat      := p->'vehicle'->>'vehicle_category';
  v_value    := (p->'vehicle'->>'agreed_value')::numeric;

  INSERT INTO applicants (first_name,last_name,email,occupation,
                          date_of_birth,license_status,years_licensed,mailing_state)
  VALUES (p->'applicant'->>'first_name', p->'applicant'->>'last_name',
          p->'applicant'->>'email', p->'applicant'->>'occupation',
          DATE '1975-06-15', 'valid'::license_status_t, 30, v_state)
  RETURNING applicant_id INTO v_applicant;

  -- submitted_at PRE-SET to the frozen submission date; submit_application keeps it
  -- via COALESCE, so AL-01/VV-03 look-back is anchored to the operating year.
  INSERT INTO applications (applicant_id, status, garaging_state, submitted_at)
  VALUES (v_applicant, 'draft', v_state, v_submitted::timestamptz)
  RETURNING application_id INTO v_app;

  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category,
                        current_appraised_value, agreed_value_requested, appraisal_date,
                        appraisal_source, annual_mileage, primary_use, garaging_street, garaging_state)
  VALUES (v_app, (p->'vehicle'->>'year')::smallint, p->'vehicle'->>'make',
          p->'vehicle'->>'model', p->'vehicle'->>'vin', v_cat::vehicle_category_t,
          v_value, true, v_submitted, 'canonical-loader', 2000, 'pleasure'::primary_use_t,
          '1 Canonical Way', v_state);

  FOR c IN SELECT * FROM jsonb_array_elements(p->'loss_run'->'claims') LOOP
    INSERT INTO claims_history (application_id, claim_date, claim_type, at_fault, paid_amount, description)
    VALUES (v_app, (c->>'claim_date')::date, (c->>'claim_type')::claim_type_t,
            (c->>'at_fault')::boolean, (c->>'paid_amount')::numeric, c->>'description');
  END LOOP;

  INSERT INTO prior_insurance (application_id, any_nonrenewal_or_cancellation_history)
  VALUES (v_app, (p->'loss_run'->>'prior_carrier_nonrenewal')::boolean);

  -- REAL referral engine -> decision_log (the audit trail is generated, not forged).
  v_action := submit_application(v_app, p_by);

  IF v_disp = 'bind' THEN
    -- DIRECT quote insert: premium = artifact SOFTENED premium; basis = the DB
    -- rater's own breakdown (faithful provenance), tagged with the softening. NOT
    -- create_quote (which would re-rate to the un-softened base).
    v_premium := (p->'quote'->>'premium')::numeric;
    SELECT record_id INTO v_rec FROM state_rating_table_versions
      WHERE state = v_state AND effective_range @> now() AND superseded_by IS NULL
      ORDER BY lower(effective_range) DESC LIMIT 1;
    SELECT breakdown INTO v_basis
      FROM compute_indicative_premium(v_cat::vehicle_category_t, v_value, v_state::char(2));
    v_basis := v_basis
      || jsonb_build_object('softening_index', (p->'quote'->>'softening_index')::numeric,
                            'sold_premium', v_premium,
                            'canonical_base_premium', (p->'quote'->>'base_premium')::numeric);
    INSERT INTO quotes (application_id, state_rating_table_record_id, program_id,
                        premium_amount, rating_basis, status,
                        broker_channel, broker_commission_rate, quoted_by, quoted_at)
    VALUES (v_app, v_rec, NULL, v_premium, v_basis, 'issued',
            '__CHAN__'::broker_channel_t, __RATE__, p_by, v_submitted::timestamptz)
    RETURNING quote_id INTO v_quote;

    v_policy := bind_policy(v_quote, p->'policy'->>'policy_number', p_by,
                            (p->'policy'->>'effective_date')::timestamptz);
  END IF;

  INSERT INTO canonical_load_disposition (application_id, submission_id, seq,
                                          artifact_disposition, engine_action)
  VALUES (v_app, (p->>'submission_id')::uuid, (p->>'seq')::int, v_disp, v_action);

  art_policy_id := p->'policy'->>'policy_id';
  db_policy_id  := v_policy;
  RETURN NEXT;
END;
$fn$ LANGUAGE plpgsql;
"""


def full_load(cur, data):
    subs = data["submissions"]
    helper_sql = (CREATE_HELPER
                  .replace("__CHAN__", BROKER_CHANNEL)
                  .replace("__RATE__", str(BROKER_COMMISSION_RATE)))
    cur.execute("DROP FUNCTION IF EXISTS pg_temp._canon_load_one(jsonb, text)")
    cur.execute(helper_sql)

    art_to_db = {}   # artifact policy_id -> DB policy_id
    counts = {"bind": 0, "refer": 0, "decline": 0}
    t0 = time.time()
    for i, s in enumerate(subs, 1):
        cur.execute("SELECT art_policy_id, db_policy_id FROM pg_temp._canon_load_one(%s::jsonb, %s)",
                    (json.dumps(s), PERFORMED_BY))
        art_pid, db_pid = cur.fetchone()
        counts[s["disposition"]] += 1
        if db_pid is not None:
            art_to_db[art_pid] = db_pid
        if i % 500 == 0:
            print(f"  loaded {i}/{len(subs)}  ({time.time()-t0:.0f}s)")
    print(f"submissions loaded: {counts} in {time.time()-t0:.0f}s")

    # E. policy-period claims, joined artifact policy_id -> DB policy_id.
    claims = data["policy_period_claims"]
    rows = []
    missing = 0
    for c in claims:
        db_pid = art_to_db.get(c["policy_id"])
        if db_pid is None:
            missing += 1
            continue
        rows.append((c["claim_id"], db_pid, c["date_of_loss"], c["incurred"], c["status"]))
    if missing:
        raise SystemExit(f"CLAIMS JOIN: {missing} claims reference a policy_id with no bound policy.")
    from psycopg2.extras import execute_values
    execute_values(
        cur,
        "INSERT INTO canonical_policy_period_claims (claim_id, policy_id, date_of_loss, incurred, status) VALUES %s",
        rows,
    )
    print(f"policy-period claims loaded: {len(rows)}")
    return counts


def main(argv):
    ap = argparse.ArgumentParser(description="Load canonical book into luxauto_demo (ADR 0046).")
    ap.add_argument("--artifact", default=DEFAULT_ARTIFACT)
    ap.add_argument("--force", action="store_true",
                    help="allow load even if applications table is non-empty (default: refuse)")
    args = ap.parse_args(argv)

    guard_env()
    data = load_artifact(args.artifact)
    snap = data["rating_snapshot"]
    subs = data["submissions"]

    conn = psycopg2.connect()
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            guard_live(cur)
            cur.execute("SET LOCAL synchronous_commit = off")

            cur.execute("SELECT count(*) FROM applications")
            existing = cur.fetchone()[0]
            if existing and not args.force:
                raise SystemExit(
                    f"REFUSING: applications table is not empty ({existing} rows). "
                    f"Rebuild the schema first (the wrapper does), or pass --force."
                )

            print("== A. reseed rating world ==")
            reseed_rating_world(cur, snap)
            print("== B. rating sanity ==")
            rating_sanity(cur, subs)
            print("== C/D/E. hybrid load ==")
            cur.execute(CREATE_TABLES)
            counts = full_load(cur, data)

        conn.commit()
        print("COMMIT OK")
    except Exception:
        conn.rollback()
        print("ROLLED BACK (no partial load).")
        raise
    finally:
        conn.close()

    exp = data["summary"]
    print(f"\nexpected artifact mix: bind={exp['binds']} refer={exp['refers']} decline={exp['declines']}")
    print(f"loaded mix:            bind={counts['bind']} refer={counts['refer']} decline={counts['decline']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
