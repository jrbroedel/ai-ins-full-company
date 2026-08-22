-- Behavioural tests for ADR 0031: the referral gate.
--
-- submit_application() is the first applications-lifecycle transition
-- (draft -> submitted): it evaluates the referral engine and returns the
-- most-severe action. current_referral_action() reads the current (latest-per-
-- rule) disposition from decision_log. create_quote() now refuses to produce an
-- automatic bindable quote unless that disposition is <= AUTO_PROCEED_WITH_FLAG.
--
--   T1  submit_application: clean app -> AUTO_PROCEED, status becomes submitted,
--       submitted_at stamped, 5 decision_log rows, current_referral_action agrees
--   T2  end-to-end: a cleared application quotes successfully after submission
--   T3  blocked: a DUI application -> MANUAL_REVIEW_SENIOR, create_quote refused
--       with QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE, no quote
--   T4  never evaluated: current_referral_action is NULL, create_quote refused
--       with QUOTE_APPLICATION_NOT_EVALUATED, no quote
--   T5  re-submission re-evaluates: submit clean (quotes OK), the data changes (a
--       DUI is added), re-submit -> the new disposition, both runs retained
--   T6  the gate reads the LATEST evaluation (newer-flagged blocks, newer-clean
--       quotes) - staged at explicit timestamps, the re-evaluation/staleness proof
--   T7  submit_application only from draft/submitted (a bound app is refused)
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, IS DISTINCT FROM on nullable reads, RAISE
-- on any failed assertion, rejection cases asserting on the error MESSAGE.

\set ON_ERROR_STOP on
BEGIN;
-- ADR 0035: this suite writes state_rating_table_versions rows directly as fixtures;
-- the onboard_state() guard permits that through the escape flag, set for this
-- rolled-back test transaction (tests use the hatch; production goes through onboard_state).
SET LOCAL luxauto.onboarding_state = 'on';

-- Fixture: a rating-table version for T0 (so PC-03 does not fire and the FK
-- resolves), an applicant, a DRAFT application in T0, and one exotic vehicle at a
-- chosen value. Everything a clean auto-quote needs except the referral run.
CREATE FUNCTION pg_temp.mk(p_tag TEXT, p_state CHAR(2) DEFAULT 'T0', p_value NUMERIC DEFAULT 600000,
  OUT app_id UUID, OUT rating_id UUID) AS $fx$
DECLARE v_applicant UUID;
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0031-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO rating_id;

  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0031-' || p_tag) RETURNING applicant_id INTO v_applicant;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'draft', p_state) RETURNING application_id INTO app_id;

  INSERT INTO vehicles (application_id, year, make, model, vehicle_category, garaging_state, current_appraised_value)
  VALUES (app_id, 2022, 'Ferrari', 'SF90', 'exotic', p_state, p_value);
END;
$fx$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.add_dui(p_app UUID) RETURNS void AS $fx$
  INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
  VALUES (p_app, NULL, (now() - interval '1 year')::date, 'DUI', true, 'MVR');
$fx$ LANGUAGE sql;

-- ---------------------------------------------------------------------------
-- T1  submit_application on a clean application: AUTO_PROCEED, the draft->
--     submitted transition and submitted_at stamp, five decision_log rows, and
--     current_referral_action() reporting the same disposition.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_action referral_action_t;
        v_status application_status_t; v_submitted TIMESTAMPTZ; v_n INT; v_cur referral_action_t;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T1') INTO v_app, v_rating;

    v_action := submit_application(v_app, '0031-suite');
    IF v_action IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0031-T1 FAILED: clean application submitted as %, expected AUTO_PROCEED', v_action;
    END IF;

    SELECT status, submitted_at INTO v_status, v_submitted FROM applications WHERE application_id = v_app;
    IF v_status IS DISTINCT FROM 'submitted' THEN
      RAISE EXCEPTION '0031-T1 FAILED: application status is %, expected submitted', v_status;
    END IF;
    IF v_submitted IS NULL THEN
      RAISE EXCEPTION '0031-T1 FAILED: submitted_at was not stamped';
    END IF;

    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app;
    IF v_n <> 5 THEN
      RAISE EXCEPTION '0031-T1 FAILED: expected 5 decision_log rows after submission, got %', v_n;
    END IF;

    v_cur := current_referral_action(v_app);
    IF v_cur IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0031-T1 FAILED: current_referral_action is %, expected AUTO_PROCEED', v_cur;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0031-T1 pass: submit_application clears a clean app (AUTO_PROCEED), transitions to submitted with submitted_at, logs 5 rows';
END $$;

-- ---------------------------------------------------------------------------
-- T2  End-to-end: a cleared application quotes successfully after submission.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_quote UUID; v_prem NUMERIC;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T2') INTO v_app, v_rating;
    PERFORM submit_application(v_app, '0031-suite');

    v_quote := create_quote(v_app, 'retail', 10, v_rating, NULL, '0031-suite');
    IF v_quote IS NULL THEN
      RAISE EXCEPTION '0031-T2 FAILED: create_quote returned NULL for a cleared application';
    END IF;
    SELECT premium_amount INTO v_prem FROM quotes WHERE quote_id = v_quote;
    IF v_prem IS DISTINCT FROM 10754.72 THEN
      RAISE EXCEPTION '0031-T2 FAILED: cleared application quoted at %, expected 10754.72', v_prem;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0031-T2 pass: a cleared application passes the gate and quotes end-to-end (10754.72)';
END $$;

-- ---------------------------------------------------------------------------
-- T3  Blocked: a DUI application evaluates to MANUAL_REVIEW_SENIOR (DH-01), so
--     create_quote refuses with QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE and writes
--     no quote.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_action referral_action_t; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T3') INTO v_app, v_rating;
    PERFORM pg_temp.add_dui(v_app);

    v_action := submit_application(v_app, '0031-suite');
    IF v_action IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0031-T3 FAILED: DUI application submitted as %, expected MANUAL_REVIEW_SENIOR', v_action;
    END IF;

    v_ok := false;
    BEGIN
      PERFORM create_quote(v_app, 'retail', 10, v_rating, NULL, '0031-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE%' THEN
      RAISE EXCEPTION '0031-T3 FAILED: a flagged application was not refused with QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM quotes WHERE application_id = v_app) <> 0 THEN
      RAISE EXCEPTION '0031-T3 FAILED: a blocked application still wrote a quote';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0031-T3 pass: a DUI application (MANUAL_REVIEW_SENIOR) is refused at the gate (QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE), no quote';
END $$;

-- ---------------------------------------------------------------------------
-- T4  Never evaluated: current_referral_action is NULL, and create_quote refuses
--     with QUOTE_APPLICATION_NOT_EVALUATED - a quote cannot be produced for an
--     application the referral engine has never seen.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T4') INTO v_app, v_rating;  -- deliberately NOT submitted

    IF current_referral_action(v_app) IS NOT NULL THEN
      RAISE EXCEPTION '0031-T4 FAILED: current_referral_action is non-NULL for a never-evaluated application';
    END IF;

    v_ok := false;
    BEGIN
      PERFORM create_quote(v_app, 'retail', 10, v_rating, NULL, '0031-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%QUOTE_APPLICATION_NOT_EVALUATED%' THEN
      RAISE EXCEPTION '0031-T4 FAILED: a never-evaluated application was not refused with QUOTE_APPLICATION_NOT_EVALUATED (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM quotes WHERE application_id = v_app) <> 0 THEN
      RAISE EXCEPTION '0031-T4 FAILED: a never-evaluated application still wrote a quote';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0031-T4 pass: a never-evaluated application has NULL disposition and is refused (QUOTE_APPLICATION_NOT_EVALUATED), no quote';
END $$;

-- ---------------------------------------------------------------------------
-- T5  Re-submission re-evaluates. Submit a clean app (it quotes); the underlying
--     data changes (a DUI conviction arrives); re-submit. submit_application is
--     re-runnable and re-evaluates the CURRENT data, returning the new
--     disposition (MANUAL_REVIEW_SENIOR), and decision_log retains both runs
--     (10 rows, append-only), status still 'submitted'. (That the *gate* then
--     reads the newest run is T6: within one test transaction now() is frozen, so
--     two real submissions collide on created_at and cannot be told apart by the
--     latest-per-rule read - the same harness reality ADR 0029 documented. In
--     production each submission is a separate transaction with a distinct now().)
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_quote UUID; v_action referral_action_t;
        v_n INT; v_status application_status_t;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T5') INTO v_app, v_rating;

    -- First evaluation: clean, and it quotes.
    v_action := submit_application(v_app, '0031-suite');
    IF v_action IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0031-T5 FAILED: first submission returned %, expected AUTO_PROCEED', v_action;
    END IF;
    v_quote := create_quote(v_app, 'retail', 10, v_rating, NULL, '0031-suite');
    IF v_quote IS NULL THEN
      RAISE EXCEPTION '0031-T5 FAILED: clean application did not quote on the first pass';
    END IF;

    -- The data changes: a DUI conviction arrives. Re-submit (re-evaluate).
    PERFORM pg_temp.add_dui(v_app);
    v_action := submit_application(v_app, '0031-suite');
    IF v_action IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0031-T5 FAILED: re-submission after DUI returned %, expected MANUAL_REVIEW_SENIOR (re-evaluated current data)', v_action;
    END IF;

    -- Both runs retained (append-only), and still 'submitted'.
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app;
    IF v_n <> 10 THEN
      RAISE EXCEPTION '0031-T5 FAILED: expected 10 decision_log rows across two evaluations, got %', v_n;
    END IF;
    SELECT status INTO v_status FROM applications WHERE application_id = v_app;
    IF v_status IS DISTINCT FROM 'submitted' THEN
      RAISE EXCEPTION '0031-T5 FAILED: status after re-evaluation is %, expected submitted', v_status;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0031-T5 pass: re-submission re-evaluates current data (AUTO_PROCEED -> MANUAL_REVIEW_SENIOR after a DUI), both runs retained (10 rows), still submitted';
END $$;

-- ---------------------------------------------------------------------------
-- T6  The gate reads the LATEST evaluation. Two runs are staged directly into
--     decision_log at explicit, distinct timestamps (bypassing the frozen-now()
--     limitation of two real submissions in one transaction, exactly as ADR 0029
--     T4 does). Case A: an older clean run, a newer flagged run -> the gate
--     blocks. Case B: an older flagged run, a newer clean run -> the gate lets
--     it quote. This proves the guard reflects the newest disposition per rule,
--     not "ever flagged" - the production re-evaluation/staleness mechanism.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app_a UUID; v_rat_a UUID; v_app_b UUID; v_rat_b UUID;
        v_t_old TIMESTAMPTZ := now() - interval '1 hour'; v_t_new TIMESTAMPTZ := now();
        v_quote UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    -- Case A: older clean, newer flagged (DH-01 fires) -> blocked. State ZZ is
    -- fine here: the gate refuses before rating, so no territory factor is needed.
    SELECT * FROM pg_temp.mk('T6a', 'ZZ') INTO v_app_a, v_rat_a;
    INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, created_at) VALUES
      (v_app_a,'AL-01','AL01_ADVERSE_LOSS_HISTORY','AUTO_PROCEED',false,'system',v_t_old),
      (v_app_a,'CP-02','CP02_AGGREGATE_TIV_CAP','AUTO_PROCEED',false,'system',v_t_old),
      (v_app_a,'DH-01','DH01_DUI_WITHIN_LOOKBACK','AUTO_PROCEED',false,'system',v_t_old),
      (v_app_a,'PC-03','PC03_OUT_OF_LICENSED_TERRITORY','AUTO_PROCEED',false,'system',v_t_old),
      (v_app_a,'EL-01','EL01_BELOW_AGREED_VALUE_FLOOR','AUTO_PROCEED',false,'system',v_t_old),
      (v_app_a,'AL-01','AL01_ADVERSE_LOSS_HISTORY','AUTO_PROCEED',false,'system',v_t_new),
      (v_app_a,'CP-02','CP02_AGGREGATE_TIV_CAP','AUTO_PROCEED',false,'system',v_t_new),
      (v_app_a,'DH-01','DH01_DUI_WITHIN_LOOKBACK','MANUAL_REVIEW_SENIOR',true,'system',v_t_new),
      (v_app_a,'PC-03','PC03_OUT_OF_LICENSED_TERRITORY','AUTO_PROCEED',false,'system',v_t_new),
      (v_app_a,'EL-01','EL01_BELOW_AGREED_VALUE_FLOOR','AUTO_PROCEED',false,'system',v_t_new);
    IF current_referral_action(v_app_a) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0031-T6 FAILED: case A disposition is %, expected MANUAL_REVIEW_SENIOR (newest run)', current_referral_action(v_app_a);
    END IF;
    v_ok := false;
    BEGIN PERFORM create_quote(v_app_a, 'retail', 10, v_rat_a, NULL, '0031-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE%' THEN
      RAISE EXCEPTION '0031-T6 FAILED: case A (newer flagged) did not block create_quote (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- Case B: older flagged, newer clean -> quotes (it is "latest", not "ever flagged").
    SELECT * FROM pg_temp.mk('T6b') INTO v_app_b, v_rat_b;
    INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, created_at) VALUES
      (v_app_b,'AL-01','AL01_ADVERSE_LOSS_HISTORY','AUTO_PROCEED',false,'system',v_t_old),
      (v_app_b,'CP-02','CP02_AGGREGATE_TIV_CAP','AUTO_PROCEED',false,'system',v_t_old),
      (v_app_b,'DH-01','DH01_DUI_WITHIN_LOOKBACK','MANUAL_REVIEW_SENIOR',true,'system',v_t_old),
      (v_app_b,'PC-03','PC03_OUT_OF_LICENSED_TERRITORY','AUTO_PROCEED',false,'system',v_t_old),
      (v_app_b,'EL-01','EL01_BELOW_AGREED_VALUE_FLOOR','AUTO_PROCEED',false,'system',v_t_old),
      (v_app_b,'AL-01','AL01_ADVERSE_LOSS_HISTORY','AUTO_PROCEED',false,'system',v_t_new),
      (v_app_b,'CP-02','CP02_AGGREGATE_TIV_CAP','AUTO_PROCEED',false,'system',v_t_new),
      (v_app_b,'DH-01','DH01_DUI_WITHIN_LOOKBACK','AUTO_PROCEED',false,'system',v_t_new),
      (v_app_b,'PC-03','PC03_OUT_OF_LICENSED_TERRITORY','AUTO_PROCEED',false,'system',v_t_new),
      (v_app_b,'EL-01','EL01_BELOW_AGREED_VALUE_FLOOR','AUTO_PROCEED',false,'system',v_t_new);
    IF current_referral_action(v_app_b) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0031-T6 FAILED: case B disposition is %, expected AUTO_PROCEED (newest run)', current_referral_action(v_app_b);
    END IF;
    v_quote := create_quote(v_app_b, 'retail', 10, v_rat_b, NULL, '0031-suite');
    IF v_quote IS NULL THEN
      RAISE EXCEPTION '0031-T6 FAILED: case B (newer clean) did not quote';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0031-T6 pass: the gate reads the latest per-rule disposition - newer-flagged blocks, newer-clean quotes (not "ever flagged")';
END $$;

-- ---------------------------------------------------------------------------
-- T7  submit_application is a draft/submitted-only transition: a bound (or any
--     terminal) application is refused with SUBMIT_APPLICATION_INVALID_STATE.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T7') INTO v_app, v_rating;
    UPDATE applications SET status = 'bound' WHERE application_id = v_app;

    v_ok := false;
    BEGIN
      PERFORM submit_application(v_app, '0031-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%SUBMIT_APPLICATION_INVALID_STATE%' THEN
      RAISE EXCEPTION '0031-T7 FAILED: submitting a bound application was not refused with SUBMIT_APPLICATION_INVALID_STATE (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0031-T7 pass: submit_application refuses a non-draft/non-submitted (bound) application (SUBMIT_APPLICATION_INVALID_STATE)';
END $$;

ROLLBACK;

\echo '0031: 7/7 cases passed (nothing committed)'
