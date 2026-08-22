-- Behavioural tests for ADR 0029: the read-side visibility views over the five
-- domains whose write/compute side shipped in ADRs 0024-0028 with the Odoo read
-- side deferred and batched here.
--
-- These are the SQL views the Odoo models are backed by (luxauto_*_view). Every
-- relevant table is empty on live, so correctness is proven against known
-- fixtures inserted here, queried through the view, and asserted - never
-- eyeballed against live data. Covered:
--   T1  reinstatement view: the audit row joined to both policy numbers
--   T2  short-rate factor reference view: passthrough + derived range bounds
--   T3  decision-log detail view: every row, and distinct id hashes (no collision)
--   T4  application-referral summary view: max(action_taken) derivation with NO
--       orchestrator call (no write side effect), and latest-row-per-rule
--   T5  commission view: channel + both rates + premium, per quote
--   T6  rating view: a v1-shaped rating_basis JSONB unpacked into typed columns,
--       and a non-v1 basis yielding NULLs rather than an error
--   T7  every view rejects INSERT/UPDATE/DELETE from the `odoo` role
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, IS DISTINCT FROM on nullable reads,
-- RAISE on any failed assertion.

\set ON_ERROR_STOP on
BEGIN;
-- ADR 0035: this suite writes state_rating_table_versions rows directly as fixtures;
-- the onboard_state() guard permits that through the escape flag, set for this
-- rolled-back test transaction (tests use the hatch; production goes through onboard_state).
SET LOCAL luxauto.onboarding_state = 'on';

-- ---------------------------------------------------------------------------
-- Fixtures. Three helpers, each a trimmed version of the ones the ADRs under
-- test already use: mk_chain (0007A), mk_app (0028), and mk_reinstatement (0024).
-- ---------------------------------------------------------------------------

-- A rating version + applicant + application + one vehicle + one driver, enough
-- to insert and bind a quote. Returns the application and rating-version ids.
CREATE FUNCTION pg_temp.mk_chain(p_tag TEXT, p_state CHAR(2), OUT app_id UUID, OUT rating_id UUID)
AS $fx$
DECLARE v_applicant UUID; v_vehicle UUID; v_driver UUID;
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0029-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO rating_id;

  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0029-' || p_tag) RETURNING applicant_id INTO v_applicant;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'submitted', p_state) RETURNING application_id INTO app_id;

  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state)
  VALUES (app_id, 2024, 'Aston Martin', 'DB12', 'VIN0029' || p_tag, 'exotic', p_state)
  RETURNING vehicle_id INTO v_vehicle;

  INSERT INTO additional_drivers (application_id, name, date_of_birth)
  VALUES (app_id, 'Driver ' || p_tag, DATE '1980-01-01') RETURNING driver_id INTO v_driver;
END;
$fx$ LANGUAGE plpgsql;

-- An application with one vehicle at a chosen appraised value, for the referral
-- rules. Returns the application id (and exposes the vehicle for re-valuation).
CREATE FUNCTION pg_temp.mk_app(p_tag TEXT, p_state CHAR(2), p_value NUMERIC, OUT app_id UUID, OUT veh_id UUID)
AS $fx$
DECLARE v_applicant UUID;
BEGIN
  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0029-' || p_tag) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'submitted', p_state) RETURNING application_id INTO app_id;
  INSERT INTO vehicles (application_id, year, make, model, vehicle_category, garaging_state, current_appraised_value)
  VALUES (app_id, 2022, 'Ferrari', 'SF90', 'exotic', p_state, p_value)
  RETURNING vehicle_id INTO veh_id;
END;
$fx$ LANGUAGE plpgsql;

-- A completed reinstatement: a prior policy bound then cancelled at a backdated
-- date, then reinstate_policy() run against it. Returns every id the
-- reinstatement view is expected to surface, plus the gap start.
CREATE FUNCTION pg_temp.mk_reinstatement(
  p_tag TEXT, p_state CHAR(2),
  OUT reinstatement_id UUID, OUT new_policy_id UUID, OUT prior_policy_id UUID,
  OUT cancellation_id UUID, OUT new_policy_number TEXT, OUT prior_policy_number TEXT,
  OUT gap_start TIMESTAMPTZ
) AS $fx$
DECLARE
  v_rating UUID; v_applicant UUID; v_app UUID; v_vehicle UUID; v_driver UUID;
  v_quote1 UUID; v_quote2 UUID;
  v_prior_term TSTZRANGE := tstzrange(now() - interval '60 days', now() + interval '305 days', '[)');
BEGIN
  prior_policy_number := 'POL-0029-' || p_tag || '-PRIOR';
  new_policy_number   := 'POL-0029-' || p_tag || '-NEW';

  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0029R-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO v_rating;

  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0029R-' || p_tag) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'bound', p_state) RETURNING application_id INTO v_app;
  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state)
  VALUES (v_app, 2024, 'Aston Martin', 'DB12', 'VIN0029R' || p_tag, 'exotic', p_state)
  RETURNING vehicle_id INTO v_vehicle;
  INSERT INTO additional_drivers (application_id, name, date_of_birth)
  VALUES (v_app, 'Driver ' || p_tag, DATE '1980-01-01') RETURNING driver_id INTO v_driver;

  INSERT INTO quotes
    (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
  VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'bound', 'retail', 10, '0029-fixture')
  RETURNING quote_id INTO v_quote1;

  INSERT INTO policies (quote_id, policy_number, effective_range, status)
  VALUES (v_quote1, prior_policy_number, v_prior_term, 'active')
  RETURNING policy_id INTO prior_policy_id;

  INSERT INTO policy_vehicles
    (policy_id, source_vehicle_id, effective_range, year, make, model, vin, vehicle_category, garaging_state)
  VALUES (prior_policy_id, v_vehicle, v_prior_term, 2024, 'Aston Martin', 'DB12', 'VIN0029R' || p_tag, 'exotic', p_state);
  INSERT INTO policy_drivers
    (policy_id, source_driver_id, effective_range, name, date_of_birth)
  VALUES (prior_policy_id, v_driver, v_prior_term, 'Driver ' || p_tag, DATE '1980-01-01');
  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (prior_policy_id, 'bound', '0029-suite', 'fixture prior policy');

  SET CONSTRAINTS ALL IMMEDIATE;

  cancellation_id := cancel_policy(prior_policy_id, 'insured_initiated', 'CX_INSURED_REQUEST',
                                   'pro_rata', now() - interval '1 day', 'lapsed, to be reinstated', '0029-suite');
  SELECT lower(pc.effective_range) INTO gap_start
  FROM policy_cancellations pc WHERE pc.cancellation_id = mk_reinstatement.cancellation_id;

  INSERT INTO quotes
    (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
  VALUES (v_app, v_rating, 10000, '{}'::jsonb, 'issued', 'retail', 10, '0029-fixture')
  RETURNING quote_id INTO v_quote2;

  new_policy_id := reinstate_policy(v_quote2, cancellation_id, new_policy_number, 'ATTEST-0029-' || p_tag, '0029-suite');
  SELECT pr.reinstatement_id INTO reinstatement_id
  FROM policy_reinstatements pr WHERE pr.new_policy_id = mk_reinstatement.new_policy_id;
END;
$fx$ LANGUAGE plpgsql;

-- The id hash every view uses for its Odoo primary key.
CREATE FUNCTION pg_temp.hash_id(p UUID) RETURNS INT AS $fx$
  SELECT ('x' || substr(md5(p::text), 1, 8))::bit(32)::int;
$fx$ LANGUAGE sql IMMUTABLE;

-- ---------------------------------------------------------------------------
-- T1  Reinstatement view: one row per reinstatement, both policy numbers joined
--     in, the gap start / attestation / performer surfaced, and id = the hash.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r RECORD;
  v_reinst UUID; v_new UUID; v_prior UUID; v_cx UUID;
  v_new_no TEXT; v_prior_no TEXT; v_gap TIMESTAMPTZ; v_n INT;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk_reinstatement('T1', 'CA')
      INTO v_reinst, v_new, v_prior, v_cx, v_new_no, v_prior_no, v_gap;

    SELECT count(*) INTO v_n FROM luxauto_policy_reinstatement_view WHERE reinstatement_id = v_reinst;
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0029-T1 FAILED: expected exactly one view row for the reinstatement, got %', v_n;
    END IF;

    SELECT * INTO r FROM luxauto_policy_reinstatement_view WHERE reinstatement_id = v_reinst;
    IF (r.id, r.new_policy_id, r.new_policy_number, r.prior_policy_id, r.prior_policy_number,
        r.cancellation_id, r.gap_start, r.attestation_reference, r.performed_by)
       IS DISTINCT FROM
       (pg_temp.hash_id(v_reinst), v_new, v_new_no, v_prior, v_prior_no,
        v_cx, v_gap, 'ATTEST-0029-T1', '0029-suite') THEN
      RAISE EXCEPTION '0029-T1 FAILED: reinstatement view row mismatch: id=%, new=%/%, prior=%/%, cx=%, gap=%, att=%, by=%',
        r.id, r.new_policy_id, r.new_policy_number, r.prior_policy_id, r.prior_policy_number,
        r.cancellation_id, r.gap_start, r.attestation_reference, r.performed_by;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0029-T1 pass: reinstatement view joins both policy numbers and surfaces the audit row, id = hash(reinstatement_id)';
END $$;

-- ---------------------------------------------------------------------------
-- T2  Short-rate factor reference view: a passthrough of the filed factor, with
--     effective_from/effective_to derived from the (unmapped) range bounds. Two
--     rows get distinct id hashes. NULL program_id/applies_to pass through as
--     NULL (a statewide row that applies to both cancellation types).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r RECORD; v_id1 UUID; v_id2 UUID; v_from TIMESTAMPTZ := '2025-01-01 00:00:00+00'; v_to TIMESTAMPTZ := '2030-01-01 00:00:00+00';
BEGIN
  BEGIN
    INSERT INTO short_rate_factors (state, factor, basis, effective_range, serff_filing_tracking_number, rate_manual_reference)
    VALUES ('CA', 0.9000, 'unearned_premium_multiplier', tstzrange(v_from, v_to, '[)'), 'SERFF-0029-SR-A', 'Rate Manual 12.3')
    RETURNING short_rate_factor_id INTO v_id1;
    -- A second, program- and type-specific row, to prove the id hashes differ.
    INSERT INTO short_rate_factors (state, factor, basis, applies_to, effective_range, serff_filing_tracking_number)
    VALUES ('NV', 0.8500, 'percent_of_annual_premium_returned', 'insured_initiated', tstzrange(v_from, v_to, '[)'), 'SERFF-0029-SR-B')
    RETURNING short_rate_factor_id INTO v_id2;

    SELECT * INTO r FROM luxauto_short_rate_factor_view WHERE short_rate_factor_id = v_id1;
    IF (r.id, r.state, r.program_id, r.factor, r.basis, r.applies_to,
        r.effective_from, r.effective_to, r.serff_filing_tracking_number, r.rate_manual_reference)
       IS DISTINCT FROM
       (pg_temp.hash_id(v_id1), 'CA', NULL::uuid, 0.9000, 'unearned_premium_multiplier'::short_rate_basis_t,
        NULL::cancellation_type_t, v_from, v_to, 'SERFF-0029-SR-A', 'Rate Manual 12.3') THEN
      RAISE EXCEPTION '0029-T2 FAILED: short-rate row A mismatch: id=%, state=%, prog=%, factor=%, basis=%, applies=%, from=%, to=%, serff=%, manual=%',
        r.id, r.state, r.program_id, r.factor, r.basis, r.applies_to, r.effective_from, r.effective_to, r.serff_filing_tracking_number, r.rate_manual_reference;
    END IF;

    SELECT applies_to INTO r FROM luxauto_short_rate_factor_view WHERE short_rate_factor_id = v_id2;
    IF r.applies_to IS DISTINCT FROM 'insured_initiated' THEN
      RAISE EXCEPTION '0029-T2 FAILED: short-rate row B applies_to is %, expected insured_initiated', r.applies_to;
    END IF;

    IF pg_temp.hash_id(v_id1) = pg_temp.hash_id(v_id2) THEN
      RAISE EXCEPTION '0029-T2 FAILED: the two short-rate rows collided on the same id hash';
    END IF;
    IF (SELECT count(DISTINCT id) FROM luxauto_short_rate_factor_view WHERE short_rate_factor_id IN (v_id1, v_id2)) <> 2 THEN
      RAISE EXCEPTION '0029-T2 FAILED: expected two distinct ids for the two short-rate rows';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0029-T2 pass: short-rate reference view passes the filed factor through with derived range bounds; distinct id hashes';
END $$;

-- ---------------------------------------------------------------------------
-- T3  Decision-log detail view: every logged row appears (5 per orchestrator
--     call), with the right fired/action per rule, and the five id hashes are
--     distinct (no collision across a handful of rows).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_veh UUID; v_n INT; v_fired BOOLEAN; v_action referral_action_t;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk_app('T3', 'ZZ', 99999.99) INTO v_app, v_veh;  -- below the $100k floor
    PERFORM evaluate_application_referrals(v_app);

    SELECT count(*) INTO v_n FROM luxauto_decision_log_view WHERE application_id = v_app;
    IF v_n <> 5 THEN
      RAISE EXCEPTION '0029-T3 FAILED: expected 5 decision-log view rows, got %', v_n;
    END IF;
    SELECT count(DISTINCT id) INTO v_n FROM luxauto_decision_log_view WHERE application_id = v_app;
    IF v_n <> 5 THEN
      RAISE EXCEPTION '0029-T3 FAILED: the 5 decision-log rows do not have 5 distinct id hashes (got % distinct)', v_n;
    END IF;

    SELECT fired, action_taken INTO v_fired, v_action
    FROM luxauto_decision_log_view WHERE application_id = v_app AND rule_id = 'EL-01';
    IF (v_fired, v_action) IS DISTINCT FROM (true, 'DECLINE_RECOMMENDED'::referral_action_t) THEN
      RAISE EXCEPTION '0029-T3 FAILED: EL-01 row reads fired=%/action=%, expected true/DECLINE_RECOMMENDED', v_fired, v_action;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0029-T3 pass: decision-log detail view returns every row with correct fired/action and 5 distinct id hashes';
END $$;

-- ---------------------------------------------------------------------------
-- T4  Application-referral summary view, in two parts.
--
--   A) Derivation via max(action_taken), with NO orchestrator call. The
--      below-floor + DUI scenario from 0028 T7 (EL-01 DECLINE, DH-01 SENIOR,
--      PC-03 REQUIRED all fire) run once through the real orchestrator: the
--      summary must read DECLINE_RECOMMENDED / 3 fired / 5 rules, and SELECTing
--      from the view must write no new decision_log rows (proving the summary
--      derives from stored rows, never by calling evaluate_application_referrals).
--
--   B) Latest-row-per-rule, and no double-counting of history. now() is frozen at
--      the transaction start, so two orchestrator calls in this one test tx would
--      write identical created_at values and be indistinguishable - which is a
--      harness artifact (in production a re-evaluation is a later transaction with
--      a later now()), not a view property. So the two evaluation runs are staged
--      directly into decision_log at two explicit, distinct timestamps: an older
--      run where EL-01 fired DECLINE and DH-01 fired SENIOR, and a newer run where
--      both cleared and PC-03 fired REQUIRED. The summary must reflect only the
--      NEWER run per rule (most_severe MANUAL_REVIEW_REQUIRED, 1 fired), rule_count
--      stays 5 (not 10), and the detail view keeps all 10 rows.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_veh UUID; v_app2 UUID; v_veh2 UUID; r RECORD; v_before INT; v_after INT;
        v_t_old TIMESTAMPTZ := now() - interval '1 hour'; v_t_new TIMESTAMPTZ := now();
BEGIN
  BEGIN
    -- Part A: real orchestrator, most-severe derivation and no write-on-read.
    SELECT * FROM pg_temp.mk_app('T4a', 'ZZ', 99999.99) INTO v_app, v_veh;
    INSERT INTO person_violations (application_id, subject_driver_id, violation_date, violation_type, conviction, source)
    VALUES (v_app, NULL, (now() - interval '1 year')::date, 'DUI', true, 'MVR');

    PERFORM evaluate_application_referrals(v_app);

    SELECT count(*) INTO v_before FROM decision_log WHERE application_id = v_app;
    SELECT * INTO r FROM luxauto_application_referral_view WHERE application_id = v_app;
    SELECT count(*) INTO v_after FROM decision_log WHERE application_id = v_app;
    IF v_after <> v_before THEN
      RAISE EXCEPTION '0029-T4 FAILED: reading the summary view wrote decision_log rows (% -> %) - it must not call the orchestrator', v_before, v_after;
    END IF;
    IF (r.id, r.most_severe_action, r.fired_rule_count, r.rule_count)
       IS DISTINCT FROM (pg_temp.hash_id(v_app), 'DECLINE_RECOMMENDED'::referral_action_t, 3::bigint, 5::bigint) THEN
      RAISE EXCEPTION '0029-T4 FAILED: summary (part A) is id=%/action=%/fired=%/rules=%, expected hash/DECLINE_RECOMMENDED/3/5',
        r.id, r.most_severe_action, r.fired_rule_count, r.rule_count;
    END IF;

    -- Part B: two staged runs at distinct timestamps on a fresh application.
    SELECT * FROM pg_temp.mk_app('T4b', 'ZZ', 500000) INTO v_app2, v_veh2;
    -- Older run: EL-01 DECLINE (fired), DH-01 SENIOR (fired), the other three not fired.
    INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, created_at) VALUES
      (v_app2, 'EL-01', 'EL01_BELOW_AGREED_VALUE_FLOOR', 'DECLINE_RECOMMENDED',  true,  'system', v_t_old),
      (v_app2, 'DH-01', 'DH01_DUI_WITHIN_LOOKBACK',      'MANUAL_REVIEW_SENIOR', true,  'system', v_t_old),
      (v_app2, 'AL-01', 'AL01_ADVERSE_LOSS_HISTORY',     'AUTO_PROCEED',         false, 'system', v_t_old),
      (v_app2, 'CP-02', 'CP02_AGGREGATE_TIV_CAP',        'AUTO_PROCEED',         false, 'system', v_t_old),
      (v_app2, 'PC-03', 'PC03_UNLICENSED_STATE',         'AUTO_PROCEED',         false, 'system', v_t_old);
    -- Newer run: EL-01 and DH-01 now clear; PC-03 fires REQUIRED. The other two still clear.
    INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, created_at) VALUES
      (v_app2, 'EL-01', 'EL01_BELOW_AGREED_VALUE_FLOOR', 'AUTO_PROCEED',           false, 'system', v_t_new),
      (v_app2, 'DH-01', 'DH01_DUI_WITHIN_LOOKBACK',      'AUTO_PROCEED',           false, 'system', v_t_new),
      (v_app2, 'AL-01', 'AL01_ADVERSE_LOSS_HISTORY',     'AUTO_PROCEED',           false, 'system', v_t_new),
      (v_app2, 'CP-02', 'CP02_AGGREGATE_TIV_CAP',        'AUTO_PROCEED',           false, 'system', v_t_new),
      (v_app2, 'PC-03', 'PC03_UNLICENSED_STATE',         'MANUAL_REVIEW_REQUIRED', true,  'system', v_t_new);

    SELECT * INTO r FROM luxauto_application_referral_view WHERE application_id = v_app2;
    IF (r.most_severe_action, r.fired_rule_count, r.rule_count)
       IS DISTINCT FROM ('MANUAL_REVIEW_REQUIRED'::referral_action_t, 1::bigint, 5::bigint) THEN
      RAISE EXCEPTION '0029-T4 FAILED: summary (part B) is action=%/fired=%/rules=%, expected MANUAL_REVIEW_REQUIRED/1/5 (latest-per-rule, not double-counted)',
        r.most_severe_action, r.fired_rule_count, r.rule_count;
    END IF;
    IF r.evaluated_at IS DISTINCT FROM v_t_new THEN
      RAISE EXCEPTION '0029-T4 FAILED: summary evaluated_at is %, expected the newer run timestamp %', r.evaluated_at, v_t_new;
    END IF;
    IF (SELECT count(*) FROM luxauto_decision_log_view WHERE application_id = v_app2) <> 10 THEN
      RAISE EXCEPTION '0029-T4 FAILED: detail view lost audit history - expected 10 rows across two runs, got %',
        (SELECT count(*) FROM luxauto_decision_log_view WHERE application_id = v_app2);
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0029-T4 pass: summary derives most-severe via max() with no orchestrator call; latest-row-per-rule, no double-counting; detail keeps full history';
END $$;

-- ---------------------------------------------------------------------------
-- T5  Commission view: broker channel, both rates (MGA = 30 - broker), premium
--     and status, one row per quote.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_quote UUID; r RECORD;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk_chain('T5', 'OR') INTO v_app, v_rating;
    INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
    VALUES (v_app, v_rating, 25000, '{}'::jsonb, 'issued', 'wholesale', 12, '0029-fixture')
    RETURNING quote_id INTO v_quote;

    SELECT * INTO r FROM luxauto_quote_commission_view WHERE quote_id = v_quote;
    IF (r.id, r.application_id, r.premium_amount, r.broker_channel, r.broker_commission_rate, r.mga_commission_rate, r.quote_status)
       IS DISTINCT FROM
       (pg_temp.hash_id(v_quote), v_app, 25000.00, 'wholesale', 12.00, 18.00, 'issued') THEN
      RAISE EXCEPTION '0029-T5 FAILED: commission view row is id=%/app=%/prem=%/chan=%/broker=%/mga=%/status=%, expected hash/app/25000/wholesale/12/18/issued',
        r.id, r.application_id, r.premium_amount, r.broker_channel, r.broker_commission_rate, r.mga_commission_rate, r.quote_status;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0029-T5 pass: commission view surfaces channel, broker + MGA rates (30 - broker) and premium per quote';
END $$;

-- ---------------------------------------------------------------------------
-- T6  Rating view: a manually-inserted v1-shaped rating_basis (the exact
--     breakdown compute_indicative_premium() emits for exotic @ $600k in T0) is
--     unpacked into typed numeric/smallint columns. A separate quote with a
--     non-v1 basis ('{}') yields NULLs for every unpacked field - no cast error -
--     which is the intended behaviour until quote creation is wired to write a
--     v1 basis (scoped-out follow-up, see ADR 0029).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_rating UUID; v_quote_v1 UUID; v_quote_empty UUID; v_basis JSONB; r RECORD;
BEGIN
  BEGIN
    SELECT * FROM pg_temp.mk_chain('T6', 'WA') INTO v_app, v_rating;

    -- The real v1 breakdown, taken from the function itself (STABLE, no writes).
    SELECT breakdown INTO v_basis FROM compute_indicative_premium('exotic', 600000, 'T0');

    INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
    VALUES (v_app, v_rating, 10754.72, v_basis, 'issued', 'retail', 10, '0029-fixture')
    RETURNING quote_id INTO v_quote_v1;

    SELECT * INTO r FROM luxauto_quote_rating_view WHERE quote_id = v_quote_v1;
    IF (r.id, r.rating_model, r.agreed_value, r.rating_vehicle_class, r.rating_class_label,
        r.value_band_lower, r.value_band_upper, r.base_rate_per_100, r.base_loss_cost,
        r.territory_state, r.territory_factor, r.gross_up_divisor, r.indicative_premium)
       IS DISTINCT FROM
       (pg_temp.hash_id(v_quote_v1), 'indicative_premium_v1', 600000.00, 3::smallint, '03 Supercar',
        500000.00, 1000000.00, 0.9500, 5700.00,
        'T0', 1.0000, 0.53, 10754.72) THEN
      RAISE EXCEPTION '0029-T6 FAILED: v1 rating unpack mismatch: model=%, agreed=%, class=%/%, band=%..%, base=%, loss=%, terr=%/%, div=%, prem=%',
        r.rating_model, r.agreed_value, r.rating_vehicle_class, r.rating_class_label,
        r.value_band_lower, r.value_band_upper, r.base_rate_per_100, r.base_loss_cost,
        r.territory_state, r.territory_factor, r.gross_up_divisor, r.indicative_premium;
    END IF;

    -- A non-v1 basis: every unpacked field is NULL, no error.
    INSERT INTO quotes (application_id, state_rating_table_record_id, premium_amount, rating_basis, status, broker_channel, broker_commission_rate, quoted_by)
    VALUES (v_app, v_rating, 9999, '{}'::jsonb, 'draft', 'retail', 10, '0029-fixture')
    RETURNING quote_id INTO v_quote_empty;

    SELECT * INTO r FROM luxauto_quote_rating_view WHERE quote_id = v_quote_empty;
    IF r.rating_model IS NOT NULL OR r.agreed_value IS NOT NULL OR r.rating_vehicle_class IS NOT NULL
       OR r.base_rate_per_100 IS NOT NULL OR r.indicative_premium IS NOT NULL THEN
      RAISE EXCEPTION '0029-T6 FAILED: a non-v1 rating_basis did not yield NULL unpacked columns (model=%, agreed=%, prem=%)',
        r.rating_model, r.agreed_value, r.indicative_premium;
    END IF;
    -- The quote's own premium_amount still shows regardless of the basis shape.
    IF r.premium_amount IS DISTINCT FROM 9999.00 THEN
      RAISE EXCEPTION '0029-T6 FAILED: premium_amount not surfaced for a non-v1 quote, got %', r.premium_amount;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0029-T6 pass: v1 rating_basis unpacks into typed columns; a non-v1 basis yields NULLs, not an error';
END $$;

-- ---------------------------------------------------------------------------
-- T7  Read-only enforcement: from the `odoo` role, INSERT/UPDATE/DELETE against
--     each of the six views is rejected. odoo holds only SELECT, so every write
--     is refused - on privilege (42501, e.g. DELETE on a single-table view), or
--     because the view is not auto-updatable (55000, the join/aggregate views),
--     or because the targeted column is computed (0A000). All three are a
--     rejection; none lets a write reach a base table. A future change that
--     accidentally made a view writable would let the statement succeed (or fail
--     with an unrelated errcode), and this asserts against that.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_views TEXT[] := ARRAY[
    'luxauto_policy_reinstatement_view', 'luxauto_short_rate_factor_view',
    'luxauto_decision_log_view', 'luxauto_application_referral_view',
    'luxauto_quote_commission_view', 'luxauto_quote_rating_view'];
  v_view TEXT; v_op TEXT; v_sql TEXT; v_ok BOOLEAN; v_state TEXT;
BEGIN
  BEGIN
    SET LOCAL ROLE odoo;
    IF current_user <> 'odoo' THEN
      RAISE EXCEPTION '0029-T7 SETUP: could not assume the odoo role (current_user=%)', current_user;
    END IF;

    FOREACH v_view IN ARRAY v_views LOOP
      FOREACH v_op IN ARRAY ARRAY['UPDATE', 'INSERT', 'DELETE'] LOOP
        v_sql := CASE v_op
          WHEN 'UPDATE' THEN format('UPDATE %I SET id = id', v_view)
          WHEN 'DELETE' THEN format('DELETE FROM %I', v_view)
          ELSE format('INSERT INTO %I (id) VALUES (0)', v_view)
        END;
        v_ok := false;
        BEGIN
          EXECUTE v_sql;
        EXCEPTION WHEN OTHERS THEN v_ok := true; v_state := SQLSTATE;
        END;
        IF NOT v_ok OR v_state NOT IN ('42501', '0A000', '55000') THEN
          RESET ROLE;
          RAISE EXCEPTION '0029-T7 FAILED: % on % was not rejected as a read-only violation (ok=%, sqlstate=%)',
            v_op, v_view, v_ok, v_state;
        END IF;
      END LOOP;
    END LOOP;

    RESET ROLE;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0029-T7 pass: all six views reject INSERT/UPDATE/DELETE from the odoo role (privilege or non-updatable), no write reaches a base table';
END $$;

ROLLBACK;

\echo '0029: 7/7 cases passed (nothing committed)'
