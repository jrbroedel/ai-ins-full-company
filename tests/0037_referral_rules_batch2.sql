-- Behavioural tests for ADR 0037: seven more referral rules -
-- VV-03, VV-04, DH-03, DH-04, AL-02, CP-01, PC-01.
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, IS DISTINCT FROM on nullable reads, RAISE
-- on any failed assertion. Each rule writes exactly one decision_log row per
-- call (fired or not, reason_code always set); T8 checks the orchestrator now
-- composes twelve rules. now() is the transaction start, constant across the
-- suite, so VV-03's look-back boundaries are deterministic to the day.

\set ON_ERROR_STOP on
BEGIN;
-- ADR 0035: this suite writes state_rating_table_versions rows directly as fixtures;
-- the onboard_state() guard permits that through the escape flag, set for this
-- rolled-back test transaction (tests use the hatch; production goes through onboard_state).
SET LOCAL luxauto.onboarding_state = 'on';

-- A complete applicant + application (the DH-04-relevant fields populated), so a
-- fixture is clean unless a case deliberately makes it otherwise. p_status lets a
-- case build a draft; p_mailing/p_occupation drive PC-01/CP-01.
CREATE FUNCTION pg_temp.mk(p_tag TEXT, p_state CHAR(2) DEFAULT 'CA',
                           p_status application_status_t DEFAULT 'submitted',
                           p_mailing CHAR(2) DEFAULT NULL, p_occupation TEXT DEFAULT NULL,
                           OUT app_id UUID, OUT app_applicant UUID) AS $fx$
BEGIN
  INSERT INTO applicants (first_name, last_name, date_of_birth, license_status, years_licensed, mailing_state, occupation)
  VALUES ('Test', '0037-' || p_tag, DATE '1980-01-01', 'valid', 20, p_mailing, p_occupation)
  RETURNING applicant_id INTO app_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state, submitted_at)
  VALUES (app_applicant, p_status, p_state, CASE WHEN p_status = 'draft' THEN NULL ELSE now() END)
  RETURNING application_id INTO app_id;
END;
$fx$ LANGUAGE plpgsql;

-- A complete vehicle by default (vin + garaging_street present, so DH-04 stays
-- clear); every rule-relevant field is a parameter so a case can vary exactly one.
CREATE FUNCTION pg_temp.add_veh(p_app UUID,
    p_category vehicle_category_t DEFAULT 'exotic', p_agreed BOOLEAN DEFAULT false,
    p_appraisal DATE DEFAULT NULL, p_mods TEXT DEFAULT NULL,
    p_use primary_use_t DEFAULT NULL, p_mileage INT DEFAULT NULL,
    p_vin TEXT DEFAULT 'VIN0037', p_street TEXT DEFAULT '1 Test St')
RETURNS UUID AS $fx$
DECLARE v UUID;
BEGIN
  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state,
    garaging_street, current_appraised_value, agreed_value_requested, appraisal_date,
    modifications, primary_use, annual_mileage)
  VALUES (p_app, 2022, 'Ferrari', 'SF90', p_vin, p_category,
    (SELECT garaging_state FROM applications WHERE application_id = p_app), p_street,
    500000, p_agreed, p_appraisal, p_mods, p_use, p_mileage)
  RETURNING vehicle_id INTO v;
  RETURN v;
END;
$fx$ LANGUAGE plpgsql;

-- A state rating-table version with a chosen agreed_value_rules payload (for
-- VV-03's live reappraisal-interval read).
CREATE FUNCTION pg_temp.onboard_avr(p_state CHAR(2), p_avr JSONB)
RETURNS void AS $fx$
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number,
     effective_range, agreed_value_rules)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0037-' || p_state,
          tstzrange(now() - interval '1 year', now() + interval '1 year', '[)'), p_avr);
$fx$ LANGUAGE sql;

-- ---------------------------------------------------------------------------
-- T1  VV-03: stale/missing appraisal when agreed value is requested ->
--     INFORMATION_REQUEST. The interval is read LIVE from the state registry,
--     falling back to the national default (3y) when the state is not onboarded
--     or the value is null/"TBD". The 115%-overvaluation limb is deliberately
--     not implemented (no requested-amount field) - not exercised here.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_ignore UUID; v_reason TEXT;
BEGIN
  BEGIN
    -- (a) agreed value requested, appraisal MISSING -> fires.
    SELECT app_id FROM pg_temp.mk('T1a', 'ZZ') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', true, NULL);
    IF evaluate_vv03(v_app) IS DISTINCT FROM 'INFORMATION_REQUEST' THEN
      RAISE EXCEPTION '0037-T1 FAILED: agreed-value-requested with a missing appraisal did not fire VV-03';
    END IF;
    SELECT reason_code INTO v_reason FROM decision_log WHERE application_id = v_app AND rule_id = 'VV-03';
    IF v_reason IS DISTINCT FROM 'VV03_STALE_OR_UNSUPPORTED_AGREED_VALUE' THEN
      RAISE EXCEPTION '0037-T1 FAILED: VV-03 reason_code was %, expected VV03_STALE_OR_UNSUPPORTED_AGREED_VALUE', v_reason;
    END IF;

    -- (b) agreed value NOT requested, appraisal missing -> not fired (gated on the request).
    SELECT app_id FROM pg_temp.mk('T1b', 'ZZ') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL);
    IF evaluate_vv03(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T1 FAILED: VV-03 fired without agreed value being requested';
    END IF;

    -- (c) un-onboarded state, national default 3y: appraisal 2y old -> within window,
    --     not fired; 4y old -> stale, fires.
    SELECT app_id FROM pg_temp.mk('T1c1', 'ZZ') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', true, (now() - interval '2 years')::date);
    IF evaluate_vv03(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T1 FAILED: a 2y-old appraisal fired under the 3y national default (should be within window)';
    END IF;
    SELECT app_id FROM pg_temp.mk('T1c2', 'ZZ') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', true, (now() - interval '4 years')::date);
    IF evaluate_vv03(v_app) IS DISTINCT FROM 'INFORMATION_REQUEST' THEN
      RAISE EXCEPTION '0037-T1 FAILED: a 4y-old appraisal did not fire under the 3y national default';
    END IF;

    -- (d) LIVE registry interval: state V1 declares reappraisal_interval_years=1, so
    --     the SAME 2y-old appraisal that cleared under the default now fires; a
    --     6-month-old one does not. This proves the live read, not the fallback.
    PERFORM pg_temp.onboard_avr('V1', '{"reappraisal_interval_years": 1}'::jsonb);
    SELECT app_id FROM pg_temp.mk('T1d1', 'V1') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', true, (now() - interval '2 years')::date);
    IF evaluate_vv03(v_app) IS DISTINCT FROM 'INFORMATION_REQUEST' THEN
      RAISE EXCEPTION '0037-T1 FAILED: a 2y-old appraisal did not fire under a live state interval of 1y';
    END IF;
    SELECT app_id FROM pg_temp.mk('T1d2', 'V1') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', true, (now() - interval '6 months')::date);
    IF evaluate_vv03(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T1 FAILED: a 6-month-old appraisal fired under a live state interval of 1y';
    END IF;

    -- (e) onboarded state whose agreed_value_rules has no interval -> falls back to
    --     the national default (2y-old appraisal clears).
    PERFORM pg_temp.onboard_avr('V0', '{}'::jsonb);
    SELECT app_id FROM pg_temp.mk('T1e', 'V0') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', true, (now() - interval '2 years')::date);
    IF evaluate_vv03(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T1 FAILED: a 2y-old appraisal fired for a state with no interval (should fall back to 3y default)';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0037-T1 pass: VV-03 fires on missing/stale appraisal only when agreed value is requested; interval read live from the registry, falling back to the 3y national default';
END $$;

-- ---------------------------------------------------------------------------
-- T2  VV-04: modifications present but still production_luxury -> MANUAL_REVIEW_REQUIRED.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID;
BEGIN
  BEGIN
    -- (a) modified + still production_luxury -> fires.
    SELECT app_id FROM pg_temp.mk('T2a', 'CA') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'production_luxury', false, NULL, 'twin-turbo upgrade, coilovers');
    IF evaluate_vv04(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_REQUIRED' THEN
      RAISE EXCEPTION '0037-T2 FAILED: a modified production_luxury vehicle did not fire VV-04';
    END IF;

    -- (b) modified but correctly categorised modified_performance -> not fired.
    SELECT app_id FROM pg_temp.mk('T2b', 'CA') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'modified_performance', false, NULL, 'twin-turbo upgrade');
    IF evaluate_vv04(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T2 FAILED: VV-04 fired on a correctly-categorised modified_performance vehicle';
    END IF;

    -- (c) production_luxury, no modifications -> not fired.
    SELECT app_id FROM pg_temp.mk('T2c', 'CA') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'production_luxury', false, NULL, NULL);
    IF evaluate_vv04(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T2 FAILED: VV-04 fired on an unmodified production_luxury vehicle';
    END IF;

    -- (d) blank/whitespace modifications string -> not a real modification, not fired.
    SELECT app_id FROM pg_temp.mk('T2d', 'CA') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'production_luxury', false, NULL, '   ');
    IF evaluate_vv04(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T2 FAILED: VV-04 fired on a blank modifications string';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0037-T2 pass: VV-04 fires only on a modified vehicle still categorised production_luxury, not when re-categorised or unmodified or blank';
END $$;

-- ---------------------------------------------------------------------------
-- T3  DH-03: suspended/revoked license (applicant or additional driver) ->
--     MANUAL_REVIEW_SENIOR. 'expired' does not count.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_applicant UUID;
BEGIN
  BEGIN
    -- (a) applicant suspended -> fires.
    SELECT app_id, app_applicant FROM pg_temp.mk('T3a', 'CA') INTO v_app, v_applicant;
    UPDATE applicants SET license_status = 'suspended' WHERE applicant_id = v_applicant;
    IF evaluate_dh03(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0037-T3 FAILED: a suspended applicant license did not fire DH-03';
    END IF;

    -- (b) additional driver revoked (applicant valid) -> fires (spans all drivers).
    SELECT app_id FROM pg_temp.mk('T3b', 'CA') INTO v_app;
    INSERT INTO additional_drivers (application_id, name, license_status)
    VALUES (v_app, 'Spouse', 'revoked');
    IF evaluate_dh03(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0037-T3 FAILED: a revoked additional-driver license did not fire DH-03';
    END IF;

    -- (c) everyone valid -> not fired.
    SELECT app_id FROM pg_temp.mk('T3c', 'CA') INTO v_app;
    INSERT INTO additional_drivers (application_id, name, license_status) VALUES (v_app, 'Spouse', 'valid');
    IF evaluate_dh03(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T3 FAILED: DH-03 fired with all licenses valid';
    END IF;

    -- (d) expired (not suspended/revoked) -> not fired.
    SELECT app_id, app_applicant FROM pg_temp.mk('T3d', 'CA') INTO v_app, v_applicant;
    UPDATE applicants SET license_status = 'expired' WHERE applicant_id = v_applicant;
    IF evaluate_dh03(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T3 FAILED: DH-03 fired on an expired (not suspended/revoked) license';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0037-T3 pass: DH-03 fires MANUAL_REVIEW_SENIOR on a suspended/revoked applicant or additional-driver license, ignores expired and valid';
END $$;

-- ---------------------------------------------------------------------------
-- T4  DH-04: insufficient data on a SUBMITTED application -> INFORMATION_REQUEST.
--     A draft is never gated.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_applicant UUID; v_reason TEXT;
BEGIN
  BEGIN
    -- (a) submitted, applicant missing license_status -> fires.
    SELECT app_id, app_applicant FROM pg_temp.mk('T4a', 'CA') INTO v_app, v_applicant;
    PERFORM pg_temp.add_veh(v_app);
    UPDATE applicants SET license_status = NULL WHERE applicant_id = v_applicant;
    IF evaluate_dh04(v_app) IS DISTINCT FROM 'INFORMATION_REQUEST' THEN
      RAISE EXCEPTION '0037-T4 FAILED: a missing applicant license_status did not fire DH-04';
    END IF;
    SELECT reason_code INTO v_reason FROM decision_log WHERE application_id = v_app AND rule_id = 'DH-04';
    IF v_reason IS DISTINCT FROM 'DH04_INSUFFICIENT_DATA_FOR_RISK_COMPUTATION' THEN
      RAISE EXCEPTION '0037-T4 FAILED: DH-04 reason_code was %, expected DH04_INSUFFICIENT_DATA_FOR_RISK_COMPUTATION', v_reason;
    END IF;

    -- (b) submitted, vehicle missing vin -> fires.
    SELECT app_id FROM pg_temp.mk('T4b', 'CA') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL, NULL, NULL, NULL, NULL);  -- p_vin NULL
    IF evaluate_dh04(v_app) IS DISTINCT FROM 'INFORMATION_REQUEST' THEN
      RAISE EXCEPTION '0037-T4 FAILED: a missing vehicle vin did not fire DH-04';
    END IF;

    -- (c) submitted, vehicle missing garaging_street -> fires.
    SELECT app_id FROM pg_temp.mk('T4c', 'CA') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL, NULL, NULL, NULL, 'VIN0037', NULL);  -- p_street NULL
    IF evaluate_dh04(v_app) IS DISTINCT FROM 'INFORMATION_REQUEST' THEN
      RAISE EXCEPTION '0037-T4 FAILED: a missing vehicle garaging_street did not fire DH-04';
    END IF;

    -- (d) submitted, complete -> not fired.
    SELECT app_id FROM pg_temp.mk('T4d', 'CA') INTO v_app;
    PERFORM pg_temp.add_veh(v_app);
    IF evaluate_dh04(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T4 FAILED: DH-04 fired on a complete submitted application';
    END IF;

    -- (e) DRAFT with everything missing -> not gated, not fired.
    SELECT app_id, app_applicant FROM pg_temp.mk('T4e', 'CA', 'draft') INTO v_app, v_applicant;
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL, NULL, NULL, NULL, NULL, NULL);  -- vin+street NULL
    UPDATE applicants SET date_of_birth = NULL, license_status = NULL, years_licensed = NULL
    WHERE applicant_id = v_applicant;
    IF evaluate_dh04(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T4 FAILED: DH-04 fired on a DRAFT application (drafts must not be gated)';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0037-T4 pass: DH-04 fires INFORMATION_REQUEST on a submitted application missing applicant DOB/license/years or vehicle vin/garaging_street, never on a draft or a complete app';
END $$;

-- ---------------------------------------------------------------------------
-- T5  AL-02: prior non-renewal/cancellation flag -> MANUAL_REVIEW_REQUIRED.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID;
BEGIN
  BEGIN
    -- (a) flag true -> fires.
    SELECT app_id FROM pg_temp.mk('T5a', 'CA') INTO v_app;
    INSERT INTO prior_insurance (application_id, any_nonrenewal_or_cancellation_history, cancellation_reason)
    VALUES (v_app, true, 'non-payment');
    IF evaluate_al02(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_REQUIRED' THEN
      RAISE EXCEPTION '0037-T5 FAILED: a prior non-renewal/cancellation flag did not fire AL-02';
    END IF;

    -- (b) flag false -> not fired.
    SELECT app_id FROM pg_temp.mk('T5b', 'CA') INTO v_app;
    INSERT INTO prior_insurance (application_id, any_nonrenewal_or_cancellation_history)
    VALUES (v_app, false);
    IF evaluate_al02(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T5 FAILED: AL-02 fired with the flag false';
    END IF;

    -- (c) no prior_insurance row -> not fired (undisclosed is not a trigger).
    SELECT app_id FROM pg_temp.mk('T5c', 'CA') INTO v_app;
    IF evaluate_al02(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T5 FAILED: AL-02 fired with no prior_insurance row present';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0037-T5 pass: AL-02 fires only when the prior_insurance non-renewal/cancellation flag is true';
END $$;

-- ---------------------------------------------------------------------------
-- T6  CP-01: suspected undisclosed business use -> MANUAL_REVIEW_REQUIRED.
--     Two signals: high mileage on a pleasure/commute vehicle; or a commercial-
--     driving occupation with a single pleasure vehicle.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID;
BEGIN
  BEGIN
    -- (a) mileage signal: pleasure @ 20000 (the inclusive threshold) -> fires.
    SELECT app_id FROM pg_temp.mk('T6a', 'CA') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL, NULL, 'pleasure', 20000);
    IF evaluate_cp01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_REQUIRED' THEN
      RAISE EXCEPTION '0037-T6 FAILED: pleasure use @ 20000 miles did not fire CP-01 (mileage signal)';
    END IF;

    -- (b) mileage boundary: 19999 -> not fired.
    SELECT app_id FROM pg_temp.mk('T6b', 'CA') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL, NULL, 'pleasure', 19999);
    IF evaluate_cp01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T6 FAILED: pleasure use @ 19999 miles fired CP-01 (threshold is inclusive at 20000)';
    END IF;

    -- (c) occupation signal: real-estate occupation + single pleasure vehicle -> fires.
    SELECT app_id FROM pg_temp.mk('T6c', 'CA', 'submitted', NULL, 'Real Estate Agent') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL, NULL, 'pleasure', 5000);
    IF evaluate_cp01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_REQUIRED' THEN
      RAISE EXCEPTION '0037-T6 FAILED: a commercial-driving occupation with a single pleasure vehicle did not fire CP-01 (occupation signal)';
    END IF;

    -- (d) same occupation but TWO vehicles -> the single-vehicle qualifier suppresses it.
    SELECT app_id FROM pg_temp.mk('T6d', 'CA', 'submitted', NULL, 'Real Estate Agent') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL, NULL, 'pleasure', 5000);
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL, NULL, 'pleasure', 5000, 'VIN0037B');
    IF evaluate_cp01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T6 FAILED: the occupation signal fired with two vehicles (single-vehicle qualifier not applied)';
    END IF;

    -- (e) ordinary occupation, ordinary mileage -> not fired.
    SELECT app_id FROM pg_temp.mk('T6e', 'CA', 'submitted', NULL, 'Software Engineer') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', false, NULL, NULL, 'commute', 10000);
    IF evaluate_cp01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T6 FAILED: CP-01 fired on an ordinary occupation with ordinary mileage';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0037-T6 pass: CP-01 fires on high pleasure/commute mileage (>=20000) or a commercial-driving occupation with a single pleasure vehicle, and is quiet otherwise';
END $$;

-- ---------------------------------------------------------------------------
-- T7  PC-01: garaging state != mailing state -> MANUAL_REVIEW_REQUIRED.
--     territory_rating_basis is descriptive metadata, not rule logic.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID;
BEGIN
  BEGIN
    -- (a) mismatch (garaging CT, mailing NY) -> fires.
    SELECT app_id FROM pg_temp.mk('T7a', 'CT', 'submitted', 'NY') INTO v_app;
    IF evaluate_pc01(v_app) IS DISTINCT FROM 'MANUAL_REVIEW_REQUIRED' THEN
      RAISE EXCEPTION '0037-T7 FAILED: garaging CT / mailing NY did not fire PC-01';
    END IF;

    -- (b) match (both CT) -> not fired.
    SELECT app_id FROM pg_temp.mk('T7b', 'CT', 'submitted', 'CT') INTO v_app;
    IF evaluate_pc01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T7 FAILED: PC-01 fired when garaging and mailing states match';
    END IF;

    -- (c) mailing_state NULL -> cannot compare, not fired.
    SELECT app_id FROM pg_temp.mk('T7c', 'CT', 'submitted', NULL) INTO v_app;
    IF evaluate_pc01(v_app) IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T7 FAILED: PC-01 fired with a null mailing_state (no comparison possible)';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0037-T7 pass: PC-01 fires on a garaging/mailing state mismatch, not on a match or a null mailing_state';
END $$;

-- ---------------------------------------------------------------------------
-- T8  Orchestrator integration: twelve rules now, one row each. A complete clean
--     application returns AUTO_PROCEED with twelve non-fired rows; a single new
--     rule tripping (DH-03 suspended) makes the orchestrator return its action
--     and flags exactly that rule, still twelve rows total.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_applicant UUID; v_n INT; v_action referral_action_t; v_dh03_fired BOOLEAN;
BEGIN
  BEGIN
    -- Clean, complete, onboarded state -> AUTO_PROCEED, 12 rows, none fired.
    PERFORM pg_temp.onboard_avr('T8', '{"reappraisal_interval_years": 3}'::jsonb);
    SELECT app_id FROM pg_temp.mk('T8clean', 'T8') INTO v_app;
    PERFORM pg_temp.add_veh(v_app, 'exotic', true, (now() - interval '6 months')::date, NULL, 'pleasure', 5000);
    v_action := evaluate_application_referrals(v_app);
    IF v_action IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0037-T8 FAILED: a clean, complete application returned %, expected AUTO_PROCEED', v_action;
    END IF;
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app;
    IF v_n <> 12 THEN
      RAISE EXCEPTION '0037-T8 FAILED: expected 12 decision_log rows from one orchestrator call, got %', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app AND fired;
    IF v_n <> 0 THEN
      RAISE EXCEPTION '0037-T8 FAILED: a clean application had % fired rows, expected 0', v_n;
    END IF;

    -- One new rule trips: DH-03 (suspended applicant). Orchestrator returns
    -- MANUAL_REVIEW_SENIOR, DH-03 is the fired rule, still 12 rows.
    SELECT app_id, app_applicant FROM pg_temp.mk('T8dh03', 'T8') INTO v_app, v_applicant;
    PERFORM pg_temp.add_veh(v_app, 'exotic', true, (now() - interval '6 months')::date, NULL, 'pleasure', 5000);
    UPDATE applicants SET license_status = 'suspended' WHERE applicant_id = v_applicant;
    v_action := evaluate_application_referrals(v_app);
    IF v_action IS DISTINCT FROM 'MANUAL_REVIEW_SENIOR' THEN
      RAISE EXCEPTION '0037-T8 FAILED: a suspended-license application returned %, expected MANUAL_REVIEW_SENIOR (DH-03)', v_action;
    END IF;
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app;
    IF v_n <> 12 THEN
      RAISE EXCEPTION '0037-T8 FAILED: expected 12 decision_log rows, got %', v_n;
    END IF;
    SELECT fired INTO v_dh03_fired FROM decision_log WHERE application_id = v_app AND rule_id = 'DH-03';
    IF v_dh03_fired IS DISTINCT FROM true THEN
      RAISE EXCEPTION '0037-T8 FAILED: DH-03 was not the fired rule';
    END IF;
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app AND fired;
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0037-T8 FAILED: expected exactly 1 fired row (DH-03), got %', v_n;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0037-T8 pass: the orchestrator composes twelve rules (one row each); clean -> AUTO_PROCEED/0 fired, DH-03 trip -> MANUAL_REVIEW_SENIOR/1 fired';
END $$;

ROLLBACK;

\echo '0037: 8/8 cases passed (nothing committed)'
