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
-- ADR 0035: this suite writes state_rating_table_versions rows directly as fixtures;
-- the onboard_state() guard permits that through the escape flag, set for this
-- rolled-back test transaction (tests use the hatch; production goes through onboard_state).
SET LOCAL luxauto.onboarding_state = 'on';

-- Fixture: applicant + application with a chosen garaging state and submit date.
CREATE FUNCTION pg_temp.mk_app(p_tag TEXT, p_state CHAR(2), p_submitted TIMESTAMPTZ DEFAULT now())
RETURNS UUID AS $fx$
DECLARE v_applicant UUID; v_app UUID;
BEGIN
  -- date_of_birth / license_status / years_licensed populated so DH-04 (ADR 0037)
  -- does not fire on these fixtures - they exercise other rules, not the
  -- completeness gate.
  INSERT INTO applicants (first_name, last_name, date_of_birth, license_status, years_licensed)
  VALUES ('Test', '0026-' || p_tag, DATE '1980-01-01', 'valid', 20) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state, submitted_at)
  VALUES (v_applicant, 'submitted', p_state, p_submitted) RETURNING application_id INTO v_app;
  RETURN v_app;
END;
$fx$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.add_vehicle(p_app UUID, p_value NUMERIC)
RETURNS VOID AS $fx$
BEGIN
  -- vin / garaging_street populated for the same DH-04 reason.
  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state, garaging_street, current_appraised_value)
  VALUES (p_app, 2024, 'Ferrari', 'SF90', 'VIN0026' || left(md5(random()::text), 10), 'exotic', 'CA', '1 Test St', p_value);
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
-- T3  DH-01: DUI OR reckless-driving conviction within 5 years (ADR 0036 folded
--     reckless driving into the same look-back and MANUAL_REVIEW_SENIOR severity),
--     spanning applicant and additional drivers; non-convicted does not fire for
--     either type; look-back boundary mutation-tested for both types; the
--     reason_code is type-aware, with DUI taking precedence over reckless when
--     both are present.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_driver UUID; v_reason TEXT;
BEGIN
  BEGIN
    -- (a) applicant DUI conviction, 1 year ago -> fires MANUAL_REVIEW_SENIOR,
    --     reason_code DH01_DUI_WITHIN_LOOKBACK.
    v_app := pg_temp.mk_app('T3a', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'DUI', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T3 FAILED: an applicant DUI conviction did not fire DH-01 as MANUAL_REVIEW_SENIOR';
    END IF;
    SELECT reason_code INTO v_reason FROM decision_log WHERE application_id = v_app AND rule_id = 'DH-01';
    IF v_reason IS DISTINCT FROM 'DH01_DUI_WITHIN_LOOKBACK' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a DUI conviction logged reason_code %, expected DH01_DUI_WITHIN_LOOKBACK', v_reason;
    END IF;

    -- (b) additional driver's DUI conviction -> fires (spans all drivers).
    v_app := pg_temp.mk_app('T3b', 'CA');
    INSERT INTO additional_drivers (application_id, name) VALUES (v_app, 'Spouse') RETURNING driver_id INTO v_driver;
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, v_driver, (now() - interval '6 months')::date, 'DUI', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T3 FAILED: an additional driver''s DUI conviction did not fire DH-01';
    END IF;

    -- (c) reckless-driving-ONLY conviction -> now FIRES MANUAL_REVIEW_SENIOR
    --     (ADR 0036), with the type-specific reason_code DH01_RECKLESS_WITHIN_LOOKBACK.
    v_app := pg_temp.mk_app('T3c', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'reckless_driving', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a reckless-driving conviction did not fire DH-01 as MANUAL_REVIEW_SENIOR (ADR 0036 folded it in)';
    END IF;
    SELECT reason_code INTO v_reason FROM decision_log WHERE application_id = v_app AND rule_id = 'DH-01';
    IF v_reason IS DISTINCT FROM 'DH01_RECKLESS_WITHIN_LOOKBACK' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a reckless-only conviction logged reason_code %, expected DH01_RECKLESS_WITHIN_LOOKBACK', v_reason;
    END IF;

    -- (c2) BOTH DUI and reckless convictions in-window -> fires; DUI takes
    --      precedence in the reason_code (one row per rule, so the code names the
    --      more serious trigger). matched_types in notes records both.
    v_app := pg_temp.mk_app('T3c2', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'reckless_driving', true, 'MVR'),
           (v_app, NULL, (now() - interval '2 years')::date, 'DUI', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a DUI+reckless combination did not fire DH-01';
    END IF;
    SELECT reason_code INTO v_reason FROM decision_log WHERE application_id = v_app AND rule_id = 'DH-01';
    IF v_reason IS DISTINCT FROM 'DH01_DUI_WITHIN_LOOKBACK' THEN
      RAISE EXCEPTION '0026-T3 FAILED: with both DUI and reckless present, reason_code was %, expected DH01_DUI_WITHIN_LOOKBACK (DUI precedence)', v_reason;
    END IF;

    -- (d) non-convicted DUI -> does NOT fire (threshold is conviction).
    v_app := pg_temp.mk_app('T3d', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'DUI', false, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a non-convicted DUI fired DH-01 (must require conviction)';
    END IF;

    -- (d2) non-convicted reckless driving -> does NOT fire (same conviction threshold).
    v_app := pg_temp.mk_app('T3d2', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'reckless_driving', false, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a non-convicted reckless-driving record fired DH-01 (must require conviction)';
    END IF;

    -- (e) DUI look-back boundary: exactly 5 years ago fires; one day earlier does not.
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

    -- (e2) reckless look-back boundary: the SAME 5-year window (ADR 0036 - "same
    --      five year look"). Exactly 5 years ago fires; one day earlier does not.
    v_app := pg_temp.mk_app('T3e2_in', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '5 years')::date, 'reckless_driving', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a reckless conviction exactly 5 years ago did not fire (window is inclusive at 5 years)';
    END IF;

    v_app := pg_temp.mk_app('T3e2_out', 'CA');
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '5 years' - interval '1 day')::date, 'reckless_driving', true, 'MVR');
    IF evaluate_dh01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0026-T3 FAILED: a reckless conviction 5 years + 1 day ago fired (outside the look-back)';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0026-T3 pass: DH-01 fires MANUAL_REVIEW_SENIOR on applicant/additional-driver DUI or reckless-driving convictions within 5 years (type-aware reason_code, DUI precedence), ignores non-convicted, boundary exact at 5 years for both types';
END $$;

-- ---------------------------------------------------------------------------
-- T4  PC-03: fires when the garaging state has no active rating-table record,
--     now routing to AUTO_PROCEED_WITH_FLAG (ADR 0036, was MANUAL_REVIEW_REQUIRED)
--     while still firing and still logging its reason_code; clears once a record
--     exists.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_n INT; v_fired BOOLEAN; v_act referral_action_t; v_reason TEXT;
BEGIN
  BEGIN
    -- 'ZZ' is unlicensed (no rating table) -> fires AUTO_PROCEED_WITH_FLAG (ADR
    -- 0036). The rule still FIRES and still writes its reason_code per the
    -- matrix's rule 4 - it just no longer routes to a human before proceeding.
    v_app := pg_temp.mk_app('T4', 'ZZ');
    IF evaluate_pc03(v_app) IS DISTINCT FROM 'AUTO_PROCEED_WITH_FLAG' THEN
      RAISE EXCEPTION '0026-T4 FAILED: an unlicensed garaging state did not route PC-03 to AUTO_PROCEED_WITH_FLAG (ADR 0036)';
    END IF;

    -- fired=true alongside AUTO_PROCEED_WITH_FLAG is a combination no rule emitted
    -- before ADR 0036 - assert it explicitly on the logged row (not just via the
    -- return value): exactly one PC-03 row, fired, the new action, and the
    -- unredacted reason_code present (rule 4).
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app AND rule_id = 'PC-03';
    SELECT fired, action_taken, reason_code INTO v_fired, v_act, v_reason
      FROM decision_log WHERE application_id = v_app AND rule_id = 'PC-03';
    IF (v_n, v_fired, v_act, v_reason)
       IS DISTINCT FROM (1, true, 'AUTO_PROCEED_WITH_FLAG'::referral_action_t, 'PC03_OUT_OF_LICENSED_TERRITORY') THEN
      RAISE EXCEPTION '0026-T4 FAILED: PC-03 fired row is rows=%/fired=%/action=%/reason=%, expected 1/true/AUTO_PROCEED_WITH_FLAG/PC03_OUT_OF_LICENSED_TERRITORY',
        v_n, v_fired, v_act, v_reason;
    END IF;

    -- Onboard 'ZZ' (active now) -> PC-03 clears to AUTO_PROCEED. (Also seeds the
    -- short-rate factor, ADR 0025 - harmless here.)
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
  RAISE NOTICE '0026-T4 pass: PC-03 fires AUTO_PROCEED_WITH_FLAG (fired, reason_code logged) with no active rating table and clears to AUTO_PROCEED once one exists';
END $$;

-- ---------------------------------------------------------------------------
-- T5  Orchestrator: exactly twelve decision_log rows per call (one per rule,
--     fired or not), and the most-severe action wins across two combinations.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_action referral_action_t; v_n INT;
        v_al BOOLEAN; v_cp BOOLEAN; v_dh BOOLEAN; v_pc BOOLEAN;
BEGIN
  BEGIN
    -- Combo 1: DUI (DH-01 -> SENIOR) + unlicensed state (PC-03 -> WITH_FLAG since
    -- ADR 0036), small single vehicle, no claims. Most severe = MANUAL_REVIEW_SENIOR
    -- (DH-01 still dominates; the PC-03 severity drop does not change the winner).
    v_app := pg_temp.mk_app('T5a', 'ZZ');
    PERFORM pg_temp.add_vehicle(v_app, 500000);
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'DUI', true, 'MVR');

    v_action := evaluate_application_referrals(v_app);
    IF v_action IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0026-T5 FAILED: combo 1 returned %, expected MANUAL_REVIEW_SENIOR (most severe of SENIOR/WITH_FLAG)', v_action;
    END IF;

    -- One row per rule (twelve since ADR 0037 added seven), with the expected
    -- fired flags on the four ADR 0026 rules.
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app;
    IF v_n <> 12 THEN
      RAISE EXCEPTION '0026-T5 FAILED: expected 12 decision_log rows from one orchestrator call, got %', v_n;
    END IF;
    SELECT (SELECT fired FROM decision_log WHERE application_id = v_app AND rule_id = 'AL-01'),
           (SELECT fired FROM decision_log WHERE application_id = v_app AND rule_id = 'CP-02'),
           (SELECT fired FROM decision_log WHERE application_id = v_app AND rule_id = 'DH-01'),
           (SELECT fired FROM decision_log WHERE application_id = v_app AND rule_id = 'PC-03')
      INTO v_al, v_cp, v_dh, v_pc;
    IF (v_al, v_cp, v_dh, v_pc) IS DISTINCT FROM (false, false, true, true) THEN
      RAISE EXCEPTION '0026-T5 FAILED: combo 1 fired flags AL/CP/DH/PC = %/%/%/%, expected false/false/true/true', v_al, v_cp, v_dh, v_pc;
    END IF;

    -- Combo 2: clean, complete application, licensed state -> nothing fires ->
    -- AUTO_PROCEED, all twelve rows fired=false (the enriched fixture also clears
    -- DH-04's completeness gate, ADR 0037).
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
    IF v_n <> 12 THEN
      RAISE EXCEPTION '0026-T5 FAILED: expected 12 non-fired decision_log rows for a clean application, got %', v_n;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0026-T5 pass: the orchestrator writes 12 rows per call and returns the most-severe fired action';
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
    -- GREATEST over a representative low-severity subset (AL-01 emits
    -- MANUAL_REVIEW_REQUIRED, DH-01/CP-02 emit MANUAL_REVIEW_SENIOR).
    IF GREATEST('AUTO_PROCEED'::referral_action_t, 'MANUAL_REVIEW_REQUIRED'::referral_action_t,
                'MANUAL_REVIEW_SENIOR'::referral_action_t, 'AUTO_PROCEED'::referral_action_t)
       IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR'::referral_action_t THEN
      RAISE EXCEPTION '0026-T7 FAILED: GREATEST over referral_action_t did not select the most severe value';
    END IF;

    -- GREATEST exercised structurally across the full taxonomy - including
    -- INFORMATION_REQUEST and HARD_DECLINE_COMPLIANCE, which no current rule
    -- emits - so the full-enum routing the orchestrator relies on is verified now
    -- rather than when a future rule first produces one of them. (Of the seven,
    -- AUTO_PROCEED, AUTO_PROCEED_WITH_FLAG (PC-03 since ADR 0036),
    -- MANUAL_REVIEW_REQUIRED, MANUAL_REVIEW_SENIOR and DECLINE_RECOMMENDED (EL-01)
    -- are load-bearing today.)
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
  RAISE NOTICE '0026-T7 pass: referral_action_t ascending-severity verified across all 7 values; GREATEST selects correctly across the full taxonomy, including the values no current rule yet produces';
END $$;

ROLLBACK;

\echo '0026: 7/7 cases passed (nothing committed)'
