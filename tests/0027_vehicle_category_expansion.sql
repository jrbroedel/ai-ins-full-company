-- Behavioural tests for ADR 0027: two new vehicle_category values
-- (pre_war_vintage, restomod_coachbuilt).
--
-- This is record-and-validate only - no rating/pricing logic exists for these
-- categories yet. The point of the suite is to confirm the new values are valid
-- end to end AND that nothing already built silently mishandles them: they must
-- insert on vehicles, snapshot through bind_policy() onto policy_vehicles, and
-- pass cleanly through the built referral engine (which does not branch on
-- vehicle_category, so a new value must behave exactly like any existing one).
--
-- Same discipline as the sibling suites: BEGIN...ROLLBACK, one self-unwinding DO
-- block per case, IS DISTINCT FROM on nullable reads, RAISE on any failure.

\set ON_ERROR_STOP on
BEGIN;

-- A bindable FK chain whose single vehicle is a chosen category. Returns the
-- issued quote id (ready to bind) and the application id.
CREATE FUNCTION pg_temp.mk(p_tag TEXT, p_state CHAR(2), p_category vehicle_category_t,
                           OUT quote_id UUID, OUT app_id UUID)
AS $fx$
DECLARE v_applicant UUID; v_rating UUID; v_vehicle UUID; v_driver UUID;
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0027-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO v_rating;

  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0027-' || p_tag) RETURNING applicant_id INTO v_applicant;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'submitted', p_state) RETURNING application_id INTO app_id;

  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state)
  VALUES (app_id, 1938, 'Bugatti', 'Type 57', 'VIN0027' || p_tag, p_category, p_state)
  RETURNING vehicle_id INTO v_vehicle;

  INSERT INTO additional_drivers (application_id, name, date_of_birth)
  VALUES (app_id, 'Driver ' || p_tag, DATE '1980-01-01') RETURNING driver_id INTO v_driver;

  INSERT INTO quotes
    (application_id, state_rating_table_record_id, premium_amount, rating_basis, status,
     broker_channel, broker_commission_rate)
  VALUES (app_id, v_rating, 10000, '{}'::jsonb, 'issued', 'retail', 10)
  RETURNING quotes.quote_id INTO quote_id;
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  Both new categories are valid on vehicles, and are NOT any of the four
--     originals (a genuine, distinct expansion).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_q UUID; v_app UUID; v_cat vehicle_category_t;
        c TEXT; st CHAR(2); i INT := 0;
BEGIN
  BEGIN
    -- Distinct state per iteration: state_rating_table_versions carries an
    -- exclusion on (state, effective_range), and both fixtures live in this one
    -- (un-rolled-back-between-iterations) subtransaction.
    FOREACH c IN ARRAY ARRAY['pre_war_vintage','restomod_coachbuilt'] LOOP
      i := i + 1;
      st := CASE i WHEN 1 THEN 'CA' ELSE 'NV' END;
      SELECT * FROM pg_temp.mk('T1_' || c, st, c::vehicle_category_t) INTO v_q, v_app;
      SELECT vehicle_category INTO v_cat FROM vehicles WHERE application_id = v_app;
      IF v_cat IS DISTINCT FROM c::vehicle_category_t THEN
        RAISE EXCEPTION '0027-T1 FAILED: vehicle stored category %, expected %', v_cat, c;
      END IF;
      IF v_cat IN ('production_luxury','exotic','classic_collector','modified_performance') THEN
        RAISE EXCEPTION '0027-T1 FAILED: % collided with an existing category', c;
      END IF;
    END LOOP;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0027-T1 pass: pre_war_vintage and restomod_coachbuilt are valid, distinct vehicle categories';
END $$;

-- ---------------------------------------------------------------------------
-- T2  A new category snapshots through bind_policy() onto policy_vehicles,
--     exactly like any existing category (the snapshot columns are the same
--     enum type, so nothing special-cases the value).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_q UUID; v_app UUID; v_policy UUID; v_cat vehicle_category_t;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T2', 'NV', 'restomod_coachbuilt') INTO v_q, v_app;
    v_policy := bind_policy(v_q, 'POL-0027-T2', '0027-suite');
    SELECT vehicle_category INTO v_cat FROM policy_vehicles WHERE policy_id = v_policy;
    IF v_cat IS DISTINCT FROM 'restomod_coachbuilt'::vehicle_category_t THEN
      RAISE EXCEPTION '0027-T2 FAILED: bound policy vehicle category is %, expected restomod_coachbuilt', v_cat;
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0027-T2 pass: a new category snapshots through bind onto policy_vehicles';
END $$;

-- ---------------------------------------------------------------------------
-- T3  The built referral engine (ADR 0026) treats a new-category vehicle like
--     any other - none of AL-01/CP-02/DH-01/PC-03 branch on vehicle_category, so
--     the outcome is driven purely by the other facts, and all four decision_log
--     rows are still written. A clean, licensed application with a pre_war_vintage
--     vehicle must AUTO_PROCEED, not error or mis-route on the category.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_q UUID; v_app UUID; v_action referral_action_t; v_n INT;
BEGIN
  BEGIN
    -- 'QQ' onboarded so PC-03 does not fire; single small vehicle, no claims,
    -- no violations -> nothing fires regardless of the vehicle's category.
    SELECT * FROM pg_temp.mk('T3', 'QQ', 'pre_war_vintage') INTO v_q, v_app;
    -- (mk already inserted a QQ rating version, so the state is licensed and the
    -- ADR 0025 short-rate seed fired - both harmless here.)
    UPDATE vehicles SET current_appraised_value = 500000 WHERE application_id = v_app;

    v_action := evaluate_application_referrals(v_app);
    IF v_action IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0027-T3 FAILED: a clean pre_war_vintage application returned %, expected AUTO_PROCEED (no rule branches on category)', v_action;
    END IF;
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_app;
    IF v_n <> 5 THEN
      RAISE EXCEPTION '0027-T3 FAILED: expected 5 decision_log rows (AL/CP/DH/PC/EL), got % - a new category must not disturb the referral pass', v_n;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0027-T3 pass: the referral engine handles a new-category vehicle like any other (no branch on category, 4 rows, correct outcome)';
END $$;

ROLLBACK;

\echo '0027: 3/3 cases passed (nothing committed)'
