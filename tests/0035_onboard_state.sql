-- Behavioural tests for ADR 0035: onboard_state() as the sole sanctioned path for
-- onboarding a state's rating data, closing the ADR 0034 trigger-ordering footgun.
--
-- onboard_state() atomically loads the compliance record (firing the ADR 0025
-- short-rate seed trigger) AND its PD territory factor, and asserts the seed
-- fired. A BEFORE INSERT guard on state_rating_table_versions rejects any direct
-- insert unless the luxauto.onboarding_state escape flag is set (the same idiom as
-- the luxauto.superseding_* correction guards) - so onboard_state() is the only
-- ungated way in.
--
--   T1  onboard_state loads all three (rating version + territory factor + the
--       auto-seeded short-rate row) and returns the rating version's record_id;
--       the default ai_governance is the NY-standard baseline
--   T2  the guard rejects a raw INSERT without the flag, and allows one WITH it
--   T3  a state onboarded through onboard_state is fully quotable end to end
--       (PC-03 clears, create_quote produces a real premium with its factor)
--
-- NOTE: this suite deliberately does NOT set the file-top escape flag the other
-- suites use - T2 needs the guard active to prove it rejects.
--
-- Same discipline as the sibling suites: BEGIN...ROLLBACK, self-unwinding DO
-- blocks, IS DISTINCT FROM on nullable reads, RAISE on any failed assertion.

\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- T1  onboard_state loads all three rows atomically and returns the record_id.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_rec UUID; v_srtv UUID; v_terr NUMERIC; v_sr NUMERIC; v_basis short_rate_basis_t; v_ai JSONB;
BEGIN
  BEGIN
    v_rec := onboard_state('QQ', 'QQ Insurance Dept', 'file_and_use', 'Private Passenger Auto',
                           'SERFF-QQ-ILLUSTRATIVE', tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
                           1.0500, 'illustrative test PD territory factor');

    SELECT record_id, ai_governance INTO v_srtv, v_ai FROM state_rating_table_versions WHERE state = 'QQ';
    IF v_srtv IS DISTINCT FROM v_rec THEN
      RAISE EXCEPTION '0035-T1 FAILED: returned record_id % does not match the rating version row %', v_rec, v_srtv;
    END IF;

    SELECT pd_territory_factor INTO v_terr FROM territory_factors WHERE state = 'QQ';
    IF v_terr IS DISTINCT FROM 1.0500 THEN
      RAISE EXCEPTION '0035-T1 FAILED: territory factor is %, expected 1.05 (onboard_state did not load it)', v_terr;
    END IF;

    -- The ADR 0025 seed trigger fired (its exact signature).
    SELECT factor, basis INTO v_sr, v_basis FROM short_rate_factors WHERE state = 'QQ' AND serff_filing_tracking_number = 'internally set - not filed';
    IF (v_sr, v_basis) IS DISTINCT FROM (0.90, 'unearned_premium_multiplier'::short_rate_basis_t) THEN
      RAISE EXCEPTION '0035-T1 FAILED: short-rate seed is %/%, expected 0.90/unearned_premium_multiplier', v_sr, v_basis;
    END IF;

    -- Default ai_governance is the NY-standard documentation baseline.
    IF NOT (v_ai -> 'documentation_required' @> '["explainability_for_adverse_outcomes","vendor_audit_rights"]'::jsonb) THEN
      RAISE EXCEPTION '0035-T1 FAILED: default ai_governance is not the NY-standard baseline: %', v_ai;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0035-T1 pass: onboard_state atomically loads rating version + territory factor + the auto-seeded short-rate row, returns the record_id, defaults ai_governance to the NY standard';
END $$;

-- ---------------------------------------------------------------------------
-- T2  The guard: a raw INSERT is rejected without the flag, allowed with it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    -- Without the flag: rejected (this is the footgun made loud).
    v_ok := false;
    BEGIN
      INSERT INTO state_rating_table_versions (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
      VALUES ('QR', 'x', 'file_and_use', 'PPA', 'SERFF-QR', tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'));
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%STATE_RATING_TABLE_DIRECT_INSERT_FORBIDDEN%' THEN
      RAISE EXCEPTION '0035-T2 FAILED: a direct insert without the flag was not rejected (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'QR') THEN
      RAISE EXCEPTION '0035-T2 FAILED: a rejected direct insert still wrote a row';
    END IF;

    -- With the flag set (the escape hatch): allowed, and the ADR 0025 seed fires.
    PERFORM set_config('luxauto.onboarding_state', 'on', true);
    INSERT INTO state_rating_table_versions (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
    VALUES ('QR', 'x', 'file_and_use', 'PPA', 'SERFF-QR', tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'));
    PERFORM set_config('luxauto.onboarding_state', 'off', true);
    IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'QR') THEN
      RAISE EXCEPTION '0035-T2 FAILED: a flagged direct insert did not write (fixtures would be broken)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM short_rate_factors WHERE state = 'QR' AND factor = 0.90) THEN
      RAISE EXCEPTION '0035-T2 FAILED: the ADR 0025 seed did not fire on the flagged insert';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0035-T2 pass: the guard rejects a direct state_rating_table_versions insert without the flag (STATE_RATING_TABLE_DIRECT_INSERT_FORBIDDEN) and allows one with it (fixtures/escape hatch intact)';
END $$;

-- ---------------------------------------------------------------------------
-- T3  A state onboarded through onboard_state is fully quotable end to end.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_rec UUID; v_applicant UUID; v_app UUID; v_action referral_action_t;
        v_quote UUID; v_prem NUMERIC; v_exp NUMERIC;
BEGIN
  BEGIN
    v_rec := onboard_state('QS', 'QS Insurance Dept', 'file_and_use', 'Private Passenger Auto',
                           'SERFF-QS-ILLUSTRATIVE', tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
                           1.0500, 'illustrative test PD territory factor');

    INSERT INTO applicants (first_name, last_name) VALUES ('Test', '0035-QS') RETURNING applicant_id INTO v_applicant;
    INSERT INTO applications (applicant_id, status, garaging_state) VALUES (v_applicant, 'draft', 'QS') RETURNING application_id INTO v_app;
    INSERT INTO vehicles (application_id, year, make, model, vehicle_category, garaging_state, current_appraised_value)
    VALUES (v_app, 2022, 'Ferrari', 'SF90', 'exotic', 'QS', 600000);

    -- PC-03 clears because QS is now onboarded -> AUTO_PROCEED.
    v_action := submit_application(v_app, 'test');
    IF v_action IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0035-T3 FAILED: an app in a freshly-onboarded state evaluated to %, expected AUTO_PROCEED (PC-03 should clear)', v_action;
    END IF;

    -- create_quote rates with QS's onboarded territory factor.
    v_quote := create_quote(v_app, 'retail', 10, v_rec, NULL, 'test');
    SELECT premium_amount INTO v_prem FROM quotes WHERE quote_id = v_quote;
    SELECT indicative_premium INTO v_exp FROM compute_indicative_premium('exotic', 600000, 'QS');
    IF v_prem IS DISTINCT FROM v_exp OR v_prem <= 0 THEN
      RAISE EXCEPTION '0035-T3 FAILED: quote premium % does not match the rating function %, or is non-positive', v_prem, v_exp;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0035-T3 pass: a state onboarded through onboard_state is quotable end to end - PC-03 clears and create_quote produces a real premium with the loaded territory factor';
END $$;

ROLLBACK;

\echo '0035: 3/3 cases passed (nothing committed)'
