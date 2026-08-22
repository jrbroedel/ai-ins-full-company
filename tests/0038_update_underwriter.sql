-- Behavioural tests for ADR 0038: update_underwriter().
--
-- The mutable-roster counterpart to add_underwriter() (ADR 0032): promote/demote
-- (authority_level), (de/re)activate (active), rename (name); NULL = leave
-- unchanged (COALESCE); underwriter_id/created_at immutable. Beyond the mutation
-- unit cases, two interaction proofs SUBSTANTIATE the audit finding rather than
-- just asserting mutations work: (T8) a senior-authorized override still releases
-- a quote after the authorizer is demoted (functional immutability), and (T9) a
-- reactivated underwriter can authorize again.
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case (its inner BEGIN..EXCEPTION savepoint rolls
-- back that case's fixtures), IS DISTINCT FROM on nullable reads, RAISE on any
-- failed assertion, rejection cases asserting on the error MESSAGE.

\set ON_ERROR_STOP on
BEGIN;
-- ADR 0035: this suite writes state_rating_table_versions rows directly as fixtures;
-- the onboard_state() guard permits that through the escape flag, set for this
-- rolled-back test transaction (tests use the hatch; production goes through onboard_state).
SET LOCAL luxauto.onboarding_state = 'on';

-- A complete, rateable T0 application (enriched per ADR 0037 so DH-04 stays clear),
-- built as a draft so submit_application drives the real referral pass.
CREATE FUNCTION pg_temp.mk_rateable_app(p_tag TEXT, OUT app_id UUID, OUT rating_id UUID) AS $fx$
DECLARE v_applicant UUID;
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
  VALUES ('T0', 'T0 DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0038-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO rating_id;
  INSERT INTO applicants (first_name, last_name, date_of_birth, license_status, years_licensed)
  VALUES ('Test', '0038-' || p_tag, DATE '1980-01-01', 'valid', 20) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'draft', 'T0') RETURNING application_id INTO app_id;
  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state, garaging_street, current_appraised_value)
  VALUES (app_id, 2022, 'Ferrari', 'SF90', 'VIN0038' || p_tag, 'exotic', 'T0', '1 Test St', 600000);
END;
$fx$ LANGUAGE plpgsql;

-- A minimal application (applicant + application only) with a staged disposition,
-- for the authorize-override path (no rating pipeline needed).
CREATE FUNCTION pg_temp.mk_flagged_app(p_tag TEXT, p_action referral_action_t, OUT app_id UUID) AS $fx$
DECLARE v_applicant UUID;
BEGIN
  INSERT INTO applicants (first_name, last_name) VALUES ('Test', '0038-' || p_tag) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state) VALUES (v_applicant, 'submitted', 'T0') RETURNING application_id INTO app_id;
  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by)
  VALUES (app_id, 'TEST-RULE', 'TEST_REASON', p_action, true, 'system');
END;
$fx$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.add_dui(p_app UUID) RETURNS void AS $fx$
  INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
  VALUES (p_app, NULL, (now() - interval '1 year')::date, 'DUI', true, 'MVR');
$fx$ LANGUAGE sql;

-- ---------------------------------------------------------------------------
-- T1  Promote (standard -> senior). Only authority_level changes; name/active
--     untouched (COALESCE). Returns the underwriter_id.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_uw UUID; v_ret UUID; v_name TEXT; v_level underwriter_authority_t; v_active BOOLEAN;
BEGIN
  BEGIN
    v_uw := add_underwriter('Bob Standard', 'standard');
    v_ret := update_underwriter(v_uw, p_authority_level => 'senior');
    IF v_ret IS DISTINCT FROM v_uw THEN
      RAISE EXCEPTION '0038-T1 FAILED: update_underwriter returned %, expected the underwriter_id %', v_ret, v_uw;
    END IF;
    SELECT name, authority_level, active INTO v_name, v_level, v_active FROM underwriters WHERE underwriter_id = v_uw;
    IF (v_name, v_level, v_active) IS DISTINCT FROM ('Bob Standard', 'senior'::underwriter_authority_t, true) THEN
      RAISE EXCEPTION '0038-T1 FAILED: after promote row is %/%/%, expected Bob Standard/senior/true (name/active unchanged)', v_name, v_level, v_active;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0038-T1 pass: promote changes only authority_level (standard->senior), returns the id, leaves name/active untouched';
END $$;

-- ---------------------------------------------------------------------------
-- T2  Demote (senior -> standard). Allowed; only authority_level changes.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_uw UUID; v_level underwriter_authority_t;
BEGIN
  BEGIN
    v_uw := add_underwriter('Alice Senior', 'senior');
    PERFORM update_underwriter(v_uw, p_authority_level => 'standard');
    SELECT authority_level INTO v_level FROM underwriters WHERE underwriter_id = v_uw;
    IF v_level IS DISTINCT FROM 'standard' THEN
      RAISE EXCEPTION '0038-T2 FAILED: after demote authority_level is %, expected standard', v_level;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0038-T2 pass: demote (senior->standard) is allowed and changes only authority_level';
END $$;

-- ---------------------------------------------------------------------------
-- T3  Deactivate then reactivate (round-trip on active); name/authority untouched.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_uw UUID; v_active BOOLEAN; v_name TEXT; v_level underwriter_authority_t;
BEGIN
  BEGIN
    v_uw := add_underwriter('Carol', 'senior');
    PERFORM update_underwriter(v_uw, p_active => false);
    SELECT active, name, authority_level INTO v_active, v_name, v_level FROM underwriters WHERE underwriter_id = v_uw;
    IF (v_active, v_name, v_level) IS DISTINCT FROM (false, 'Carol', 'senior'::underwriter_authority_t) THEN
      RAISE EXCEPTION '0038-T3 FAILED: after deactivate row is active=%/name=%/level=%, expected false/Carol/senior', v_active, v_name, v_level;
    END IF;

    PERFORM update_underwriter(v_uw, p_active => true);
    SELECT active INTO v_active FROM underwriters WHERE underwriter_id = v_uw;
    IF v_active IS DISTINCT FROM true THEN
      RAISE EXCEPTION '0038-T3 FAILED: after reactivate active is %, expected true', v_active;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0038-T3 pass: active round-trips false->true, leaving name/authority_level unchanged';
END $$;

-- ---------------------------------------------------------------------------
-- T4  Rename, and partial COALESCE: updating name alone leaves authority/active.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_uw UUID; v_name TEXT; v_level underwriter_authority_t; v_active BOOLEAN;
BEGIN
  BEGIN
    v_uw := add_underwriter('Old Name', 'standard');
    PERFORM update_underwriter(v_uw, p_name => 'New Name');
    SELECT name, authority_level, active INTO v_name, v_level, v_active FROM underwriters WHERE underwriter_id = v_uw;
    IF (v_name, v_level, v_active) IS DISTINCT FROM ('New Name', 'standard'::underwriter_authority_t, true) THEN
      RAISE EXCEPTION '0038-T4 FAILED: after rename row is %/%/%, expected New Name/standard/true', v_name, v_level, v_active;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0038-T4 pass: rename changes only name; authority_level/active preserved by COALESCE';
END $$;

-- ---------------------------------------------------------------------------
-- T5  All-NULL update rejected (UPDATE_UNDERWRITER_NO_CHANGES).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_uw UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    v_uw := add_underwriter('Dave', 'standard');
    v_ok := false;
    BEGIN PERFORM update_underwriter(v_uw);
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%UPDATE_UNDERWRITER_NO_CHANGES%' THEN
      RAISE EXCEPTION '0038-T5 FAILED: an all-NULL update was not rejected with UPDATE_UNDERWRITER_NO_CHANGES (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0038-T5 pass: an update supplying no fields is rejected (UPDATE_UNDERWRITER_NO_CHANGES)';
END $$;

-- ---------------------------------------------------------------------------
-- T6  Blank name rejected (UPDATE_UNDERWRITER_NAME_REQUIRED), and no partial write.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_uw UUID; v_ok BOOLEAN; v_err TEXT; v_level underwriter_authority_t;
BEGIN
  BEGIN
    v_uw := add_underwriter('Eve', 'standard');
    v_ok := false;
    BEGIN PERFORM update_underwriter(v_uw, p_name => '   ', p_authority_level => 'senior');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%UPDATE_UNDERWRITER_NAME_REQUIRED%' THEN
      RAISE EXCEPTION '0038-T6 FAILED: a blank name was not rejected with UPDATE_UNDERWRITER_NAME_REQUIRED (ok=%, err=%)', v_ok, v_err;
    END IF;
    -- The whole update rolled back: authority_level must NOT have been changed to senior.
    SELECT authority_level INTO v_level FROM underwriters WHERE underwriter_id = v_uw;
    IF v_level IS DISTINCT FROM 'standard' THEN
      RAISE EXCEPTION '0038-T6 FAILED: a rejected blank-name update still changed authority_level to %', v_level;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0038-T6 pass: a blank name is rejected (UPDATE_UNDERWRITER_NAME_REQUIRED) and nothing else is written';
END $$;

-- ---------------------------------------------------------------------------
-- T7  Unknown underwriter_id rejected (UPDATE_UNDERWRITER_NOT_FOUND).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    v_ok := false;
    BEGIN PERFORM update_underwriter('00000000-0000-0000-0000-000000000000'::uuid, p_active => false);
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%UPDATE_UNDERWRITER_NOT_FOUND%' THEN
      RAISE EXCEPTION '0038-T7 FAILED: an unknown underwriter_id was not rejected with UPDATE_UNDERWRITER_NOT_FOUND (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0038-T7 pass: updating a non-existent underwriter is rejected (UPDATE_UNDERWRITER_NOT_FOUND)';
END $$;

-- ---------------------------------------------------------------------------
-- T8  INTERACTION PROOF (functional immutability): a senior authorizes an
--     override of MANUAL_REVIEW_SENIOR; the underwriter is then DEMOTED to
--     standard; create_quote() STILL succeeds against that existing override.
--     A demotion does not retroactively invalidate a past supervised release -
--     the append-only override row, not the authorizer's current level, is what
--     the gate reads. (The pre-demotion state is also proven: a standard could
--     not have created this override in the first place.)
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_uw UUID; v_action referral_action_t;
        v_quote UUID; v_prem NUMERIC; v_level underwriter_authority_t; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT app_id, rating_id FROM pg_temp.mk_rateable_app('T8') INTO v_app, v_rating;
    PERFORM pg_temp.add_dui(v_app);
    v_action := submit_application(v_app, '0038-suite');
    IF v_action IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0038-T8 FAILED: DUI application evaluated to %, expected MANUAL_REVIEW_SENIOR', v_action;
    END IF;

    -- A standard underwriter CANNOT authorize this - proves the senior requirement
    -- was really in force at authorization time.
    v_ok := false;
    BEGIN PERFORM authorize_referral_override(v_app, 'MANUAL_REVIEW_SENIOR', 'trying as standard',
             add_underwriter('Standard Nope', 'standard'));
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%OVERRIDE_SENIOR_AUTHORITY_REQUIRED%' THEN
      RAISE EXCEPTION '0038-T8 FAILED: a standard underwriter was not refused for a SENIOR override (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- The senior authorizes the override (valid at insert time).
    v_uw := add_underwriter('Senior Approver', 'senior');
    PERFORM authorize_referral_override(v_app, 'MANUAL_REVIEW_SENIOR', 'senior reviewed the DUI, dated & mitigated', v_uw);

    -- Now DEMOTE that senior to standard.
    PERFORM update_underwriter(v_uw, p_authority_level => 'standard');
    SELECT authority_level INTO v_level FROM underwriters WHERE underwriter_id = v_uw;
    IF v_level IS DISTINCT FROM 'standard' THEN
      RAISE EXCEPTION '0038-T8 FAILED: demotion did not take (authority_level is %)', v_level;
    END IF;

    -- create_quote STILL succeeds: the existing override row releases the gate,
    -- unaffected by the authorizer's now-lower current authority.
    v_quote := create_quote(v_app, 'retail', 10, v_rating, NULL, '0038-suite');
    IF v_quote IS NULL THEN
      RAISE EXCEPTION '0038-T8 FAILED: create_quote returned NULL after the authorizer was demoted';
    END IF;
    SELECT premium_amount INTO v_prem FROM quotes WHERE quote_id = v_quote;
    IF v_prem IS DISTINCT FROM 10754.72 THEN
      RAISE EXCEPTION '0038-T8 FAILED: quote premium is %, expected the re-rated 10754.72', v_prem;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0038-T8 pass: a senior-authorized override still releases create_quote (10754.72) after the authorizer is demoted to standard - past overrides are immutable and functionally unaffected by later roster changes';
END $$;

-- ---------------------------------------------------------------------------
-- T9  INTERACTION PROOF (reactivation restores authority): a deactivated
--     underwriter is refused, then reactivated, then authorizes successfully.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_uw UUID; v_ov UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT app_id FROM pg_temp.mk_flagged_app('T9', 'MANUAL_REVIEW_REQUIRED') INTO v_app;
    v_uw := add_underwriter('Grace', 'standard');

    -- Deactivate -> authorization refused (inactive).
    PERFORM update_underwriter(v_uw, p_active => false);
    v_ok := false;
    BEGIN PERFORM authorize_referral_override(v_app, 'MANUAL_REVIEW_REQUIRED', 'while inactive', v_uw);
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%OVERRIDE_AUTHORIZER_INACTIVE%' THEN
      RAISE EXCEPTION '0038-T9 FAILED: a deactivated underwriter was not refused (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- Reactivate -> authorization now succeeds.
    PERFORM update_underwriter(v_uw, p_active => true);
    v_ov := authorize_referral_override(v_app, 'MANUAL_REVIEW_REQUIRED', 'reviewed after reactivation', v_uw);
    IF v_ov IS NULL THEN
      RAISE EXCEPTION '0038-T9 FAILED: a reactivated underwriter could not authorize an override';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM referral_overrides WHERE override_id = v_ov AND authorized_by_underwriter_id = v_uw) THEN
      RAISE EXCEPTION '0038-T9 FAILED: the override row was not recorded for the reactivated underwriter';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0038-T9 pass: a deactivated underwriter is refused (OVERRIDE_AUTHORIZER_INACTIVE), and after reactivation authorizes a new override successfully';
END $$;

ROLLBACK;

\echo '0038: 9/9 cases passed (nothing committed)'
