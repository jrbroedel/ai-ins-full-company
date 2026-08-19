-- Behavioural tests for ADR 0026: referral engine, rules AL-01, CP-02, DH-01, PC-03.
--
-- The four confirmed-and-queued rules only. Each rule function writes exactly one
-- append-only decision_log row (fired or not, reason_code always set), and the
-- orchestrator composes them and returns the most-severe action. The other 11
-- matrix rules are out of scope (ADR 0026).
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, RAISE on any failed assertion,
-- IS DISTINCT FROM wherever a SELECT INTO could read NULL. now() is the
-- transaction start and constant across the suite, so look-back boundaries are
-- deterministic to the day.

\set ON_ERROR_STOP on
BEGIN;

-- Fixture: applicant + application with a chosen garaging state and submit date.
CREATE FUNCTION pg_temp.mk_app(p_tag TEXT, p_state CHAR(2), p_submitted TIMESTAMPTZ DEFAULT now())
RETURNS UUID AS $fx$
DECLARE v_applicant UUID; v_app UUID;
BEGIN
  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0026-' || p_tag) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state, submitted_at)
  VALUES (v_applicant, 'submitted', p_state, p_submitted) RETURNING application_id INTO v_app;
  RETURN v_app;
END;
$fx$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.add_vehicle(p_app UUID, p_value NUMERIC)
RETURNS VOID AS $fx$
BEGIN
  INSERT INTO vehicles (application_id, year, make, model, vehicle_category, garaging_state, current_appraised_value)
  VALUES (p_app, 2024, 'Ferrari', 'SF90', 'exotic', 'CA', p_value);
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  AL-01: 2+ at-fault claims OR a single claim >= 30% of the priciest
--     vehicle's appraised value; NULL paid_amount skipped in the severity limb;
--     boundary mutation-tested at 30%.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_action referral_action_t; v_fired BOOLEAN;
BEGIN
  BEGIN
    -- (a) frequency limb: 2 at-fault claims, neither severe -> fires.
    v_app := pg_temp.mk_app('T1a', 'CA');
    PERFORM pg_temp.add_vehicle(v_app, 1000000);
    INSERT INTO claims_history (application_id, claim_date, claim_type, at_fault, paid_amount)
    VALUES (v_app, (now() - interval '1 year')::date, 'collision', true, 1000),
           (v_app, (now() - interval '2 years')::date, 'collision', true, 1000);
    v_action := evaluate_al01(v_app);
    IF v_action IS DISTINCT FROM 'MANUAL_REVIEW_REQUIRED' THEN
      RAISE EXCEPTION '0026-T1 FAILED: 2 at-fault claims returned %, expected MANUAL_REVIEW_REQUIRED', v_action;
    END IF;
    SELECT fired INTO v_fired FROM decision_log WHERE application_id = v_app AND rule_id = 'AL-01';
    IF v_fired IS DISTINCT FROM true THEN
      RAISE EXCEPTION '0026-T1 FAILED: AL-01 decision_log row not marked fired for the frequency limb';
    END IF;

    -- (b) severity limb, exactly at 30%: 1 vehicle @1,000,000, 1 claim @300,000 -> fires.
    v_app := pg_temp.mk_app('T1b', 'CA');
    PERFORM pg_temp.add_vehicle(v_app, 1000000);
    INSERT INTO claims_history (application_id, claim_date, claim_type, at_fault, paid_amount)
    VALUES (v_app, (now() - interval '1 year')::date, 'collision', true, 300000);
    IF evaluate_al01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_REQUIRED' THEN
      RAISE EXCEPTION '0026-T1 FAILED: a single claim at exactly 30%% of max value did not fire AL-01';
    END IF;

    -- (c) just under: 1 claim @299,999.99 (< 30% of 1,000,000) and only 1 claim -> not fired.
    v_app := pg_temp.mk_app('T1c', 'CA');
    PERFORM pg_temp.add_vehicle(v_app, 1000000);
    INSERT INTO claims_history (application_id, claim_date, claim_type, at_fault, paid_amount)
    VALUES (v_app, (now() - interval '1 year')::date, 'collision', true, 299999.99);
    IF evaluate_al01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T1 FAILED: a single claim just under 30%% fired AL-01 (boundary is inclusive-at, not below)';
    END IF;

    -- (d) NULL paid_amount is skipped in the severity limb, no error; only 1 claim -> not fired.
    v_app := pg_temp.mk_app('T1d', 'CA');
    PERFORM pg_temp.add_vehicle(v_app, 1000000);
    INSERT INTO claims_history (application_id, claim_date, claim_type, at_fault, paid_amount)
    VALUES (v_app, (now() - interval '1 year')::date, 'collision', true, NULL);
    IF evaluate_al01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T1 FAILED: a NULL-paid_amount claim was not skipped cleanly in the severity limb';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0026-T1 pass: AL-01 fires on frequency and on the 30%% severity boundary, skips NULL paid_amount, and clears just under';
END $$;

-- ---------------------------------------------------------------------------
-- T2  CP-02: aggregate appraised value STRICTLY over $2,000,000 fires; at/under
--     does not. Boundary mutation-tested.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID;
BEGIN
  BEGIN
    -- Just over: 2,000,000.01 -> fires MANUAL_REVIEW_SENIOR.
    v_app := pg_temp.mk_app('T2a', 'CA');
    PERFORM pg_temp.add_vehicle(v_app, 1500000);
    PERFORM pg_temp.add_vehicle(v_app, 500000.01);
    IF evaluate_cp02(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T2 FAILED: aggregate 2,000,000.01 did not fire CP-02 as MANUAL_REVIEW_SENIOR';
    END IF;

    -- Exactly at the cap: 2,000,000.00 -> does not fire.
    v_app := pg_temp.mk_app('T2b', 'CA');
    PERFORM pg_temp.add_vehicle(v_app, 1500000);
    PERFORM pg_temp.add_vehicle(v_app, 500000);
    IF evaluate_cp02(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T2 FAILED: aggregate exactly 2,000,000 fired CP-02 (cap is strictly-over)';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0026-T2 pass: CP-02 fires just over $2M and clears exactly at it';
END $$;

-- ---------------------------------------------------------------------------
-- T3  DH-01: DUI conviction within 5 years, spanning applicant and additional
--     drivers; reckless-driving-only does NOT fire (current narrow scope);
--     non-convicted DUI does not fire; look-back boundary mutation-tested.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_driver UUID;
BEGIN
  BEGIN
    -- (a) applicant DUI conviction, 1 year ago -> fires MANUAL_REVIEW_SENIOR.
    v_app := pg_temp.mk_app('T3a', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'DUI', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T3 FAILED: an applicant DUI conviction did not fire DH-01 as MANUAL_REVIEW_SENIOR';
    END IF;

    -- (b) additional driver's DUI conviction -> fires (spans all drivers).
    v_app := pg_temp.mk_app('T3b', 'CA');
    INSERT INTO additional_drivers (application_id, name) VALUES (v_app, 'Spouse') RETURNING driver_id INTO v_driver;
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, v_driver, (now() - interval '6 months')::date, 'DUI', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T3 FAILED: an additional driver''s DUI conviction did not fire DH-01';
    END IF;

    -- (c) reckless-driving-only conviction -> does NOT fire (DUI-only scope).
    v_app := pg_temp.mk_app('T3c', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'reckless_driving', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a reckless-driving-only record fired DH-01 (scope must be DUI-only for now)';
    END IF;

    -- (d) non-convicted DUI -> does NOT fire (threshold is conviction).
    v_app := pg_temp.mk_app('T3d', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'DUI', false, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a non-convicted DUI fired DH-01 (must require conviction)';
    END IF;

    -- (e) look-back boundary: DUI exactly 5 years ago fires; one day earlier does not.
    v_app := pg_temp.mk_app('T3e_in', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '5 years')::date, 'DUI', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a DUI exactly 5 years ago did not fire (window is inclusive at 5 years)';
    END IF;

    v_app := pg_temp.mk_app('T3e_out', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '5 years' - interval '1 day')::date, 'DUI', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a DUI 5 years + 1 day ago fired (outside the look-back)';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0026-T3 pass: DH-01 fires on applicant/additional-driver DUI convictions, ignores reckless-only and non-convicted, boundary exact at 5 years';
END $$;

-- ---------------------------------------------------------------------------
-- T4  PC-03: fires when the garaging state has no active rating-table record;
--     clears once one exists.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID;
BEGIN
  BEGIN
    -- 'ZZ' is unlicensed (no rating table) -> fires MANUAL_REVIEW_REQUIRED.
    v_app := pg_temp.mk_app('T4', 'ZZ');
    IF evaluate_pc03(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_REQUIRED' THEN
      RAISE EXCEPTION '0026-T4 FAILED: an unlicensed garaging state did not fire PC-03 as MANUAL_REVIEW_REQUIRED';
    END IF;

    -- Onboard 'ZZ' (active now) -> PC-03 clears. (Also seeds the short-rate factor,
    -- ADR 0025 - harmless here.)
    INSERT INTO state_rating_table_versions
      (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
    VALUES ('ZZ', 'ZZ DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0026-T4',
            tstzrange(now() - interval '1 year', now() + interval '1 year', '[)'));
    IF evaluate_pc03(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T4 FAILED: PC-03 still fired after an active rating-table record was created for the state';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0026-T4 pass: PC-03 fires with no active rating table and clears once one exists';
END $$;

-- ---------------------------------------------------------------------------
-- T5  Orchestrator: exactly four decision_log rows per call (one per rule,
--     fired or not), and the most-severe action wins across two combinations.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_action referral_action_t; v_n INT;
        v_al BOOLEAN; v_cp BOOLEAN; v_dh BOOLEAN; v_pc BOOLEAN;
BEGIN
  BEGIN
    -- Combo 1: DUI (DH-01 -> SENIOR) + unlicensed state (PC-03 -> REQUIRED),
    -- small single vehicle, no claims. Most severe = MANUAL_REVIEW_SENIOR.
    v_app := pg_temp.mk_app('T5a', 'ZZ');
    PERFORM pg_temp.add_vehicle(v_app, 500000);
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'DUI', true, 'MVR');

    v_action := evaluate_application_referrals(v_app);
    IF v_action IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T5 FAILED: combo 1 returned %, expected MANUAL_REVIEW_SENIOR (most severe of SENIOR/REQUIRED)', v_action;
    END IF;

    -- One row per rule (five since ADR 0028 added EL-01), with the expected
    -- fired flags on the four ADR 0026 rules.
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app;
    IF v_n <> 5 THEN
      RAISE EXCEPTION '0026-T5 FAILED: expected 5 decision_log rows from one orchestrator call, got %', v_n;
    END IF;
    SELECT (SELECT fired FROM decision_log WHERE application_id = v_app AND rule_id = 'AL-01'),
           (SELECT fired FROM decision_log WHERE application_id = v_app AND rule_id = 'CP-02'),
           (SELECT fired FROM decision_log WHERE application_id = v_app AND rule_id = 'DH-01'),
           (SELECT fired FROM decision_log WHERE application_id = v_app AND rule_id = 'PC-03')
      INTO v_al, v_cp, v_dh, v_pc;
    IF (v_al, v_cp, v_dh, v_pc) IS DISTINCT FROM (false, false, true, true) THEN
      RAISE EXCEPTION '0026-T5 FAILED: combo 1 fired flags AL/CP/DH/PC = %/%/%/%, expected false/false/true/true', v_al, v_cp, v_dh, v_pc;
    END IF;

    -- Combo 2: clean application, licensed state -> nothing fires -> AUTO_PROCEED,
    -- five rows all fired=false (AL/CP/DH/PC/EL).
    v_app := pg_temp.mk_app('T5b', 'QQ');
    PERFORM pg_temp.add_vehicle(v_app, 500000);
    INSERT INTO state_rating_table_versions
      (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
    VALUES ('QQ', 'QQ DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0026-T5b',
            tstzrange(now() - interval '1 year', now() + interval '1 year', '[)'));

    v_action := evaluate_application_referrals(v_app);
    IF v_action IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T5 FAILED: a clean, licensed application returned %, expected AUTO_PROCEED', v_action;
    END IF;
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app AND NOT fired;
    IF v_n <> 5 THEN
      RAISE EXCEPTION '0026-T5 FAILED: expected 5 non-fired decision_log rows for a clean application, got %', v_n;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0026-T5 pass: the orchestrator writes 4 rows per call and returns the most-severe fired action';
END $$;

-- ---------------------------------------------------------------------------
-- T6  decision_log stays append-only under this new write path: the rows the
--     referral engine writes cannot be updated or deleted.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_log UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    v_app := pg_temp.mk_app('T6', 'ZZ');
    PERFORM evaluate_pc03(v_app);
    SELECT log_id INTO v_log FROM decision_log WHERE application_id = v_app AND rule_id = 'PC-03';

    v_ok := false;
    BEGIN
      UPDATE decision_log SET notes = 'tampered' WHERE log_id = v_log;
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%append-only%' THEN
      RAISE EXCEPTION '0026-T6 FAILED: a referral decision_log row was UPDATE-able (ok=%, err=%)', v_ok, v_err;
    END IF;

    v_ok := false;
    BEGIN
      DELETE FROM decision_log WHERE log_id = v_log;
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%append-only%' THEN
      RAISE EXCEPTION '0026-T6 FAILED: a referral decision_log row was DELETE-able (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0026-T6 pass: referral decision_log rows are append-only (no update, no delete)';
END $$;

-- ---------------------------------------------------------------------------
-- T7  The severity invariant the orchestrator relies on: referral_action_t is
--     ordered least-to-most severe, so GREATEST picks the most severe. A future
--     reorder of the enum fails here rather than silently mis-routing.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    IF NOT ('HARD_DECLINE_COMPLIANCE'::referral_action_t > 'DECLINE_RECOMMENDED'::referral_action_t
        AND 'DECLINE_RECOMMENDED'::referral_action_t   > 'MANUAL_REVIEW_SENIOR'::referral_action_t
        AND 'MANUAL_REVIEW_SENIOR'::referral_action_t  > 'MANUAL_REVIEW_REQUIRED'::referral_action_t
        AND 'MANUAL_REVIEW_REQUIRED'::referral_action_t > 'INFORMATION_REQUEST'::referral_action_t
        AND 'INFORMATION_REQUEST'::referral_action_t   > 'AUTO_PROCEED_WITH_FLAG'::referral_action_t
        AND 'AUTO_PROCEED_WITH_FLAG'::referral_action_t > 'AUTO_PROCEED'::referral_action_t) THEN
      RAISE EXCEPTION '0026-T7 FAILED: referral_action_t is not in ascending severity order - the orchestrator''s GREATEST-based routing is broken';
    END IF;
    -- GREATEST over the three values today's rules actually produce.
    IF GREATEST('AUTO_PROCEED'::referral_action_t, 'MANUAL_REVIEW_REQUIRED'::referral_action_t,
                'MANUAL_REVIEW_SENIOR'::referral_action_t, 'AUTO_PROCEED'::referral_action_t)
       IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR'::referral_action_t THEN
      RAISE EXCEPTION '0026-T7 FAILED: GREATEST over referral_action_t did not select the most severe value';
    END IF;

    -- GREATEST exercised across the FOUR values no current rule emits
    -- (HARD_DECLINE_COMPLIANCE, DECLINE_RECOMMENDED, INFORMATION_REQUEST,
    -- AUTO_PROCEED_WITH_FLAG), so the full-enum routing the orchestrator relies on
    -- is verified now - while only 3 of 7 values are load-bearing - rather than
    -- when a future rule first produces one of them.
    IF GREATEST('HARD_DECLINE_COMPLIANCE'::referral_action_t, 'AUTO_PROCEED_WITH_FLAG'::referral_action_t)
       IS DISTINCT FROM 'HARD_DECLINE_COMPLIANCE'::referral_action_t
    OR GREATEST('DECLINE_RECOMMENDED'::referral_action_t, 'MANUAL_REVIEW_SENIOR'::referral_action_t)
       IS DISTINCT FROM 'DECLINE_RECOMMENDED'::referral_action_t
    OR GREATEST('INFORMATION_REQUEST'::referral_action_t, 'AUTO_PROCEED'::referral_action_t)
       IS DISTINCT FROM 'INFORMATION_REQUEST'::referral_action_t
    OR GREATEST('AUTO_PROCEED'::referral_action_t, 'AUTO_PROCEED_WITH_FLAG'::referral_action_t)
       IS DISTINCT FROM 'AUTO_PROCEED_WITH_FLAG'::referral_action_t
    OR GREATEST('AUTO_PROCEED'::referral_action_t, 'AUTO_PROCEED_WITH_FLAG'::referral_action_t,
                'INFORMATION_REQUEST'::referral_action_t, 'MANUAL_REVIEW_REQUIRED'::referral_action_t,
                'MANUAL_REVIEW_SENIOR'::referral_action_t, 'DECLINE_RECOMMENDED'::referral_action_t,
                'HARD_DECLINE_COMPLIANCE'::referral_action_t)
       IS DISTINCT FROM 'HARD_DECLINE_COMPLIANCE'::referral_action_t THEN
      RAISE EXCEPTION '0026-T7 FAILED: GREATEST mis-selected across the currently-untested referral_action_t values - the full-enum severity ordering is wrong';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0026-T7 pass: referral_action_t ascending-severity verified across all 7 values; GREATEST selects correctly including the 4 not yet produced by any rule';
END $$;

ROLLBACK;

\echo '0026: 7/7 cases passed (nothing committed)'
