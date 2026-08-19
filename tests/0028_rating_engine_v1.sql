-- Behavioural tests for ADR 0028: rating engine v1 (minimal core).
--
-- v1 = base rate (rating class x agreed-value band) x per-state territory factor
-- / 0.53 gross-up -> indicative_premium, plus the $100,000 agreed-value floor
-- (declined, not rated). The 84 base-rate rows, the 5-row category->class
-- mapping, and the single T0 territory row are loaded by the schema apply, so
-- the read-only rating tests need no fixtures; only the EL-01 referral test
-- builds an application.
--
-- Same discipline as the sibling suites: BEGIN...ROLLBACK, one self-unwinding DO
-- block per case, IS DISTINCT FROM on nullable reads, RAISE on any failure,
-- rejection cases asserting on the error message.

\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.mk_app(p_tag TEXT, p_state CHAR(2), p_value NUMERIC)
RETURNS UUID AS $fx$
DECLARE v_applicant UUID; v_app UUID;
BEGIN
  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0028-' || p_tag) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'submitted', p_state) RETURNING application_id INTO v_app;
  INSERT INTO vehicles (application_id, year, make, model, vehicle_category, garaging_state, current_appraised_value)
  VALUES (v_app, 2022, 'Ferrari', 'SF90', 'exotic', p_state, p_value);
  RETURN v_app;
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  Worked example: exotic (-> class 03 Supercar) @ $600,000 agreed value in
--     test state T0 (factor 1.00). The function's output is asserted against the
--     formula computed inline from the components it returned - so the test
--     tracks the real function, not a possibly-wrong hand-typed number - and the
--     documented figure (10754.72) is confirmed as a sanity check.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_prem NUMERIC; v_class SMALLINT; v_rate NUMERIC; v_terr NUMERIC;
BEGIN
  BEGIN
    SELECT indicative_premium, rating_vehicle_class, base_rate, territory_factor
      INTO v_prem, v_class, v_rate, v_terr
    FROM compute_indicative_premium('exotic', 600000, 'T0');

    IF v_class IS DISTINCT FROM 3 THEN
      RAISE EXCEPTION '0028-T1 FAILED: exotic mapped to class %, expected 3 (Supercar)', v_class;
    END IF;
    IF v_rate IS DISTINCT FROM 0.9500 THEN
      RAISE EXCEPTION '0028-T1 FAILED: class 3 @ $600k used base rate %, expected 0.95', v_rate;
    END IF;
    IF v_terr IS DISTINCT FROM 1.0000 THEN
      RAISE EXCEPTION '0028-T1 FAILED: T0 territory factor is %, expected 1.00', v_terr;
    END IF;
    -- The function output must equal the formula rebuilt from its own components.
    IF v_prem IS DISTINCT FROM ROUND(600000 / 100 * v_rate * v_terr / 0.53, 2) THEN
      RAISE EXCEPTION '0028-T1 FAILED: indicative_premium % does not match (agreed/100 x rate x terr / 0.53) = %',
        v_prem, ROUND(600000 / 100 * v_rate * v_terr / 0.53, 2);
    END IF;
    -- ...and that value is the documented 10754.72.
    IF v_prem IS DISTINCT FROM 10754.72 THEN
      RAISE EXCEPTION '0028-T1 FAILED: indicative_premium is %, expected the documented 10754.72', v_prem;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0028-T1 pass: exotic @ $600k / T0 -> class 3, rate 0.95, indicative premium 10754.72';
END $$;

-- ---------------------------------------------------------------------------
-- T2  The $100,000 floor, boundary-tested: exactly $100,000 rates; $99,999.99
--     is declined by the rating function itself (RATING_BELOW_AGREED_VALUE_FLOOR).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_prem NUMERIC; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    -- Exactly at the floor: rates (band 1, rate 1.42 for class 3).
    SELECT indicative_premium INTO v_prem FROM compute_indicative_premium('exotic', 100000, 'T0');
    IF v_prem IS NULL OR v_prem IS DISTINCT FROM ROUND(100000 / 100 * 1.42 * 1.00 / 0.53, 2) THEN
      RAISE EXCEPTION '0028-T2 FAILED: exactly $100,000 did not rate as expected, got %', v_prem;
    END IF;

    -- One cent below the floor: declined, not rated.
    v_ok := false;
    BEGIN
      PERFORM indicative_premium FROM compute_indicative_premium('exotic', 99999.99, 'T0');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%RATING_BELOW_AGREED_VALUE_FLOOR%' THEN
      RAISE EXCEPTION '0028-T2 FAILED: $99,999.99 was not declined by the rating function (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0028-T2 pass: the $100k floor rates at exactly 100000 and declines at 99999.99';
END $$;

-- ---------------------------------------------------------------------------
-- T3  EL-01 through evaluate_application_referrals(): a below-floor vehicle fires
--     EL01_BELOW_AGREED_VALUE_FLOOR -> DECLINE_RECOMMENDED, logged; an at/above
--     vehicle does not fire it. Five decision_log rows per call now.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_action referral_action_t; v_fired BOOLEAN; v_n INT;
BEGIN
  BEGIN
    -- Below floor: EL-01 fires and dominates (DECLINE_RECOMMENDED is more severe
    -- than any review action the other rules can emit).
    v_app := pg_temp.mk_app('T3below', 'ZZ', 99999.99);
    v_action := evaluate_application_referrals(v_app);
    IF v_action IS DISTINCT FROM 'DECLINE_RECOMMENDED' THEN
      RAISE EXCEPTION '0028-T3 FAILED: a below-floor application returned %, expected DECLINE_RECOMMENDED', v_action;
    END IF;
    SELECT fired INTO v_fired FROM decision_log WHERE application_id = v_app AND rule_id = 'EL-01';
    IF v_fired IS DISTINCT FROM true THEN
      RAISE EXCEPTION '0028-T3 FAILED: EL-01 did not fire for a below-floor application';
    END IF;
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app;
    IF v_n <> 5 THEN
      RAISE EXCEPTION '0028-T3 FAILED: expected 5 decision_log rows (AL/CP/DH/PC/EL), got %', v_n;
    END IF;

    -- At/above floor: EL-01 does not fire.
    v_app := pg_temp.mk_app('T3ok', 'ZZ', 500000);
    PERFORM evaluate_application_referrals(v_app);
    SELECT fired INTO v_fired FROM decision_log WHERE application_id = v_app AND rule_id = 'EL-01';
    IF v_fired IS DISTINCT FROM false THEN
      RAISE EXCEPTION '0028-T3 FAILED: EL-01 fired for an at/above-floor ($500k) application';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0028-T3 pass: EL-01 fires below the floor (DECLINE_RECOMMENDED, logged), clears above it; 5 rows per call';
END $$;

-- ---------------------------------------------------------------------------
-- T4  A category with no rating class mapping (modified_performance) raises
--     RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY - never a silent default class.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    v_ok := false;
    BEGIN
      PERFORM indicative_premium FROM compute_indicative_premium('modified_performance', 600000, 'T0');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY%' THEN
      RAISE EXCEPTION '0028-T4 FAILED: modified_performance did not raise RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY (ok=%, err=%)', v_ok, v_err;
    END IF;
    -- And it is genuinely still a valid intake category (no mapping row, but the
    -- enum value exists).
    IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid
                   WHERE t.typname='vehicle_category_t' AND e.enumlabel='modified_performance') THEN
      RAISE EXCEPTION '0028-T4 FAILED: modified_performance is no longer a valid vehicle_category (it must stay valid for intake)';
    END IF;
    IF EXISTS (SELECT 1 FROM vehicle_category_rating_class WHERE vehicle_category='modified_performance') THEN
      RAISE EXCEPTION '0028-T4 FAILED: modified_performance unexpectedly has a rating class mapping';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0028-T4 pass: modified_performance is valid for intake but raises RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY, no silent default';
END $$;

-- ---------------------------------------------------------------------------
-- T5  An unconfigured state (anything but T0) raises TERRITORY_FACTOR_NOT_CONFIGURED.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    v_ok := false;
    BEGIN
      PERFORM indicative_premium FROM compute_indicative_premium('exotic', 600000, 'ZZ');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%TERRITORY_FACTOR_NOT_CONFIGURED%' THEN
      RAISE EXCEPTION '0028-T5 FAILED: an unconfigured state did not raise TERRITORY_FACTOR_NOT_CONFIGURED (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0028-T5 pass: an unconfigured state fails loud (TERRITORY_FACTOR_NOT_CONFIGURED)';
END $$;

-- ---------------------------------------------------------------------------
-- T6  All 84 base-rate rows loaded, and a spot-check of individual values across
--     classes and bands (not just the row count).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_n INT; v_rate NUMERIC;
BEGIN
  BEGIN
    SELECT count(*) INTO v_n FROM rating_base_rates;
    IF v_n <> 84 THEN
      RAISE EXCEPTION '0028-T6 FAILED: expected 84 base-rate rows (12 classes x 7 bands), got %', v_n;
    END IF;

    -- Spot-checks: (class, band lower) -> expected rate.
    -- class 1 @ [100k,250k) = 0.92
    SELECT base_rate INTO v_rate FROM rating_base_rates WHERE rating_vehicle_class=1 AND value_band_lower=100000;
    IF v_rate IS DISTINCT FROM 0.9200 THEN RAISE EXCEPTION '0028-T6 FAILED: class 1 band1 rate is %, expected 0.92', v_rate; END IF;
    -- class 3 @ [500k,1M) = 0.95
    SELECT base_rate INTO v_rate FROM rating_base_rates WHERE rating_vehicle_class=3 AND value_band_lower=500000;
    IF v_rate IS DISTINCT FROM 0.9500 THEN RAISE EXCEPTION '0028-T6 FAILED: class 3 band3 rate is %, expected 0.95', v_rate; END IF;
    -- class 4 @ [1M,2M) = 1.00
    SELECT base_rate INTO v_rate FROM rating_base_rates WHERE rating_vehicle_class=4 AND value_band_lower=1000000;
    IF v_rate IS DISTINCT FROM 1.0000 THEN RAISE EXCEPTION '0028-T6 FAILED: class 4 band4 rate is %, expected 1.00', v_rate; END IF;
    -- class 6 @ [100k,250k) = 0.50
    SELECT base_rate INTO v_rate FROM rating_base_rates WHERE rating_vehicle_class=6 AND value_band_lower=100000;
    IF v_rate IS DISTINCT FROM 0.5000 THEN RAISE EXCEPTION '0028-T6 FAILED: class 6 band1 rate is %, expected 0.50', v_rate; END IF;
    -- class 12 @ [10M,) = 0.55  (the open-ended top band)
    SELECT base_rate INTO v_rate FROM rating_base_rates WHERE rating_vehicle_class=12 AND value_band_lower=10000000 AND value_band_upper IS NULL;
    IF v_rate IS DISTINCT FROM 0.5500 THEN RAISE EXCEPTION '0028-T6 FAILED: class 12 top band rate is %, expected 0.55', v_rate; END IF;

    -- Provenance is marked on every row.
    IF EXISTS (SELECT 1 FROM rating_base_rates WHERE source_reference NOT ILIKE '%not actuarially certified%') THEN
      RAISE EXCEPTION '0028-T6 FAILED: some base-rate rows are missing the illustrative-benchmark disclaimer';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0028-T6 pass: 84 base-rate rows loaded, spot-checked across classes/bands, all marked as illustrative benchmarks';
END $$;

-- ---------------------------------------------------------------------------
-- T7  EL-01 firing ALONGSIDE other rules through the real orchestrator (not just
--     the synthetic GREATEST() pairs of 0026 T7): a below-floor application that
--     is also DUI-flagged, in an unlicensed state. EL-01 (DECLINE), DH-01
--     (SENIOR) and PC-03 (REQUIRED) all fire and log; the aggregate is the most
--     severe, DECLINE_RECOMMENDED.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_action referral_action_t;
        v_el BOOLEAN; v_el_action referral_action_t;
        v_dh BOOLEAN; v_dh_action referral_action_t; v_n INT;
BEGIN
  BEGIN
    v_app := pg_temp.mk_app('T7', 'ZZ', 99999.99);   -- below the $100k floor
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'DUI', true, 'MVR');

    v_action := evaluate_application_referrals(v_app);
    IF v_action IS DISTINCT FROM 'DECLINE_RECOMMENDED' THEN
      RAISE EXCEPTION '0028-T7 FAILED: below-floor + DUI returned %, expected DECLINE_RECOMMENDED (most severe of DECLINE/SENIOR/REQUIRED)', v_action;
    END IF;

    -- Both rules that fired are logged with the right action, side by side.
    SELECT fired, action_taken INTO v_el, v_el_action FROM decision_log WHERE application_id = v_app AND rule_id = 'EL-01';
    SELECT fired, action_taken INTO v_dh, v_dh_action FROM decision_log WHERE application_id = v_app AND rule_id = 'DH-01';
    IF (v_el, v_el_action) IS DISTINCT FROM (true, 'DECLINE_RECOMMENDED'::referral_action_t) THEN
      RAISE EXCEPTION '0028-T7 FAILED: EL-01 row is fired=%/action=%, expected true/DECLINE_RECOMMENDED', v_el, v_el_action;
    END IF;
    IF (v_dh, v_dh_action) IS DISTINCT FROM (true, 'MANUAL_REVIEW_SENIOR'::referral_action_t) THEN
      RAISE EXCEPTION '0028-T7 FAILED: DH-01 row is fired=%/action=%, expected true/MANUAL_REVIEW_SENIOR', v_dh, v_dh_action;
    END IF;
    -- Five rows total, three fired (EL-01, DH-01, PC-03) - EL-01 firing does not
    -- suppress or duplicate any other rule's row.
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app;
    IF v_n <> 5 THEN
      RAISE EXCEPTION '0028-T7 FAILED: expected 5 decision_log rows, got %', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app AND fired;
    IF v_n <> 3 THEN
      RAISE EXCEPTION '0028-T7 FAILED: expected 3 fired rows (EL-01, DH-01, PC-03), got %', v_n;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0028-T7 pass: EL-01 fires alongside DH-01 and PC-03 - each logged correctly, aggregate is the most-severe DECLINE_RECOMMENDED';
END $$;

ROLLBACK;

\echo '0028: 7/7 cases passed (nothing committed)'
