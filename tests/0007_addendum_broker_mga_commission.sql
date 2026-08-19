-- Behavioural tests for the ADR 0007 addendum: broker + MGA acquisition
-- commission on quotes.
--
-- Confirmed rules: single broker channel (retail/wholesale) required on every
-- placement; broker commission 0-15%; MGA commission always fills the remainder
-- under a 30% combined ceiling (MGA = 30 - broker, a GENERATED column). Rates are
-- percentages, matching program_participants.commission_rate.
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, RAISE on any failed assertion,
-- IS DISTINCT FROM wherever a SELECT INTO could read NULL, rejection cases
-- asserting on the error MESSAGE.

\set ON_ERROR_STOP on
BEGIN;

-- Fixture: a bindable FK chain - rating version, applicant, application, one
-- vehicle (with a vin) and one driver (with identity), so a quote can both be
-- inserted and bound. Returns the application and rating-version ids.
CREATE FUNCTION pg_temp.mk_chain(p_tag TEXT, p_state CHAR(2), OUT app_id UUID, OUT rating_id UUID)
AS $fx$
DECLARE v_applicant UUID; v_vehicle UUID; v_driver UUID;
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0007A-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO rating_id;

  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0007A-' || p_tag) RETURNING applicant_id INTO v_applicant;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'submitted', p_state) RETURNING application_id INTO app_id;

  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state)
  VALUES (app_id, 2024, 'Aston Martin', 'DB12', 'VIN0007A' || p_tag, 'exotic', p_state)
  RETURNING vehicle_id INTO v_vehicle;

  INSERT INTO additional_drivers (application_id, name, date_of_birth)
  VALUES (app_id, 'Driver ' || p_tag, DATE '1980-01-01') RETURNING driver_id INTO v_driver;
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  broker_commission_rate CHECK boundary: 0 and 15 accepted, just over 15
--     rejected. MGA computes as 30 - broker at each accepted value.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_mga NUMERIC; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk_chain('T1', 'CA') INTO v_app, v_rating;

    -- 0% accepted, MGA = 30.
    INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
    VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'draft', 'retail', 0, '0007A-fixture')
    RETURNING mga_commission_rate INTO v_mga;
    IF v_mga IS DISTINCT FROM 30.00 THEN
      RAISE EXCEPTION '0007A-T1 FAILED: broker 0%% gave MGA %, expected 30.00', v_mga;
    END IF;

    -- Exactly 15% accepted (boundary), MGA = 15.
    INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
    VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'draft', 'wholesale', 15, '0007A-fixture')
    RETURNING mga_commission_rate INTO v_mga;
    IF v_mga IS DISTINCT FROM 15.00 THEN
      RAISE EXCEPTION '0007A-T1 FAILED: broker 15%% gave MGA %, expected 15.00', v_mga;
    END IF;

    -- Just over 15% rejected.
    v_ok := false;
    BEGIN
      INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
      VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'draft', 'retail', 15.01, '0007A-fixture');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%quotes_broker_commission_rate_ck%' THEN
      RAISE EXCEPTION '0007A-T1 FAILED: broker 15.01%% was not rejected by the 15%% CHECK (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- 16% likewise rejected.
    v_ok := false;
    BEGIN
      INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
      VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'draft', 'retail', 16, '0007A-fixture');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%quotes_broker_commission_rate_ck%' THEN
      RAISE EXCEPTION '0007A-T1 FAILED: broker 16%% was not rejected by the 15%% CHECK (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0007A-T1 pass: broker rate 0 and 15 accepted, >15 rejected; MGA fills to 30 at each';
END $$;

-- ---------------------------------------------------------------------------
-- T2  mga_commission_rate is derived (30 - broker) across values AND cannot be
--     set independently - it is GENERATED ALWAYS.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_mga NUMERIC; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk_chain('T2', 'NV') INTO v_app, v_rating;

    INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
    VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'draft', 'retail', 10, '0007A-fixture')
    RETURNING mga_commission_rate INTO v_mga;
    IF v_mga IS DISTINCT FROM 20.00 THEN
      RAISE EXCEPTION '0007A-T2 FAILED: broker 10%% gave MGA %, expected 20.00', v_mga;
    END IF;

    -- Trying to set mga_commission_rate directly is refused (GENERATED ALWAYS).
    v_ok := false;
    BEGIN
      INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, mga_commission_rate, quoted_by)
      VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'draft', 'retail', 10, 5, '0007A-fixture');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%mga_commission_rate%' THEN
      RAISE EXCEPTION '0007A-T2 FAILED: an explicit mga_commission_rate insert was not refused (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0007A-T2 pass: MGA = 30 - broker, and is not independently settable';
END $$;

-- ---------------------------------------------------------------------------
-- T3  broker_channel: NULL rejected, a value outside the two-value enum
--     rejected, both valid values accepted.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_ok BOOLEAN; v_err TEXT; v_n INT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk_chain('T3', 'AZ') INTO v_app, v_rating;

    -- NULL channel rejected (NOT NULL).
    v_ok := false;
    BEGIN
      INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
      VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'draft', NULL, 10, '0007A-fixture');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%broker_channel%' THEN
      RAISE EXCEPTION '0007A-T3 FAILED: a null broker_channel was not rejected (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- A value outside the enum rejected.
    v_ok := false;
    BEGIN
      INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
      VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'draft', 'direct', 10, '0007A-fixture');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%invalid input value for enum broker_channel_t%' THEN
      RAISE EXCEPTION '0007A-T3 FAILED: an out-of-enum broker_channel was not rejected (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- Both valid values accepted.
    INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
    VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'draft', 'retail', 10, '0007A-fixture'),
           (v_app, v_rating, 10000, '{}'::jsonb, 'draft', 'wholesale', 10, '0007A-fixture');
    SELECT count(*) INTO v_n FROM quotes WHERE application_id = v_app;
    IF v_n <> 2 THEN
      RAISE EXCEPTION '0007A-T3 FAILED: expected 2 accepted quotes (retail + wholesale), got %', v_n;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0007A-T3 pass: broker_channel rejects NULL and out-of-enum values, accepts retail and wholesale';
END $$;

-- ---------------------------------------------------------------------------
-- T4  The commission fields carry through to the bound policy, the same way
--     premium_amount does (the policy has no commission columns of its own; it
--     reads them off its quote via quote_id).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_quote UUID; v_policy UUID;
        v_channel broker_channel_t; v_broker NUMERIC; v_mga NUMERIC;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk_chain('T4', 'OR') INTO v_app, v_rating;

    INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
    VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'issued', 'wholesale', 12, '0007A-fixture')
    RETURNING quote_id INTO v_quote;

    v_policy := bind_policy(v_quote, 'POL-0007A-T4', '0007A-suite');

    SELECT q.broker_channel, q.broker_commission_rate, q.mga_commission_rate
      INTO v_channel, v_broker, v_mga
    FROM policies p JOIN quotes q ON q.quote_id = p.quote_id
    WHERE p.policy_id = v_policy;

    IF (v_channel, v_broker, v_mga) IS DISTINCT FROM ('wholesale'::broker_channel_t, 12.00, 18.00) THEN
      RAISE EXCEPTION '0007A-T4 FAILED: bound policy carries channel/broker/mga = %/%/%, expected wholesale/12.00/18.00',
        v_channel, v_broker, v_mga;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0007A-T4 pass: broker_channel / broker + MGA commission carry through bind to the policy, like premium_amount';
END $$;

ROLLBACK;

\echo '0007 addendum: 4/4 cases passed (nothing committed)'
