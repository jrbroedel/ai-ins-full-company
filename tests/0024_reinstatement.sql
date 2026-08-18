-- Behavioural tests for ADR 0024: backdated reinstatement-as-new-business.
--
-- REBUILT after the original gap-only ADR 0024 design was rejected on business
-- review. The first version of this file tested reverse-the-same-cancellation
-- with a gap-only charge (the 209.58 / 246.57 worked examples); that mechanism
-- was scrapped because a policy on risk for only 10-14 days against a $1M+ limit
-- is a risk/premium mismatch the carrier will not take. This file tests what
-- replaced it: reinstatement is ALWAYS a new policy, bound as new business via
-- the ADR 0023 path, backdated to the gap start so coverage is continuous, at
-- full annual premium. The rejected suite is preserved out-of-tree as a record;
-- this is deliberately not a patch of it. See docs/decisions/0024.
--
-- Same discipline as the 0017/0018/0021/0023 suites: one transaction rolled back
-- at the end, one self-unwinding DO block per case, SET CONSTRAINTS ALL IMMEDIATE
-- instead of committing, RAISE on any failed assertion, IS DISTINCT FROM wherever
-- a SELECT INTO could read NULL off a missing row, and rejection cases asserting
-- on the error MESSAGE, not merely that something failed.
--
-- The 14-day window is measured from the cancellation effective date to now().
-- now() is the TRANSACTION start time in Postgres and is constant across this
-- whole suite, so a fixture that cancels at exactly now() - 14 days is exactly
-- 14 days old when reinstate_policy() evaluates the window - the boundary is
-- deterministic to the second, not a timing race.

\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- Fixture. A backdated reinstatement needs (a) a prior policy that is bound and
-- then cancelled at a chosen past date, and (b) the returning customer's fresh,
-- ISSUED quote to bind as new business. Both are built on one application (same
-- vehicles/drivers), so the prior policy uses a first quote (bound) and the
-- reinstatement uses a second quote (still issued).
--
-- The prior policy is inserted directly (like the 0018 suite) rather than via
-- bind_policy(), because its term must straddle the backdated cancellation date
-- and bind_policy() would otherwise anchor it at now(). One state per call:
-- state_rating_table_versions carries an exclusion on (state, effective_range).
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.mk(
  p_tag TEXT,
  p_state CHAR(2),
  p_premium NUMERIC,
  p_cancel_at TIMESTAMPTZ,
  OUT cancellation_id UUID,
  OUT new_quote_id UUID,
  OUT prior_policy_id UUID
) AS $fx$
DECLARE
  v_rating UUID; v_applicant UUID; v_app UUID; v_vehicle UUID; v_driver UUID;
  v_program UUID; v_quote1 UUID;
  v_prior_term TSTZRANGE := tstzrange(now() - interval '60 days', now() + interval '305 days', '[)');
  v_program_term TSTZRANGE := tstzrange(now() - interval '2 years', now() + interval '2 years', '[)');
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code,
     serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX',
          'SERFF-0024-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO v_rating;

  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0024-' || p_tag) RETURNING applicant_id INTO v_applicant;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'bound', p_state) RETURNING application_id INTO v_app;

  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state)
  VALUES (v_app, 2024, 'Aston Martin', 'DB12', 'VIN0024' || p_tag, 'exotic', p_state)
  RETURNING vehicle_id INTO v_vehicle;

  INSERT INTO additional_drivers (application_id, name, date_of_birth)
  VALUES (v_app, 'Driver ' || p_tag, DATE '1980-01-01') RETURNING driver_id INTO v_driver;

  INSERT INTO insurance_programs (program_name, capacity_provider_name, effective_range)
  VALUES ('0024-' || p_tag, 'Fronting Co', v_program_term) RETURNING program_id INTO v_program;

  INSERT INTO program_participants
    (program_id, participant_type, participant_name, share_percentage, commission_rate, effective_range)
  VALUES (v_program, 'capacity_provider', 'Fronting Co', 100, 0, v_program_term);

  -- Prior policy: a first quote, bound, term straddling the backdated cancel date.
  INSERT INTO quotes
    (application_id, state_rating_table_record_id, program_id, premium_amount, rating_basis, status,
     broker_channel, broker_commission_rate)
  VALUES (v_app, v_rating, v_program, p_premium, '{}'::jsonb, 'bound',
          'retail', 10)
  RETURNING quote_id INTO v_quote1;

  INSERT INTO policies (quote_id, policy_number, effective_range, status)
  VALUES (v_quote1, 'POL-0024-' || p_tag || '-PRIOR', v_prior_term, 'active')
  RETURNING policy_id INTO prior_policy_id;

  INSERT INTO policy_vehicles
    (policy_id, source_vehicle_id, effective_range, year, make, model, vin, vehicle_category, garaging_state)
  VALUES (prior_policy_id, v_vehicle, v_prior_term, 2024, 'Aston Martin', 'DB12', 'VIN0024' || p_tag, 'exotic', p_state);
  INSERT INTO policy_drivers
    (policy_id, source_driver_id, effective_range, name, date_of_birth)
  VALUES (prior_policy_id, v_driver, v_prior_term, 'Driver ' || p_tag, DATE '1980-01-01');
  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (prior_policy_id, 'bound', '0024-suite', 'fixture prior policy');

  SET CONSTRAINTS ALL IMMEDIATE;

  -- Cancel the prior policy at the chosen (backdated) date - pro_rata, so no
  -- filed short-rate table is needed. This is what leaves coverage lapsed.
  cancellation_id := cancel_policy(prior_policy_id, 'insured_initiated', 'CX_INSURED_REQUEST',
                                   'pro_rata', p_cancel_at, 'lapsed, to be reinstated', '0024-suite');

  -- The returning customer's fresh, ISSUED quote (new business), ready to bind.
  INSERT INTO quotes
    (application_id, state_rating_table_record_id, program_id, premium_amount, rating_basis, status,
     broker_channel, broker_commission_rate)
  VALUES (v_app, v_rating, v_program, p_premium, '{}'::jsonb, 'issued',
          'retail', 10)
  RETURNING quote_id INTO new_quote_id;
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  Happy path: a policy that lapsed 1 day ago is reinstated as new business,
--     backdated to the gap start. Asserts every fact the mechanism promises:
--     the new policy's inception is exactly the gap start, its term is a full
--     year (no stub), it carries the full annual premium (no proration), it is
--     linked back to the prior policy, the audit row is written, and the prior
--     policy survives as cancelled (it is NOT reversed).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cx UUID; v_quote UUID; v_prior UUID; v_new UUID;
        v_gap_start TIMESTAMPTZ; v_range TSTZRANGE; v_status policy_status_t;
        v_link UUID; v_prem NUMERIC; v_veh_lo TIMESTAMPTZ; v_n INT;
        v_r_new UUID; v_r_prior UUID; v_r_cx UUID; v_r_gap TIMESTAMPTZ; v_r_att TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T1', 'CA', 10000, now() - interval '1 day')
      INTO v_cx, v_quote, v_prior;
    SELECT lower(effective_range) INTO v_gap_start FROM policy_cancellations WHERE cancellation_id = v_cx;

    SELECT reinstate_policy(v_quote, v_cx, 'POL-0024-T1-NEW', 'ATTEST-0024-T1', '0024-suite') INTO v_new;

    -- A genuinely new, distinct, active policy.
    IF v_new IS NULL OR v_new = v_prior THEN
      RAISE EXCEPTION '0024-T1 FAILED: reinstatement did not create a new distinct policy (new=%, prior=%)', v_new, v_prior;
    END IF;
    SELECT status, effective_range INTO v_status, v_range FROM policies WHERE policy_id = v_new;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION '0024-T1 FAILED: new policy is %, expected active', v_status;
    END IF;

    -- (4) inception == gap start, exactly; and a full one-year term (no stub).
    IF lower(v_range) IS DISTINCT FROM v_gap_start THEN
      RAISE EXCEPTION '0024-T1 FAILED: new policy inception % is not the gap start %', lower(v_range), v_gap_start;
    END IF;
    IF upper(v_range) IS DISTINCT FROM v_gap_start + interval '1 year' THEN
      RAISE EXCEPTION '0024-T1 FAILED: new policy term is not a full year from the gap start, got %', v_range;
    END IF;

    -- The backdated inception flows to the snapshots too.
    SELECT lower(effective_range) INTO v_veh_lo FROM policy_vehicles WHERE policy_id = v_new;
    IF v_veh_lo IS DISTINCT FROM v_gap_start THEN
      RAISE EXCEPTION '0024-T1 FAILED: the new vehicle snapshot did not start at the backdated inception, got %', v_veh_lo;
    END IF;

    -- (5) linkage: reinstated_from_policy_id points at the prior policy.
    SELECT reinstated_from_policy_id INTO v_link FROM policies WHERE policy_id = v_new;
    IF v_link IS DISTINCT FROM v_prior THEN
      RAISE EXCEPTION '0024-T1 FAILED: reinstated_from_policy_id is %, expected the prior policy %', v_link, v_prior;
    END IF;

    -- (6) full annual premium, no proration: the new policy carries the quote's
    -- premium unchanged.
    SELECT q.premium_amount INTO v_prem
    FROM policies p JOIN quotes q ON q.quote_id = p.quote_id WHERE p.policy_id = v_new;
    IF v_prem IS DISTINCT FROM 10000 THEN
      RAISE EXCEPTION '0024-T1 FAILED: new policy premium is %, expected the full annual 10000 (no proration)', v_prem;
    END IF;

    -- (7) the audit row.
    SELECT new_policy_id, prior_policy_id, cancellation_id, gap_start, attestation_reference
      INTO v_r_new, v_r_prior, v_r_cx, v_r_gap, v_r_att
    FROM policy_reinstatements WHERE new_policy_id = v_new;
    IF (v_r_new, v_r_prior, v_r_cx, v_r_gap, v_r_att)
       IS DISTINCT FROM (v_new, v_prior, v_cx, v_gap_start, 'ATTEST-0024-T1') THEN
      RAISE EXCEPTION '0024-T1 FAILED: the reinstatement audit row is wrong: %/%/%/%/%',
        v_r_new, v_r_prior, v_r_cx, v_r_gap, v_r_att;
    END IF;

    -- The 'reinstated' event on the new policy, and the linkage events on both.
    SELECT count(*) INTO v_n FROM policy_events WHERE policy_id = v_new AND event_type = 'reinstated';
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0024-T1 FAILED: expected one reinstated event on the new policy, got %', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM policy_events
    WHERE event_type = 'reinstatement_linked' AND policy_id IN (v_new, v_prior);
    IF v_n <> 2 THEN
      RAISE EXCEPTION '0024-T1 FAILED: expected a reinstatement_linked event on each policy, got % total', v_n;
    END IF;

    -- The prior policy SURVIVES as cancelled - it is not reversed.
    IF (SELECT status FROM policies WHERE policy_id = v_prior) IS DISTINCT FROM 'cancelled' THEN
      RAISE EXCEPTION '0024-T1 FAILED: the prior policy is no longer cancelled - it must survive, not be reversed';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0024-T1 pass: backdated new policy at the gap start, full-year term, full premium, linked, audited; prior survives cancelled';
END $$;

-- ---------------------------------------------------------------------------
-- T2  The 14-day backdating window, mutation-tested to the second. now() is the
--     transaction start and constant here, so "cancelled exactly 14 days ago" is
--     exactly on the boundary when reinstate_policy() checks it.
--
--       - lapsed  1 day  ago  -> accepted
--       - lapsed 14 days ago  -> accepted (boundary, inclusive)
--       - lapsed 14 days + 1s -> REFUSED (just past the boundary)
--       - lapsed 15 days ago  -> REFUSED
--
--     A `<` where the code has `<=`, or a 13/15-day off-by-one, fails one edge.
--     Each sub-case gets its own fixture/state, since a success mutates state.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cx UUID; v_quote UUID; v_prior UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    -- 1 day: accepted.
    SELECT * FROM pg_temp.mk('T2a', 'NV', 10000, now() - interval '1 day') INTO v_cx, v_quote, v_prior;
    PERFORM reinstate_policy(v_quote, v_cx, 'POL-0024-T2a', 'ATTEST-0024-T2a', '0024-suite');

    -- Exactly 14 days: accepted (inclusive boundary).
    SELECT * FROM pg_temp.mk('T2b', 'AZ', 10000, now() - interval '14 days') INTO v_cx, v_quote, v_prior;
    PERFORM reinstate_policy(v_quote, v_cx, 'POL-0024-T2b', 'ATTEST-0024-T2b', '0024-suite');

    -- 14 days + 1 second: refused.
    SELECT * FROM pg_temp.mk('T2c', 'OR', 10000, now() - interval '14 days' - interval '1 second') INTO v_cx, v_quote, v_prior;
    v_ok := false;
    BEGIN
      PERFORM reinstate_policy(v_quote, v_cx, 'POL-0024-T2c', 'ATTEST-0024-T2c', '0024-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%REINSTATEMENT_WINDOW_EXPIRED%' THEN
      RAISE EXCEPTION '0024-T2 FAILED: a reinstatement one second past 14 days was not refused with REINSTATEMENT_WINDOW_EXPIRED (ok=%, err=%)', v_ok, v_err;
    END IF;
    -- Nothing partial survived: the issued quote is still issued, no new policy.
    IF (SELECT status FROM quotes WHERE quote_id = v_quote) IS DISTINCT FROM 'issued' THEN
      RAISE EXCEPTION '0024-T2 FAILED: a refused (just-past-window) reinstatement still bound the quote';
    END IF;

    -- 15 days: refused.
    SELECT * FROM pg_temp.mk('T2d', 'WA', 10000, now() - interval '15 days') INTO v_cx, v_quote, v_prior;
    v_ok := false;
    BEGIN
      PERFORM reinstate_policy(v_quote, v_cx, 'POL-0024-T2d', 'ATTEST-0024-T2d', '0024-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%REINSTATEMENT_WINDOW_EXPIRED%' THEN
      RAISE EXCEPTION '0024-T2 FAILED: a 15-day-old lapse was not refused with REINSTATEMENT_WINDOW_EXPIRED (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0024-T2 pass: the 14-day backdating window holds inclusively at the boundary and refuses past it';
END $$;

-- ---------------------------------------------------------------------------
-- T3  A missing attestation is refused - required unconditionally. Both NULL and
--     a blank/whitespace reference are rejected, and nothing is written: the
--     issued quote stays issued and no reinstatement row appears.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cx UUID; v_quote UUID; v_prior UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T3', 'CO', 10000, now() - interval '2 days') INTO v_cx, v_quote, v_prior;

    v_ok := false;
    BEGIN
      PERFORM reinstate_policy(v_quote, v_cx, 'POL-0024-T3', NULL, '0024-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%REINSTATEMENT_ATTESTATION_REQUIRED%' THEN
      RAISE EXCEPTION '0024-T3 FAILED: a null attestation was not refused with REINSTATEMENT_ATTESTATION_REQUIRED (ok=%, err=%)', v_ok, v_err;
    END IF;

    v_ok := false;
    BEGIN
      PERFORM reinstate_policy(v_quote, v_cx, 'POL-0024-T3', '   ', '0024-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%REINSTATEMENT_ATTESTATION_REQUIRED%' THEN
      RAISE EXCEPTION '0024-T3 FAILED: a blank attestation was not refused with REINSTATEMENT_ATTESTATION_REQUIRED (ok=%, err=%)', v_ok, v_err;
    END IF;

    IF (SELECT status FROM quotes WHERE quote_id = v_quote) IS DISTINCT FROM 'issued' THEN
      RAISE EXCEPTION '0024-T3 FAILED: a refused reinstatement still bound the quote';
    END IF;
    IF EXISTS (SELECT 1 FROM policy_reinstatements WHERE cancellation_id = v_cx) THEN
      RAISE EXCEPTION '0024-T3 FAILED: a refused reinstatement still wrote an audit row';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0024-T3 pass: a null or blank attestation is refused, and nothing is written';
END $$;

-- ---------------------------------------------------------------------------
-- T4  A cancellation that does not exist is refused, and a cancellation already
--     reinstated is refused (one reinstatement per cancellation). The second is
--     the id-based idempotency guard: reinstate once, then try the same
--     cancellation again.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cx UUID; v_quote UUID; v_prior UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T4', 'UT', 10000, now() - interval '3 days') INTO v_cx, v_quote, v_prior;

    -- Not found.
    v_ok := false;
    BEGIN
      PERFORM reinstate_policy(v_quote, uuid_generate_v4(), 'POL-0024-T4', 'ATTEST-0024-T4', '0024-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%REINSTATEMENT_CANCELLATION_NOT_FOUND%' THEN
      RAISE EXCEPTION '0024-T4 FAILED: an unknown cancellation was not refused with REINSTATEMENT_CANCELLATION_NOT_FOUND (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- First reinstatement succeeds.
    PERFORM reinstate_policy(v_quote, v_cx, 'POL-0024-T4-NEW', 'ATTEST-0024-T4', '0024-suite');

    -- Second reinstatement of the same cancellation: refused. (The already-exists
    -- guard is checked before the bind, so reusing the now-bound quote still
    -- surfaces REINSTATEMENT_ALREADY_EXISTS, not a quote-state error.)
    v_ok := false;
    BEGIN
      PERFORM reinstate_policy(v_quote, v_cx, 'POL-0024-T4-AGAIN', 'ATTEST-0024-T4', '0024-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%REINSTATEMENT_ALREADY_EXISTS%' THEN
      RAISE EXCEPTION '0024-T4 FAILED: a second reinstatement was not refused with REINSTATEMENT_ALREADY_EXISTS (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM policy_reinstatements WHERE cancellation_id = v_cx) <> 1 THEN
      RAISE EXCEPTION '0024-T4 FAILED: expected exactly one reinstatement row for the cancellation, got %',
        (SELECT count(*) FROM policy_reinstatements WHERE cancellation_id = v_cx);
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0024-T4 pass: an unknown cancellation and an already-reinstated one are both refused';
END $$;

-- ---------------------------------------------------------------------------
-- T5  A superseded cancellation (emptied by correct_policy_cancellation(), so
--     no longer the one in force) cannot be reinstated off - its gap start is
--     gone, and backdating to a date nobody cancelled at is refused.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cx UUID; v_quote UUID; v_prior UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T5', 'NM', 10000, now() - interval '5 days') INTO v_cx, v_quote, v_prior;

    -- Supersede the cancellation (correct it to a slightly different date); the
    -- original row is emptied.
    PERFORM correct_policy_cancellation(v_cx, now() - interval '4 days',
              'insured_initiated', 'CX_INSURED_REQUEST', 'pro_rata', 'corrected', '0024-suite');
    IF NOT (SELECT isempty(effective_range) FROM policy_cancellations WHERE cancellation_id = v_cx) THEN
      RAISE EXCEPTION '0024-T5 SETUP: the corrected cancellation was not emptied';
    END IF;

    v_ok := false;
    BEGIN
      PERFORM reinstate_policy(v_quote, v_cx, 'POL-0024-T5', 'ATTEST-0024-T5', '0024-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%REINSTATEMENT_CANCELLATION_NOT_IN_FORCE%' THEN
      RAISE EXCEPTION '0024-T5 FAILED: a superseded cancellation was not refused with REINSTATEMENT_CANCELLATION_NOT_IN_FORCE (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0024-T5 pass: a superseded (emptied) cancellation cannot be reinstated off';
END $$;

ROLLBACK;

\echo '0024: 5/5 cases passed (nothing committed)'
