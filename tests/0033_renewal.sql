-- Behavioural tests for ADR 0033: automatic renewal.
--
-- generate_renewal_offers(as_of) finds active policies whose term ends within 30
-- days and auto-renews each by REUSING the pipeline (copy application ->
-- submit_application re-referral -> create_quote re-rating -> renew_policy bind at
-- a contiguous inception). renew_policy is the thin bind_policy wrapper;
-- policy_tenure_years is the cumulative-tenure helper; nonrenew_policy now adopts
-- it (the scoped Flag B change).
--
--   T1  happy path: an in-window policy is renewed, contiguous inception exact,
--       renewed_from/original/generation all correct, renewal re-rated
--   T2  a policy outside the 30-day window is not renewed
--   T3a nonrenewal decision -> the detector skips it (no offer)
--   T3b nonrenewal decision -> a direct renew_policy() is refused (structural guard)
--   T4  idempotency: two detector runs produce exactly one successor
--   T5  multi-generation: renew a renewal -> original_policy_id stays the TRUE
--       original, and policy_tenure_years is cumulative across the full chain
--   T6  nonrenew_policy regression: byte-identical for a no-history policy (Flag B
--       safe), and correctly cumulative for a renewed policy
--   T7  re-rating and re-referral actually FIRE on the renewal (not just a quote
--       appearing): the renewal application has decision_log rows and a v1 basis
--   T8  correct_policy_nonrenewal also reflects cumulative tenure on a renewal
--       (the Flag B extension - no divergence from nonrenew_policy)
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

-- Fixture: a real bound, rateable T0 policy built through the whole pipeline
-- (so a renewal has a genuine source application to copy). p_inception lets the
-- term be positioned relative to now(). Ensures a single shared T0 rating-table
-- version (the exclusion constraint forbids two overlapping ones per state).
CREATE FUNCTION pg_temp.mk_policy(p_tag TEXT, p_inception TIMESTAMPTZ, p_number TEXT)
RETURNS UUID AS $fx$
DECLARE v_rating UUID; v_applicant UUID; v_app UUID; v_quote UUID; v_policy UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'T0' AND effective_range @> now()) THEN
    INSERT INTO state_rating_table_versions
      (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
    VALUES ('T0', 'T0 DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0033',
            tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'));
  END IF;
  SELECT record_id INTO v_rating FROM state_rating_table_versions WHERE state = 'T0' AND effective_range @> now() LIMIT 1;

  -- date_of_birth / license_status / years_licensed (applicant) and garaging_street
  -- (vehicle) populated so DH-04 (ADR 0037) does not fire - and copy_application_
  -- for_renewal reuses this applicant and copies the vehicle's garaging_street/vin,
  -- so the renewal application stays complete too.
  INSERT INTO applicants (first_name, last_name, date_of_birth, license_status, years_licensed)
  VALUES ('Test', '0033-' || p_tag, DATE '1980-01-01', 'valid', 20) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state) VALUES (v_applicant, 'draft', 'T0') RETURNING application_id INTO v_app;
  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state, garaging_street, current_appraised_value)
  VALUES (v_app, 2022, 'Ferrari', 'SF90', 'VIN0033' || p_tag, 'exotic', 'T0', '1 Test St', 600000);

  PERFORM submit_application(v_app, 'test');
  v_quote := create_quote(v_app, 'retail', 10, v_rating, NULL, 'test');
  v_policy := bind_policy(v_quote, p_number, 'test', p_inception);
  RETURN v_policy;
END;
$fx$ LANGUAGE plpgsql;

-- Load a nonrenewal notice requirement for T0 (nonrenew_policy needs one).
CREATE FUNCTION pg_temp.load_notice(p_days SMALLINT, p_min_years SMALLINT)
RETURNS void AS $fx$
  INSERT INTO nonrenewal_notice_requirements
    (state, notice_days, min_policy_years, effective_range, regulatory_reference)
  VALUES ('T0', p_days, p_min_years, tstzrange('2000-01-01 00:00:00+00','2100-01-01 00:00:00+00','[)'), 'TEST-DOI');
$fx$ LANGUAGE sql;

-- Build a renewal of p_pred by hand (copy -> submit -> quote -> renew_policy),
-- for chains the detector's 30-day window wouldn't reach.
CREATE FUNCTION pg_temp.renew_by_hand(p_pred UUID, p_number TEXT)
RETURNS UUID AS $fx$
DECLARE v_src UUID; v_new_app UUID; v_rating UUID; v_state CHAR(2); v_quote UUID;
BEGIN
  SELECT ap.application_id, ap.garaging_state INTO v_src, v_state
  FROM policies p JOIN quotes q ON q.quote_id = p.quote_id JOIN applications ap ON ap.application_id = q.application_id
  WHERE p.policy_id = p_pred;
  SELECT record_id INTO v_rating FROM state_rating_table_versions WHERE state = v_state AND effective_range @> now() LIMIT 1;
  v_new_app := copy_application_for_renewal(v_src);
  PERFORM submit_application(v_new_app, 'test');
  v_quote := create_quote(v_new_app, 'retail', 10, v_rating, NULL, 'test');
  RETURN renew_policy(v_quote, p_pred, p_number, 'test');
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  Happy path.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_pred UUID; v_pred_end TIMESTAMPTZ; v_n INT; r RECORD; v_prem NUMERIC;
BEGIN
  BEGIN
    v_pred := pg_temp.mk_policy('T1', now() - interval '350 days', 'POL-0033-T1');
    SELECT upper(effective_range) INTO v_pred_end FROM policies WHERE policy_id = v_pred;

    SELECT renewed_count INTO v_n FROM generate_renewal_offers(now());
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0033-T1 FAILED: expected 1 renewal, got %', v_n;
    END IF;

    SELECT * INTO r FROM policies WHERE renewed_from_policy_id = v_pred;
    IF r.policy_id IS NULL THEN
      RAISE EXCEPTION '0033-T1 FAILED: no successor policy was created';
    END IF;
    -- Contiguous inception EXACTLY at the predecessor's term end; full-year term.
    IF lower(r.effective_range) IS DISTINCT FROM v_pred_end THEN
      RAISE EXCEPTION '0033-T1 FAILED: successor inception % is not the predecessor term end %', lower(r.effective_range), v_pred_end;
    END IF;
    IF upper(r.effective_range) IS DISTINCT FROM v_pred_end + interval '1 year' THEN
      RAISE EXCEPTION '0033-T1 FAILED: successor term is not a full year from the contiguous inception';
    END IF;
    IF (r.status, r.renewed_from_policy_id, r.original_policy_id, r.renewal_generation)
       IS DISTINCT FROM ('active'::policy_status_t, v_pred, v_pred, 1) THEN
      RAISE EXCEPTION '0033-T1 FAILED: successor linkage is status=%/renewed_from=%/original=%/gen=%, expected active/pred/pred/1',
        r.status, r.renewed_from_policy_id, r.original_policy_id, r.renewal_generation;
    END IF;
    -- Re-rated: the renewal quote carries the recomputed premium.
    SELECT premium_amount INTO v_prem FROM quotes q WHERE q.quote_id = r.quote_id;
    IF v_prem IS DISTINCT FROM 10754.72 THEN
      RAISE EXCEPTION '0033-T1 FAILED: renewal premium is %, expected the re-rated 10754.72', v_prem;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0033-T1 pass: an in-window policy is auto-renewed, contiguous inception exact, linkage/generation correct, re-rated to 10754.72';
END $$;

-- ---------------------------------------------------------------------------
-- T2  Outside the 30-day window: no renewal.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_pred UUID; v_n INT;
BEGIN
  BEGIN
    v_pred := pg_temp.mk_policy('T2', now() - interval '100 days', 'POL-0033-T2');  -- term ends ~265 days out
    SELECT renewed_count INTO v_n FROM generate_renewal_offers(now());
    IF v_n <> 0 THEN
      RAISE EXCEPTION '0033-T2 FAILED: a policy 265 days from term end was renewed (renewed=%)', v_n;
    END IF;
    IF EXISTS (SELECT 1 FROM policies WHERE renewed_from_policy_id = v_pred) THEN
      RAISE EXCEPTION '0033-T2 FAILED: an out-of-window policy got a successor';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0033-T2 pass: a policy outside the 30-day window is not renewed';
END $$;

-- ---------------------------------------------------------------------------
-- T3a  Nonrenewal decision -> the detector skips it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_pred UUID; v_n INT;
BEGIN
  BEGIN
    v_pred := pg_temp.mk_policy('T3a', now() - interval '350 days', 'POL-0033-T3a');
    PERFORM pg_temp.load_notice(10::smallint, NULL);
    PERFORM nonrenew_policy(v_pred, 'CX_TEST', now(), 'declining to renew', 'test');

    SELECT renewed_count INTO v_n FROM generate_renewal_offers(now());
    IF v_n <> 0 THEN
      RAISE EXCEPTION '0033-T3a FAILED: a nonrenewed policy was renewed by the detector (renewed=%)', v_n;
    END IF;
    IF EXISTS (SELECT 1 FROM policies WHERE renewed_from_policy_id = v_pred) THEN
      RAISE EXCEPTION '0033-T3a FAILED: a nonrenewed policy got a successor';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0033-T3a pass: the detector skips a policy with an active nonrenewal decision';
END $$;

-- ---------------------------------------------------------------------------
-- T3b  Nonrenewal decision -> a direct renew_policy() is refused (structural guard).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_pred UUID; v_ok BOOLEAN; v_err TEXT;
BEGIN
  BEGIN
    v_pred := pg_temp.mk_policy('T3b', now() - interval '350 days', 'POL-0033-T3b');
    PERFORM pg_temp.load_notice(10::smallint, NULL);
    PERFORM nonrenew_policy(v_pred, 'CX_TEST', now(), 'declining to renew', 'test');

    v_ok := false;
    BEGIN PERFORM renew_policy(uuid_generate_v4(), v_pred, 'POL-0033-T3b-R', 'test');
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
    IF NOT v_ok OR v_err NOT LIKE '%RENEWAL_POLICY_NONRENEWED%' THEN
      RAISE EXCEPTION '0033-T3b FAILED: renew_policy did not refuse a nonrenewed policy (ok=%, err=%)', v_ok, v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0033-T3b pass: renew_policy structurally refuses a policy with an active nonrenewal decision (RENEWAL_POLICY_NONRENEWED)';
END $$;

-- ---------------------------------------------------------------------------
-- T4  Idempotency: two detector runs -> exactly one successor.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_pred UUID; v_n1 INT; v_n2 INT; v_cnt INT;
BEGIN
  BEGIN
    v_pred := pg_temp.mk_policy('T4', now() - interval '350 days', 'POL-0033-T4');
    SELECT renewed_count INTO v_n1 FROM generate_renewal_offers(now());
    SELECT renewed_count INTO v_n2 FROM generate_renewal_offers(now());
    IF v_n1 <> 1 OR v_n2 <> 0 THEN
      RAISE EXCEPTION '0033-T4 FAILED: runs returned %/% renewals, expected 1/0', v_n1, v_n2;
    END IF;
    SELECT count(*) INTO v_cnt FROM policies WHERE renewed_from_policy_id = v_pred;
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION '0033-T4 FAILED: expected exactly one successor, got %', v_cnt;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0033-T4 pass: the detector is idempotent - a second run creates no duplicate successor';
END $$;

-- ---------------------------------------------------------------------------
-- T5  Multi-generation: renew a renewal. original_policy_id must stay the TRUE
--     original (not the immediate predecessor), and policy_tenure_years must be
--     cumulative across the whole chain.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_pred UUID; v_s1 UUID; v_s2 UUID; r RECORD; v_ref TIMESTAMPTZ := now();
BEGIN
  BEGIN
    v_pred := pg_temp.mk_policy('T5', now() - interval '350 days', 'POL-0033-T5');
    v_s1 := pg_temp.renew_by_hand(v_pred, 'POL-0033-T5-R1');   -- gen 1, original = pred
    v_s2 := pg_temp.renew_by_hand(v_s1,  'POL-0033-T5-R2');    -- gen 2, original still pred

    SELECT renewed_from_policy_id, original_policy_id, renewal_generation INTO r FROM policies WHERE policy_id = v_s2;
    IF (r.renewed_from_policy_id, r.original_policy_id, r.renewal_generation)
       IS DISTINCT FROM (v_s1, v_pred, 2) THEN
      RAISE EXCEPTION '0033-T5 FAILED: gen-2 linkage is renewed_from=%/original=%/gen=%, expected s1/pred/2',
        r.renewed_from_policy_id, r.original_policy_id, r.renewal_generation;
    END IF;

    -- Cumulative tenure: s2 measures from the ORIGINAL's inception, so it equals
    -- the predecessor's tenure at the same instant, and is well over a year old
    -- despite s2's own term being brand new.
    IF policy_tenure_years(v_s2, v_ref) IS DISTINCT FROM policy_tenure_years(v_pred, v_ref) THEN
      RAISE EXCEPTION '0033-T5 FAILED: s2 tenure % != original tenure % (not cumulative)',
        policy_tenure_years(v_s2, v_ref), policy_tenure_years(v_pred, v_ref);
    END IF;
    IF policy_tenure_years(v_s2, v_ref) <= 0.9 THEN
      RAISE EXCEPTION '0033-T5 FAILED: cumulative tenure % is not ~350 days (0.958y) - it used s2''s own new term, not the chain head', policy_tenure_years(v_s2, v_ref);
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0033-T5 pass: a renewal of a renewal keeps original_policy_id pinned to the true original; policy_tenure_years is cumulative across the chain';
END $$;

-- ---------------------------------------------------------------------------
-- T6  nonrenew_policy regression. (a) policy_tenure_years is byte-identical to
--     the old own-age formula for a policy with no renewal history (Flag B safe).
--     (b) nonrenew_policy on a RENEWED policy now uses cumulative tenure, so it
--     reaches a higher min_policy_years band that its own <1yr term never could.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_orig UUID; v_pred UUID; v_r1 UUID; v_at TIMESTAMPTZ := now();
        v_expected NUMERIC; v_required SMALLINT;
BEGIN
  BEGIN
    -- (a) byte-identical for a no-history policy.
    v_orig := pg_temp.mk_policy('T6a', now() - interval '200 days', 'POL-0033-T6a');
    SELECT EXTRACT(EPOCH FROM (v_at - lower(effective_range))) / (365.25 * 86400)
      INTO v_expected FROM policies WHERE policy_id = v_orig;
    IF policy_tenure_years(v_orig, v_at) IS DISTINCT FROM v_expected THEN
      RAISE EXCEPTION '0033-T6 FAILED: policy_tenure_years % != inline own-age formula % for an original policy (Flag B not behaviour-preserving)',
        policy_tenure_years(v_orig, v_at), v_expected;
    END IF;

    -- (b) a renewed policy whose OWN term is current but whose cumulative tenure
    -- (from an original bound 400 days ago) exceeds 1 year -> the min_years=1 band.
    PERFORM pg_temp.load_notice(10::smallint, NULL);       -- base band
    PERFORM pg_temp.load_notice(45::smallint, 1::smallint); -- 1+ year tenure band
    v_pred := pg_temp.mk_policy('T6b', now() - interval '400 days', 'POL-0033-T6b'); -- term ended ~35d ago
    v_r1 := pg_temp.renew_by_hand(v_pred, 'POL-0033-T6b-R1'); -- contiguous: current term, cumulative tenure ~1.1y

    PERFORM nonrenew_policy(v_r1, 'CX_TEST', now(), 'declining the renewed term', 'test');
    SELECT notice_days_required INTO v_required FROM policy_nonrenewals WHERE policy_id = v_r1 AND NOT isempty(effective_range);
    IF v_required <> 45 THEN
      RAISE EXCEPTION '0033-T6 FAILED: nonrenew_policy recorded notice_days_required=% for a >1yr-tenure renewal, expected 45 (the 1+ year band). Own-age would have given 10 - proving it did NOT use cumulative tenure', v_required;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0033-T6 pass: policy_tenure_years is byte-identical to the old formula for a no-history policy; nonrenew_policy now reaches a tenure band via cumulative tenure on a renewal';
END $$;

-- ---------------------------------------------------------------------------
-- T7  Re-rating and re-referral actually fire on the renewal (not merely a quote
--     appearing): the renewal application has the 12 decision_log rows a submission
--     writes, and the renewal quote carries a v1 rating_basis.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_pred UUID; v_succ UUID; v_ren_app UUID; v_n INT; v_model TEXT;
BEGIN
  BEGIN
    v_pred := pg_temp.mk_policy('T7', now() - interval '350 days', 'POL-0033-T7');
    PERFORM generate_renewal_offers(now());

    SELECT p.policy_id, q.application_id INTO v_succ, v_ren_app
    FROM policies p JOIN quotes q ON q.quote_id = p.quote_id
    WHERE p.renewed_from_policy_id = v_pred;
    IF v_succ IS NULL THEN
      RAISE EXCEPTION '0033-T7 FAILED: no successor to inspect';
    END IF;
    -- The renewal application is a DISTINCT, fresh application (not the predecessor's).
    IF v_ren_app = (SELECT q.application_id FROM policies p JOIN quotes q ON q.quote_id = p.quote_id WHERE p.policy_id = v_pred) THEN
      RAISE EXCEPTION '0033-T7 FAILED: the renewal reused the predecessor application instead of a fresh copy';
    END IF;

    -- Re-referral fired: submit_application wrote the 12 decision_log rows.
    SELECT count(*) INTO v_n FROM decision_log WHERE application_id = v_ren_app;
    IF v_n <> 12 THEN
      RAISE EXCEPTION '0033-T7 FAILED: renewal application has % decision_log rows, expected 12 (re-referral did not fire)', v_n;
    END IF;

    -- Re-rating fired: the renewal quote carries a v1 rating_basis.
    SELECT rating_basis ->> 'model' INTO v_model FROM quotes q JOIN policies p ON p.quote_id = q.quote_id WHERE p.policy_id = v_succ;
    IF v_model IS DISTINCT FROM 'indicative_premium_v1' THEN
      RAISE EXCEPTION '0033-T7 FAILED: renewal quote rating_basis model is %, expected indicative_premium_v1 (re-rating did not fire)', v_model;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0033-T7 pass: the renewal pipeline really runs - a fresh copied application with 12 decision_log rows (re-referral) and a v1 rating_basis (re-rating)';
END $$;

-- ---------------------------------------------------------------------------
-- T8  correct_policy_nonrenewal regression (Flag B extended): correcting a
--     nonrenewal on a renewed policy also uses CUMULATIVE tenure, so it re-
--     validates against the same >1yr band nonrenew_policy used - no divergence.
--     Own-age would have re-validated against the base (10-day) band.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_pred UUID; v_r1 UUID; v_nr UUID; v_required SMALLINT;
BEGIN
  BEGIN
    PERFORM pg_temp.load_notice(10::smallint, NULL);
    PERFORM pg_temp.load_notice(45::smallint, 1::smallint);
    v_pred := pg_temp.mk_policy('T8', now() - interval '400 days', 'POL-0033-T8'); -- term ended ~35d ago
    v_r1 := pg_temp.renew_by_hand(v_pred, 'POL-0033-T8-R1');  -- current term, cumulative tenure ~1.1y

    v_nr := nonrenew_policy(v_r1, 'CX_TEST', now(), 'declining', 'test');
    PERFORM correct_policy_nonrenewal(v_nr, now() + interval '1 day', 'CX_TEST', 'corrected notice date', 'test');

    -- The live (non-superseded) row after correction must carry the 45-day band,
    -- proving correct_policy_nonrenewal used cumulative tenure (own-age -> 10).
    SELECT notice_days_required INTO v_required
    FROM policy_nonrenewals WHERE policy_id = v_r1 AND NOT isempty(effective_range);
    IF v_required <> 45 THEN
      RAISE EXCEPTION '0033-T8 FAILED: corrected nonrenewal recorded notice_days_required=% for a >1yr-tenure renewal, expected 45 (own-age would give 10 - proving the correction did NOT use cumulative tenure)', v_required;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0033-T8 pass: correct_policy_nonrenewal also uses cumulative tenure on a renewed policy - no divergence from nonrenew_policy';
END $$;

ROLLBACK;

\echo '0033: 9/9 cases passed (nothing committed)'
