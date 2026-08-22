-- Behavioural tests for ADR 0034: Connecticut, the first illustrative state
-- onboarded end to end, proven with the existing sample APP-0001 (Miriam
-- Ostrander, Greenwich CT) flowing through the real pipeline.
--
-- CT onboarding data (state_rating_table_versions + territory_factors) is seeded
-- by schemas/db/postgresql_schema.sql itself (illustrative, clearly marked), so
-- these tests read that persisted data; only APP-0001 is a fixture (rolled back).
--
--   T1  CT onboarding inserted correctly (compliance record + territory factor)
--   T2  the ADR 0025 short-rate auto-seed trigger fired for CT (a real state)
--   T3  PC-03 clears for a CT application, and STILL fires for an unlicensed
--       state - onboarding CT did not weaken the gate for everyone else
--   T4  full APP-0001 walkthrough: submit -> AUTO_PROCEED, create_quote -> the
--       real computed premium (4179.92) using CT's actual 1.12 factor, the ADR
--       0029 rating view unpacks it, and it binds into a real policy
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, IS DISTINCT FROM on nullable reads, RAISE
-- on any failed assertion.

\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- T1  CT onboarding present and correct (read from the persisted schema seed).
-- ---------------------------------------------------------------------------
DO $$
DECLARE r RECORD; v_factor NUMERIC; v_active BOOLEAN;
BEGIN
  BEGIN
    SELECT regulator_name, filing_status, (effective_range @> now()) AS active,
           credit_based_insurance_score ->> 'permitted' AS credit_permitted,
           ai_governance -> 'documentation_required' AS ai_docs
      INTO r
    FROM state_rating_table_versions WHERE state = 'CT';
    IF r IS NULL THEN
      RAISE EXCEPTION '0034-T1 FAILED: no state_rating_table_versions row for CT';
    END IF;
    IF (r.regulator_name, r.filing_status::text, r.active, r.credit_permitted)
       IS DISTINCT FROM ('Connecticut Insurance Department', 'prior_approval', true, 'true') THEN
      RAISE EXCEPTION '0034-T1 FAILED: CT record is regulator=%/filing=%/active=%/credit=%',
        r.regulator_name, r.filing_status, r.active, r.credit_permitted;
    END IF;
    -- Built to the NY-standard AI documentation bar (project baseline).
    IF NOT (r.ai_docs @> '["explainability_for_adverse_outcomes","vendor_audit_rights"]'::jsonb) THEN
      RAISE EXCEPTION '0034-T1 FAILED: CT ai_governance is not at the NY documentation standard: %', r.ai_docs;
    END IF;

    SELECT pd_territory_factor, (effective_range @> now()) INTO v_factor, v_active
    FROM territory_factors WHERE state = 'CT';
    IF (v_factor, v_active) IS DISTINCT FROM (1.1200, true) THEN
      RAISE EXCEPTION '0034-T1 FAILED: CT territory factor is %/active=%, expected 1.12/true', v_factor, v_active;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0034-T1 pass: CT is onboarded - prior_approval compliance record (credit permitted, NY-standard AI docs) and a 1.12 territory factor, both active';
END $$;

-- ---------------------------------------------------------------------------
-- T2  The ADR 0025 auto-seed trigger fired for CT (its first real-state run).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_factor NUMERIC; v_basis short_rate_basis_t; v_from NUMERIC; v_to NUMERIC;
BEGIN
  BEGIN
    SELECT factor, basis, elapsed_fraction_from, elapsed_fraction_to
      INTO v_factor, v_basis, v_from, v_to
    FROM short_rate_factors WHERE state = 'CT';
    IF v_factor IS NULL THEN
      RAISE EXCEPTION '0034-T2 FAILED: no short_rate_factors row for CT - the ADR 0025 auto-seed trigger did not fire on the real state insert';
    END IF;
    IF (v_factor, v_basis, v_from, v_to)
       IS DISTINCT FROM (0.9000, 'unearned_premium_multiplier'::short_rate_basis_t, 0.0000, 1.0000) THEN
      RAISE EXCEPTION '0034-T2 FAILED: CT short-rate seed is factor=%/basis=%/band=%..%, expected the flat 0.90 holdback',
        v_factor, v_basis, v_from, v_to;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0034-T2 pass: inserting the CT rating-table version auto-seeded a CT short_rate_factors row (flat 0.90) - the ADR 0025 trigger works for a real state, not just fixtures';
END $$;

-- ---------------------------------------------------------------------------
-- T3  PC-03 clears for CT and still fires for an unlicensed state.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_ct_app UUID; v_zz_app UUID; v_applicant UUID; v_ct_fired BOOLEAN; v_zz_fired BOOLEAN;
BEGIN
  BEGIN
    -- A CT application.
    INSERT INTO applicants (first_name, last_name) VALUES ('Test', '0034-CT') RETURNING applicant_id INTO v_applicant;
    INSERT INTO applications (applicant_id, status, garaging_state) VALUES (v_applicant, 'submitted', 'CT') RETURNING application_id INTO v_ct_app;
    PERFORM evaluate_application_referrals(v_ct_app);
    SELECT fired INTO v_ct_fired FROM decision_log WHERE application_id = v_ct_app AND rule_id = 'PC-03';
    IF v_ct_fired IS DISTINCT FROM false THEN
      RAISE EXCEPTION '0034-T3 FAILED: PC-03 fired for a CT application - CT is not being treated as licensed';
    END IF;

    -- An unlicensed state (ZZ has no state_rating_table_versions row): PC-03 must still fire.
    INSERT INTO applicants (first_name, last_name) VALUES ('Test', '0034-ZZ') RETURNING applicant_id INTO v_applicant;
    INSERT INTO applications (applicant_id, status, garaging_state) VALUES (v_applicant, 'submitted', 'ZZ') RETURNING application_id INTO v_zz_app;
    PERFORM evaluate_application_referrals(v_zz_app);
    SELECT fired INTO v_zz_fired FROM decision_log WHERE application_id = v_zz_app AND rule_id = 'PC-03';
    IF v_zz_fired IS DISTINCT FROM true THEN
      RAISE EXCEPTION '0034-T3 FAILED: PC-03 did NOT fire for an unlicensed state - onboarding CT weakened the gate for everyone else';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0034-T3 pass: PC-03 clears for a CT application (now licensed) and still fires for an unlicensed state - the gate is narrowed to CT, not weakened for all';
END $$;

-- ---------------------------------------------------------------------------
-- T4  The APP-0001 end-to-end walkthrough with real data and the real premium.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_applicant UUID; v_app UUID; v_ct_record UUID; v_action referral_action_t;
  v_quote UUID; v_prem NUMERIC; v_exp NUMERIC; r RECORD; v_policy UUID; v_status policy_status_t;
BEGIN
  BEGIN
    -- APP-0001's actual data.
    INSERT INTO applicants (first_name, last_name, date_of_birth, email, phone, mailing_city, mailing_state)
    VALUES ('Miriam', 'Ostrander', DATE '1971-03-14', 'm.ostrander@example.com', '555-010-0001', 'Greenwich', 'CT')
    RETURNING applicant_id INTO v_applicant;
    INSERT INTO applications (applicant_id, status, garaging_state)
    VALUES (v_applicant, 'draft', 'CT') RETURNING application_id INTO v_app;
    INSERT INTO vehicles (application_id, year, make, model, trim, vin, vehicle_category,
      purchase_price, current_appraised_value, agreed_value_requested, annual_mileage, primary_use, garaging_state)
    VALUES (v_app, 2023, 'Porsche', '911', 'Turbo S', 'WP0AA0000PS000001', 'production_luxury',
      231000, 215000, true, 3200, 'pleasure', 'CT');

    -- (2) submit -> AUTO_PROCEED (clean risk, CT now licensed, well above the floor).
    v_action := submit_application(v_app, 'APP-0001');
    IF v_action IS DISTINCT FROM 'AUTO_PROCEED' THEN
      RAISE EXCEPTION '0034-T4 FAILED: APP-0001 evaluated to %, expected AUTO_PROCEED', v_action;
    END IF;

    -- (3) create_quote -> the real computed premium using CT's actual factors.
    SELECT record_id INTO v_ct_record FROM state_rating_table_versions WHERE state = 'CT' AND effective_range @> now() LIMIT 1;
    v_quote := create_quote(v_app, 'retail', 10, v_ct_record, NULL, 'APP-0001');
    SELECT premium_amount INTO v_prem FROM quotes WHERE quote_id = v_quote;
    SELECT indicative_premium INTO v_exp FROM compute_indicative_premium('production_luxury', 215000, 'CT');
    IF v_prem IS DISTINCT FROM v_exp OR v_prem IS DISTINCT FROM 4179.92 THEN
      RAISE EXCEPTION '0034-T4 FAILED: APP-0001 quoted at % (function says %), expected 4179.92', v_prem, v_exp;
    END IF;

    -- (4) the ADR 0029 rating view unpacks this real quote correctly.
    SELECT rating_model, rating_class_label, agreed_value, base_rate_per_100, territory_state, territory_factor, indicative_premium
      INTO r
    FROM luxauto_quote_rating_view WHERE quote_id = v_quote;
    IF (r.rating_model, r.rating_class_label, r.agreed_value, r.base_rate_per_100, r.territory_state, r.territory_factor, r.indicative_premium)
       IS DISTINCT FROM ('indicative_premium_v1', '01 Luxury Sedan/SUV', 215000.00, 0.9200, 'CT', 1.1200, 4179.92) THEN
      RAISE EXCEPTION '0034-T4 FAILED: rating view unpack is model=%/class=%/agreed=%/rate=%/terr=%/%/prem=%',
        r.rating_model, r.rating_class_label, r.agreed_value, r.base_rate_per_100, r.territory_state, r.territory_factor, r.indicative_premium;
    END IF;

    -- (5) bind it into a real policy - the full lifecycle for the first real state.
    v_policy := bind_policy(v_quote, 'POL-CT-APP0001', 'APP-0001');
    SELECT status INTO v_status FROM policies WHERE policy_id = v_policy;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION '0034-T4 FAILED: APP-0001 policy status is %, expected active', v_status;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0034-T4 pass: APP-0001 flows end to end on CT - AUTO_PROCEED, quoted at the real 4179.92 (class 01 x 0.92 x CT 1.12 / 0.53), rating view unpacks it, bound into an active policy';
END $$;

ROLLBACK;

\echo '0034: 4/4 cases passed (nothing committed)'
