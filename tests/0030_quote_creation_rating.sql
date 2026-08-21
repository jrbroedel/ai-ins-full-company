-- Behavioural tests for ADR 0030: create_quote(), the first real quote-creation
-- write path, wiring compute_indicative_premium() (ADR 0028) into quote creation.
--
-- create_quote() resolves the application's single vehicle, calls the rating
-- function as a thin call, and writes premium_amount + a verbatim v1 rating_basis
-- onto a new 'issued' quote. Every failure mode fails loud with NO quote written:
--   T1  single-vehicle happy path - premium is the real computed number (asserted
--       against the function itself, not hand-typed), rating_basis stored verbatim,
--       and the ADR 0029 rating view now unpacks it end-to-end
--   T2  2+ vehicles -> QUOTE_RATING_MULTI_VEHICLE_UNSUPPORTED, no quote
--   T3  0 vehicles  -> QUOTE_RATING_NO_VEHICLE, no quote
--   T4  unconfigured territory -> TERRITORY_FACTOR_NOT_CONFIGURED (the resolved
--       failure mode: creation fails outright, no "unrated" quote ever exists)
--   T5  below the $100k floor -> now blocked at the ADR 0031 referral gate
--       (EL-01 DECLINE_RECOMMENDED) before rating runs, no quote
--   NB: every case now submit_application()s before create_quote() - the ADR 0031
--       referral gate requires a cleared evaluation first (contract change).
--   T6  unmapped category (modified_performance) -> RATING_CLASS_NOT_CONFIGURED_
--       FOR_CATEGORY, no quote - the thin call surfaces every rating guard
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, IS DISTINCT FROM on nullable reads, RAISE
-- on any failed assertion, rejection cases asserting on the error MESSAGE.

\set ON_ERROR_STOP on
BEGIN;

-- Fixture: a state's rating-table version (the FK quotes needs), an applicant,
-- an application in that state, and p_n vehicles at a chosen value/category.
-- p_n=0 builds an application with no vehicles. Territory factors are NOT loaded
-- here: only T0 has one (shipped by the schema), so a T0 fixture rates and any
-- other state hits TERRITORY_FACTOR_NOT_CONFIGURED - which is exactly T4.
CREATE FUNCTION pg_temp.mk(
  p_tag TEXT, p_state CHAR(2), p_value NUMERIC,
  p_n INT DEFAULT 1, p_category vehicle_category_t DEFAULT 'exotic',
  OUT app_id UUID, OUT rating_id UUID
) AS $fx$
DECLARE v_applicant UUID; i INT;
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0030-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO rating_id;

  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0030-' || p_tag) RETURNING applicant_id INTO v_applicant;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'submitted', p_state) RETURNING application_id INTO app_id;

  FOR i IN 1..p_n LOOP
    INSERT INTO vehicles (application_id, year, make, model, vehicle_category, garaging_state, current_appraised_value)
    VALUES (app_id, 2022, 'Ferrari', 'SF90-' || i, p_category, p_state, p_value);
  END LOOP;
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  Happy path: exotic @ $600,000 in T0 (factor 1.00). The quote is created,
--     'issued', priced at the real computed premium, and carries the breakdown
--     verbatim; the ADR 0029 rating view unpacks that stored basis end-to-end.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_quote UUID;
        v_prem NUMERIC; v_basis JSONB; v_status TEXT; v_chan broker_channel_t;
        v_broker NUMERIC; v_mga NUMERIC; v_app_on_quote UUID; v_prog UUID; v_quoted_by TEXT;
        v_exp_prem NUMERIC; v_exp_basis JSONB; r RECORD;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T1', 'T0', 600000, 1, 'exotic') INTO v_app, v_rating;
    -- ADR 0031: create_quote now requires a cleared referral evaluation. A clean
    -- single-vehicle T0 application (rating table present, so PC-03 does not fire)
    -- evaluates to AUTO_PROCEED, so the gate passes.
    PERFORM submit_application(v_app, '0030-suite');

    v_quote := create_quote(v_app, 'retail', 10, v_rating, NULL, '0030-suite');
    IF v_quote IS NULL THEN
      RAISE EXCEPTION '0030-T1 FAILED: create_quote returned NULL';
    END IF;

    SELECT premium_amount, rating_basis, status, broker_channel, broker_commission_rate,
           mga_commission_rate, application_id, program_id, quoted_by
      INTO v_prem, v_basis, v_status, v_chan, v_broker, v_mga, v_app_on_quote, v_prog, v_quoted_by
    FROM quotes WHERE quote_id = v_quote;

    -- The premium equals what the rating function itself returns for these inputs
    -- (tracks the real function, not a hand-typed number) - and is the documented
    -- worked example, 10754.72.
    SELECT indicative_premium, breakdown INTO v_exp_prem, v_exp_basis
    FROM compute_indicative_premium('exotic', 600000, 'T0');
    IF v_prem IS DISTINCT FROM v_exp_prem THEN
      RAISE EXCEPTION '0030-T1 FAILED: quote premium % <> compute_indicative_premium() %', v_prem, v_exp_prem;
    END IF;
    IF v_prem IS DISTINCT FROM 10754.72 THEN
      RAISE EXCEPTION '0030-T1 FAILED: quote premium is %, expected the documented 10754.72', v_prem;
    END IF;
    -- rating_basis stored verbatim - byte-for-byte the function's breakdown.
    IF v_basis IS DISTINCT FROM v_exp_basis THEN
      RAISE EXCEPTION '0030-T1 FAILED: rating_basis was reshaped, not stored verbatim';
    END IF;
    -- Issued (bindable), the commission/quote fields are what we passed, and
    -- quoted_by persisted the creator (the audit column, same as the other write
    -- functions record performed_by).
    IF (v_status, v_chan, v_broker, v_mga, v_app_on_quote, v_prog, v_quoted_by)
       IS DISTINCT FROM ('issued', 'retail'::broker_channel_t, 10.00, 20.00, v_app, NULL::uuid, '0030-suite') THEN
      RAISE EXCEPTION '0030-T1 FAILED: quote fields are status=%/chan=%/broker=%/mga=%/app=%/prog=%/by=%, expected issued/retail/10/20/app/NULL/0030-suite',
        v_status, v_chan, v_broker, v_mga, v_app_on_quote, v_prog, v_quoted_by;
    END IF;

    -- End-to-end: the ADR 0029 rating view unpacks the stored basis. This is the
    -- whole point of the wiring - a real quote's rating view is no longer NULL.
    SELECT rating_model, base_rate_per_100, territory_factor, gross_up_divisor, indicative_premium
      INTO r
    FROM luxauto_quote_rating_view WHERE quote_id = v_quote;
    IF (r.rating_model, r.base_rate_per_100, r.territory_factor, r.gross_up_divisor, r.indicative_premium)
       IS DISTINCT FROM ('indicative_premium_v1', 0.9500, 1.0000, 0.53, 10754.72) THEN
      RAISE EXCEPTION '0030-T1 FAILED: rating view unpack is model=%/rate=%/terr=%/div=%/prem=%, expected v1/0.95/1.00/0.53/10754.72',
        r.rating_model, r.base_rate_per_100, r.territory_factor, r.gross_up_divisor, r.indicative_premium;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0030-T1 pass: create_quote rates a single-vehicle quote (10754.72), stores the breakdown verbatim, issued and bindable; the rating view unpacks it';
END $$;

-- ---------------------------------------------------------------------------
-- T2  Two vehicles: rejected (v1 rates exactly one), and no quote is written.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T2', 'T0', 600000, 2, 'exotic') INTO v_app, v_rating;
    PERFORM submit_application(v_app, '0030-suite');  -- clean (2x $600k, no DUI) -> AUTO_PROCEED
    v_ok := false;
    BEGIN
      PERFORM create_quote(v_app, 'retail', 10, v_rating, NULL, '0030-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%QUOTE_RATING_MULTI_VEHICLE_UNSUPPORTED%' THEN
      RAISE EXCEPTION '0030-T2 FAILED: a 2-vehicle application was not rejected with QUOTE_RATING_MULTI_VEHICLE_UNSUPPORTED (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM quotes WHERE application_id = v_app) <> 0 THEN
      RAISE EXCEPTION '0030-T2 FAILED: a rejected multi-vehicle create still wrote a quote';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0030-T2 pass: 2+ vehicles rejected (QUOTE_RATING_MULTI_VEHICLE_UNSUPPORTED), no quote written';
END $$;

-- ---------------------------------------------------------------------------
-- T3  Zero vehicles: rejected, no quote written.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T3', 'T0', 600000, 0) INTO v_app, v_rating;
    PERFORM submit_application(v_app, '0030-suite');  -- no vehicles, no violations -> AUTO_PROCEED
    v_ok := false;
    BEGIN
      PERFORM create_quote(v_app, 'retail', 10, v_rating, NULL, '0030-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%QUOTE_RATING_NO_VEHICLE%' THEN
      RAISE EXCEPTION '0030-T3 FAILED: a no-vehicle application was not rejected with QUOTE_RATING_NO_VEHICLE (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM quotes WHERE application_id = v_app) <> 0 THEN
      RAISE EXCEPTION '0030-T3 FAILED: a rejected no-vehicle create still wrote a quote';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0030-T3 pass: 0 vehicles rejected (QUOTE_RATING_NO_VEHICLE), no quote written';
END $$;

-- ---------------------------------------------------------------------------
-- T4  Unconfigured territory (state ZZ has a rating-table version but no
--     territory_factors row): quote creation FAILS OUTRIGHT, no quote written.
--     This is the resolved failure mode - no "unrated" quote is ever created.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T4', 'ZZ', 600000, 1, 'exotic') INTO v_app, v_rating;
    -- ZZ has a rating-table version (mk creates it) so PC-03 does not fire; the
    -- app is clean (AUTO_PROCEED). The gate passes and rating then fails on the
    -- MISSING territory factor - the two are separate per-state loads (ADR 0030).
    PERFORM submit_application(v_app, '0030-suite');
    v_ok := false;
    BEGIN
      PERFORM create_quote(v_app, 'retail', 10, v_rating, NULL, '0030-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%TERRITORY_FACTOR_NOT_CONFIGURED%' THEN
      RAISE EXCEPTION '0030-T4 FAILED: an unconfigured-territory state was not rejected with TERRITORY_FACTOR_NOT_CONFIGURED (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM quotes WHERE application_id = v_app) <> 0 THEN
      RAISE EXCEPTION '0030-T4 FAILED: rating failed but a quote was still created - no unrated quote may exist';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0030-T4 pass: unconfigured territory fails outright (TERRITORY_FACTOR_NOT_CONFIGURED), no quote - never a partially-priced record';
END $$;

-- ---------------------------------------------------------------------------
-- T5  Below the $100k floor: now intercepted by the ADR 0031 referral gate
--     BEFORE rating runs. Submission fires EL-01 (DECLINE_RECOMMENDED), so the
--     application is not clear to auto-quote and create_quote refuses with
--     QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE - it never reaches
--     compute_indicative_premium()'s own RATING_BELOW_AGREED_VALUE_FLOOR guard,
--     which remains a backstop (exercised directly in tests/0028). No quote.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T5', 'T0', 99999.99, 1, 'exotic') INTO v_app, v_rating;
    PERFORM submit_application(v_app, '0030-suite');  -- EL-01 fires -> DECLINE_RECOMMENDED
    v_ok := false;
    BEGIN
      PERFORM create_quote(v_app, 'retail', 10, v_rating, NULL, '0030-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE%' THEN
      RAISE EXCEPTION '0030-T5 FAILED: a below-floor risk was not rejected at the referral gate with QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM quotes WHERE application_id = v_app) <> 0 THEN
      RAISE EXCEPTION '0030-T5 FAILED: a below-floor create still wrote a quote';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0030-T5 pass: below the $100k floor blocked at the ADR 0031 referral gate (EL-01 DECLINE_RECOMMENDED -> QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE), no quote written';
END $$;

-- ---------------------------------------------------------------------------
-- T6  Unmapped category (modified_performance has no rating class in v1):
--     rejected, no quote - the thin call surfaces the rating function's category
--     guard just like the floor and territory guards.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk('T6', 'T0', 600000, 1, 'modified_performance') INTO v_app, v_rating;
    -- Clean app (category is not a referral factor) -> AUTO_PROCEED; the gate
    -- passes and rating then fails on the unmapped category.
    PERFORM submit_application(v_app, '0030-suite');
    v_ok := false;
    BEGIN
      PERFORM create_quote(v_app, 'retail', 10, v_rating, NULL, '0030-suite');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY%' THEN
      RAISE EXCEPTION '0030-T6 FAILED: an unmapped category was not rejected with RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY (ok=%, err=%)', v_ok, v_err;
    END IF;
    IF (SELECT count(*) FROM quotes WHERE application_id = v_app) <> 0 THEN
      RAISE EXCEPTION '0030-T6 FAILED: an unmapped-category create still wrote a quote';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0030-T6 pass: unmapped category rejected (RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY), no quote written';
END $$;

ROLLBACK;

\echo '0030: 6/6 cases passed (nothing committed)'
