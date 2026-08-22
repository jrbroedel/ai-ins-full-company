-- Behavioural tests for ADR 0032: underwriter supervised release / referral override.
--
-- A flagged application (disposition worse than AUTO_PROCEED_WITH_FLAG) can be
-- supervise-released by a human underwriter via authorize_referral_override(),
-- after which create_quote() lets it through. HARD_DECLINE_COMPLIANCE is NEVER
-- overridable - enforced by a table CHECK (structural) and an explicit
-- create_quote() guard (belt and suspenders). MANUAL_REVIEW_SENIOR needs a senior
-- underwriter; the override is pinned to the evaluation it reviewed.
--
--   T1  add_underwriter happy path (and a blank name refused)
--   T2  standard underwriter overrides MANUAL_REVIEW_REQUIRED -> succeeds
--   T3  standard underwriter overrides DECLINE_RECOMMENDED -> succeeds
--   T4  standard underwriter for MANUAL_REVIEW_SENIOR -> rejected (function AND a
--       direct INSERT, proving the trigger is the structural enforcement)
--   T5  senior underwriter overrides MANUAL_REVIEW_SENIOR -> succeeds
--   T6  inactive underwriter -> rejected (function AND trigger)
--   T7  HARD_DECLINE_COMPLIANCE override -> rejected: the function forbids it, and
--       a direct INSERT (even by a senior) is rejected by the table CHECK
--   T8  staleness pin: override, then a re-evaluation to the same disposition VALUE
--       but a new evaluated_at -> the old override no longer satisfies the guard
--   T9  end-to-end: a flagged (MANUAL_REVIEW_SENIOR) application blocked at
--       create_quote, senior-overridden, then quotes successfully
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

-- Fixture: a rateable application - a T0 rating-table version, an applicant, a
-- 'submitted' application, and one exotic vehicle at $600k in the state. (A
-- staged decision_log disposition, below, decides whether it is flagged.)
CREATE FUNCTION pg_temp.mk(p_tag TEXT, p_state CHAR(2) DEFAULT 'T0',
  OUT app_id UUID, OUT rating_id UUID) AS $fx$
DECLARE v_applicant UUID;
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0032-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO rating_id;
  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0032-' || p_tag) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'submitted', p_state) RETURNING application_id INTO app_id;
  INSERT INTO vehicles (application_id, year, make, model, vehicle_category, garaging_state, current_appraised_value)
  VALUES (app_id, 2022, 'Ferrari', 'SF90', 'exotic', p_state, 600000);
END;
$fx$ LANGUAGE plpgsql;

-- Stage a disposition directly into decision_log at a chosen time (one rule row,
-- so current_referral_action = that action and current_referral_evaluated_at = t).
CREATE FUNCTION pg_temp.set_disp(p_app UUID, p_action referral_action_t, p_at TIMESTAMPTZ DEFAULT now())
RETURNS void AS $fx$
  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, created_at)
  VALUES (p_app, 'TEST-RULE', 'TEST_REASON', p_action, p_action <> 'AUTO_PROCEED', 'system', p_at);
$fx$ LANGUAGE sql;

CREATE FUNCTION pg_temp.add_dui(p_app UUID) RETURNS void AS $fx$
  INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
  VALUES (p_app, NULL, (now() - interval '1 year')::date, 'DUI', true, 'MVR');
$fx$ LANGUAGE sql;

-- ---------------------------------------------------------------------------
-- T1  add_underwriter: a row with the right level and active=true; a blank name
--     is refused.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_id UUID; v_name TEXT; v_level underwriter_authority_t; v_active BOOLEAN; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    v_id := add_underwriter('Alice Senior', 'senior');
    SELECT name, authority_level, active INTO v_name, v_level, v_active FROM underwriters WHERE underwriter_id = v_id;
    IF (v_name, v_level, v_active) IS DISTINCT FROM ('Alice Senior', 'senior'::underwriter_authority_t, true) THEN
      RAISE EXCEPTION '0032-T1 FAILED: underwriter row is %/%/%, expected Alice Senior/senior/true', v_name, v_level, v_active;
    END IF;

    v_ok := false;
    BEGIN PERFORM add_underwriter('   ', 'standard');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%ADD_UNDERWRITER_NAME_REQUIRED%' THEN
      RAISE EXCEPTION '0032-T1 FAILED: a blank underwriter name was not refused (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0032-T1 pass: add_underwriter creates an active roster row and refuses a blank name';
END $$;

-- ---------------------------------------------------------------------------
-- T2  Standard underwriter overrides MANUAL_REVIEW_REQUIRED -> succeeds.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_uw UUID; v_ov UUID; r RECORD;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T2') INTO v_app, v_rating;
    PERFORM pg_temp.set_disp(v_app, 'MANUAL_REVIEW_REQUIRED');
    v_uw := add_underwriter('Bob Standard', 'standard');

    v_ov := authorize_referral_override(v_app, 'MANUAL_REVIEW_REQUIRED', 'household driver disclosed on call', v_uw);
    IF v_ov IS NULL THEN
      RAISE EXCEPTION '0032-T2 FAILED: authorize_referral_override returned NULL';
    END IF;
    SELECT overridden_action, reason, authorized_by_underwriter_id INTO r
    FROM referral_overrides WHERE override_id = v_ov;
    IF (r.overridden_action, r.reason, r.authorized_by_underwriter_id)
       IS DISTINCT FROM ('MANUAL_REVIEW_REQUIRED'::referral_action_t, 'household driver disclosed on call', v_uw) THEN
      RAISE EXCEPTION '0032-T2 FAILED: override row is %/%/%', r.overridden_action, r.reason, r.authorized_by_underwriter_id;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0032-T2 pass: a standard underwriter can override MANUAL_REVIEW_REQUIRED';
END $$;

-- ---------------------------------------------------------------------------
-- T3  Standard underwriter overrides DECLINE_RECOMMENDED -> succeeds (a human
--     confirming/reversing a recommendation is normal).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_uw UUID; v_ov UUID;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T3') INTO v_app, v_rating;
    PERFORM pg_temp.set_disp(v_app, 'DECLINE_RECOMMENDED');
    v_uw := add_underwriter('Bob Standard', 'standard');
    v_ov := authorize_referral_override(v_app, 'DECLINE_RECOMMENDED', 'model over-weighted a stale claim; proceeding', v_uw);
    IF v_ov IS NULL THEN
      RAISE EXCEPTION '0032-T3 FAILED: a standard underwriter could not override DECLINE_RECOMMENDED';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0032-T3 pass: a standard underwriter can override DECLINE_RECOMMENDED';
END $$;

-- ---------------------------------------------------------------------------
-- T4  Standard underwriter for MANUAL_REVIEW_SENIOR -> rejected. Both the
--     function pre-check AND a direct INSERT (proving the trigger enforces).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_uw UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T4') INTO v_app, v_rating;
    PERFORM pg_temp.set_disp(v_app, 'MANUAL_REVIEW_SENIOR');
    v_uw := add_underwriter('Bob Standard', 'standard');

    -- Via the function.
    v_ok := false;
    BEGIN PERFORM authorize_referral_override(v_app, 'MANUAL_REVIEW_SENIOR', 'trying', v_uw);
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%OVERRIDE_SENIOR_AUTHORITY_REQUIRED%' THEN
      RAISE EXCEPTION '0032-T4 FAILED: function did not reject a standard override of MANUAL_REVIEW_SENIOR (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- Direct INSERT bypassing the function: the trigger must still reject it.
    v_ok := false;
    BEGIN
      INSERT INTO referral_overrides (application_id, overridden_action, evaluated_at, reason, authorized_by_underwriter_id)
      VALUES (v_app, 'MANUAL_REVIEW_SENIOR', now(), 'bypassing the function', v_uw);
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%OVERRIDE_SENIOR_AUTHORITY_REQUIRED%' THEN
      RAISE EXCEPTION '0032-T4 FAILED: the trigger did not reject a direct standard-override of MANUAL_REVIEW_SENIOR (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM referral_overrides WHERE application_id = v_app) <> 0 THEN
      RAISE EXCEPTION '0032-T4 FAILED: a rejected senior override still wrote a row';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0032-T4 pass: a standard underwriter cannot override MANUAL_REVIEW_SENIOR - rejected by the function AND, structurally, the trigger';
END $$;

-- ---------------------------------------------------------------------------
-- T5  Senior underwriter overrides MANUAL_REVIEW_SENIOR -> succeeds.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_uw UUID; v_ov UUID;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T5') INTO v_app, v_rating;
    PERFORM pg_temp.set_disp(v_app, 'MANUAL_REVIEW_SENIOR');
    v_uw := add_underwriter('Alice Senior', 'senior');
    v_ov := authorize_referral_override(v_app, 'MANUAL_REVIEW_SENIOR', 'senior reviewed TIV concentration, approved', v_uw);
    IF v_ov IS NULL THEN
      RAISE EXCEPTION '0032-T5 FAILED: a senior underwriter could not override MANUAL_REVIEW_SENIOR';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0032-T5 pass: a senior underwriter can override MANUAL_REVIEW_SENIOR';
END $$;

-- ---------------------------------------------------------------------------
-- T6  Inactive underwriter -> rejected (function AND trigger).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_uw UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T6') INTO v_app, v_rating;
    PERFORM pg_temp.set_disp(v_app, 'MANUAL_REVIEW_REQUIRED');
    v_uw := add_underwriter('Carol Departed', 'senior');
    UPDATE underwriters SET active = false WHERE underwriter_id = v_uw;

    v_ok := false;
    BEGIN PERFORM authorize_referral_override(v_app, 'MANUAL_REVIEW_REQUIRED', 'trying', v_uw);
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%OVERRIDE_AUTHORIZER_INACTIVE%' THEN
      RAISE EXCEPTION '0032-T6 FAILED: function did not reject an inactive authorizer (ok=%, err=%)', v_ok, v_err;
    END IF;

    v_ok := false;
    BEGIN
      INSERT INTO referral_overrides (application_id, overridden_action, evaluated_at, reason, authorized_by_underwriter_id)
      VALUES (v_app, 'MANUAL_REVIEW_REQUIRED', now(), 'bypassing', v_uw);
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%OVERRIDE_AUTHORIZER_INACTIVE%' THEN
      RAISE EXCEPTION '0032-T6 FAILED: the trigger did not reject a direct override by an inactive underwriter (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0032-T6 pass: an inactive underwriter cannot authorize an override - function and trigger both refuse';
END $$;

-- ---------------------------------------------------------------------------
-- T7  HARD_DECLINE_COMPLIANCE is NEVER overridable. The function forbids it; a
--     direct INSERT (even by a senior) is rejected by the table CHECK. This is
--     the single most important property, verified end-to-end with the authority
--     model in place. No override row is ever written.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_uw UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T7') INTO v_app, v_rating;
    PERFORM pg_temp.set_disp(v_app, 'HARD_DECLINE_COMPLIANCE');
    v_uw := add_underwriter('Alice Senior', 'senior');

    -- Via the function: forbidden with a clear message.
    v_ok := false;
    BEGIN PERFORM authorize_referral_override(v_app, 'HARD_DECLINE_COMPLIANCE', 'a senior insisting', v_uw);
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%OVERRIDE_COMPLIANCE_DECLINE_FORBIDDEN%' THEN
      RAISE EXCEPTION '0032-T7 FAILED: the function let a senior attempt a compliance-decline override (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- Direct INSERT, even by a senior: rejected by the table CHECK (structural).
    v_ok := false;
    BEGIN
      INSERT INTO referral_overrides (application_id, overridden_action, evaluated_at, reason, authorized_by_underwriter_id)
      VALUES (v_app, 'HARD_DECLINE_COMPLIANCE', now(), 'forcing it', v_uw);
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%referral_overrides_overridable_ck%' THEN
      RAISE EXCEPTION '0032-T7 FAILED: a direct HARD_DECLINE_COMPLIANCE override was not rejected by the table CHECK (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM referral_overrides WHERE application_id = v_app) <> 0 THEN
      RAISE EXCEPTION '0032-T7 FAILED: a compliance-decline override row was written - this must be structurally impossible';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0032-T7 pass: HARD_DECLINE_COMPLIANCE is never overridable - function forbids it, table CHECK makes it structurally impossible even for a senior';
END $$;

-- ---------------------------------------------------------------------------
-- T8  Staleness pin. Override MANUAL_REVIEW_REQUIRED at an older evaluation; then
--     a re-evaluation produces the SAME disposition value at a new evaluated_at.
--     The old override no longer matches the current evaluation, so create_quote
--     stays blocked. (Explicit timestamps, since now() is frozen within one tx.)
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_uw UUID; v_ov UUID;
        v_t_old TIMESTAMPTZ := now() - interval '1 hour'; v_t_new TIMESTAMPTZ := now();
        v_ov_eval TIMESTAMPTZ; v_cur_eval TIMESTAMPTZ; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T8') INTO v_app, v_rating;
    PERFORM pg_temp.set_disp(v_app, 'MANUAL_REVIEW_REQUIRED', v_t_old);
    v_uw := add_underwriter('Bob Standard', 'standard');
    v_ov := authorize_referral_override(v_app, 'MANUAL_REVIEW_REQUIRED', 'reviewed as of the older evaluation', v_uw);

    -- Re-evaluation: same disposition VALUE, newer timestamp.
    PERFORM pg_temp.set_disp(v_app, 'MANUAL_REVIEW_REQUIRED', v_t_new);

    SELECT evaluated_at INTO v_ov_eval FROM referral_overrides WHERE override_id = v_ov;
    v_cur_eval := current_referral_evaluated_at(v_app);
    IF v_ov_eval IS NOT DISTINCT FROM v_cur_eval THEN
      RAISE EXCEPTION '0032-T8 FAILED: override evaluated_at (%) still equals current (%) - the pin did not move', v_ov_eval, v_cur_eval;
    END IF;

    -- The stale override no longer satisfies the guard.
    v_ok := false;
    BEGIN PERFORM create_quote(v_app, 'retail', 10, v_rating, NULL, '0032-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE%' THEN
      RAISE EXCEPTION '0032-T8 FAILED: a stale override (older evaluation) still cleared create_quote (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0032-T8 pass: an override is pinned to its evaluation - a re-evaluation (even to the same disposition value) invalidates it, and create_quote stays blocked';
END $$;

-- ---------------------------------------------------------------------------
-- T9  End-to-end: a real DUI application (MANUAL_REVIEW_SENIOR) is blocked at
--     create_quote, a senior underwriter supervise-releases it, and it then
--     quotes successfully (10754.72).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_uw UUID; v_action referral_action_t;
        v_quote UUID; v_prem NUMERIC; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T9') INTO v_app, v_rating;
    PERFORM pg_temp.add_dui(v_app);
    v_action := submit_application(v_app, '0032-suite');
    IF v_action IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0032-T9 FAILED: DUI application evaluated to %, expected MANUAL_REVIEW_SENIOR', v_action;
    END IF;

    -- Blocked before any override.
    v_ok := false;
    BEGIN PERFORM create_quote(v_app, 'retail', 10, v_rating, NULL, '0032-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE%' THEN
      RAISE EXCEPTION '0032-T9 FAILED: a flagged application was not blocked before override (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- Senior supervise-releases it.
    v_uw := add_underwriter('Alice Senior', 'senior');
    PERFORM authorize_referral_override(v_app, 'MANUAL_REVIEW_SENIOR', 'senior reviewed the DUI, dated and mitigated; approved', v_uw);

    -- Now it quotes.
    v_quote := create_quote(v_app, 'retail', 10, v_rating, NULL, '0032-suite');
    IF v_quote IS NULL THEN
      RAISE EXCEPTION '0032-T9 FAILED: create_quote did not produce a quote after a valid senior override';
    END IF;
    SELECT premium_amount INTO v_prem FROM quotes WHERE quote_id = v_quote;
    IF v_prem IS DISTINCT FROM 10754.72 THEN
      RAISE EXCEPTION '0032-T9 FAILED: overridden application quoted at %, expected 10754.72', v_prem;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0032-T9 pass: a flagged application blocked at create_quote is supervise-released by a senior override and then quotes (10754.72)';
END $$;

ROLLBACK;

\echo '0032: 9/9 cases passed (nothing committed)'
