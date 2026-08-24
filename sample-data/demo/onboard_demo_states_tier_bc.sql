-- demo/investor-preview 50-state expansion: Tier B + Tier C, via onboard_state()
-- only (no raw inserts). Runs against luxauto_demo only. Idempotent per state.
-- Preserves the three-tier distinction in documentation.verified_by and a
-- documentation.tier marker:
--   Tier A (CA/NY/TX/FL) - already onboarded (sample-data/demo/onboard_demo_states.sql)
--   Tier B (CO/MA/HI/MI) - onboarded from the 2026-08-08 research skeleton
--   Tier C (41 states)   - bulk-generated placeholders, no state-specific research
-- CT is the schema's own baked-in illustrative seed (present since first deploy).
\set ON_ERROR_STOP on

-- ============================================================================
-- TIER B - 4 states with researched skeletons in state_rating_tables_sample.json
-- (CO, MA, HI, MI). Same rigor/labeling as Tier A. Researched content preserved;
-- only numeric/enum TBDs filled with plausible demo values.
-- ============================================================================
DO $$
BEGIN
  -- ---- COLORADO ----
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'CO') THEN
    PERFORM onboard_state(
      'CO', 'Colorado Division of Insurance', 'file_and_use', 'Private Passenger Auto',
      'DEMO-SYNTHETIC-CO-01',
      tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
      1.1000,
      'Illustrative PD territory factor - demo/investor-preview synthetic data, not a filed factor',
      p_rate_manual_reference := 'DEMO - illustrative onboarding, not a filed manual',
      p_expiration_or_review_date := '2027-12-31',
      p_prohibited_variables := $json$[
        {"variable_name": "external_consumer_data / predictive_models (unfair discrimination risk)", "citation": "C.R.S. 10-3-1104.9 and implementing regulation", "notes": "Prohibits external consumer data sources and predictive models that result in unfair discrimination based on protected classes (from 2026-08-08 research skeleton)."}
      ]$json$::jsonb,
      p_credit_based_insurance_score := $json${"permitted": true, "usage_context": ["new_business","renewal","tiering"], "notes": "Not banned outright, but subject to the unfair-discrimination testing requirement (research skeleton)."}$json$::jsonb,
      p_gender_rating_permitted := NULL,
      p_territory_rating_basis := 'DEMO - PD territory factor 1.10 loaded in territory_factors (illustrative)',
      p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": 5000, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Illustrative demo defaults."}$json$::jsonb,
      p_referral_thresholds_state_specific := $json${"dui_lookback_years": 5, "sr22_fr44_required": false, "salvage_title_disclosure_rule": "Disclosure required (illustrative)", "notes": "Illustrative demo values."}$json$::jsonb,
      p_ai_governance := $json${"naic_model_bulletin_adopted": true, "naic_model_bulletin_adoption_date": "TBD - verify NAIC tracker", "state_specific_ai_law": "Colorado C.R.S. 10-3-1104.9", "documentation_required": ["bias_testing_records","explainability_for_adverse_outcomes"], "citation": "C.R.S. 10-3-1104.9 (2026-08-08 research skeleton)."}$json$::jsonb,
      p_documentation := $json${"record_id": "CO-2026-DEMO-v1", "tier": "B", "source_urls": [], "last_verified_date": "2026-08-24", "verified_by": "Demo branch - based on the 2026-08-08 design-session research skeleton, illustrative data only, not a filed rate"}$json$::jsonb
    );
  END IF;

  -- ---- MASSACHUSETTS ----
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'MA') THEN
    PERFORM onboard_state(
      'MA', 'Massachusetts Division of Insurance', 'prior_approval', 'Private Passenger Auto',
      'DEMO-SYNTHETIC-MA-01',
      tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
      1.2500,
      'Illustrative PD territory factor - demo/investor-preview synthetic data, not a filed factor',
      p_rate_manual_reference := 'DEMO - illustrative onboarding, not a filed manual',
      p_expiration_or_review_date := '2027-12-31',
      p_prohibited_variables := $json$[
        {"variable_name": "applicant.credit_based_insurance_score_band", "citation": "MA statute prohibiting use of credit information/credit-based insurance scores in auto insurance", "notes": "Full ban - applies to underwriting AND renewal (2026-08-08 research skeleton)."}
      ]$json$::jsonb,
      p_credit_based_insurance_score := $json${"permitted": false, "usage_context": [], "notes": "Full ban - Massachusetts (research skeleton)."}$json$::jsonb,
      p_gender_rating_permitted := NULL,
      p_territory_rating_basis := 'DEMO - PD territory factor 1.25 loaded in territory_factors (illustrative)',
      p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": 5000, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Illustrative demo defaults."}$json$::jsonb,
      p_referral_thresholds_state_specific := $json${"dui_lookback_years": 5, "sr22_fr44_required": false, "salvage_title_disclosure_rule": "Disclosure required (illustrative)", "notes": "Illustrative demo values."}$json$::jsonb,
      p_ai_governance := $json${"naic_model_bulletin_adopted": true, "naic_model_bulletin_adoption_date": "2024-12-09", "state_specific_ai_law": null, "documentation_required": ["bias_testing_records","internal_governance_log"], "citation": "MA Bulletin No. 2024-10 (2026-08-08 research skeleton)."}$json$::jsonb,
      p_documentation := $json${"record_id": "MA-2026-DEMO-v1", "tier": "B", "source_urls": [], "last_verified_date": "2026-08-24", "verified_by": "Demo branch - based on the 2026-08-08 design-session research skeleton, illustrative data only, not a filed rate"}$json$::jsonb
    );
  END IF;

  -- ---- HAWAII ----
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'HI') THEN
    PERFORM onboard_state(
      'HI', 'Hawaii Insurance Division', 'prior_approval', 'Private Passenger Auto',
      'DEMO-SYNTHETIC-HI-01',
      tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
      1.3000,
      'Illustrative PD territory factor - demo/investor-preview synthetic data, not a filed factor',
      p_rate_manual_reference := 'DEMO - illustrative onboarding, not a filed manual',
      p_expiration_or_review_date := '2027-12-31',
      p_prohibited_variables := $json$[
        {"variable_name": "applicant.credit_based_insurance_score_band", "citation": "HI statute banning credit ratings in underwriting standards and rating plans for auto insurance", "notes": "Full ban (2026-08-08 research skeleton)."}
      ]$json$::jsonb,
      p_credit_based_insurance_score := $json${"permitted": false, "usage_context": [], "notes": "Full ban - Hawaii (research skeleton)."}$json$::jsonb,
      p_gender_rating_permitted := NULL,
      p_territory_rating_basis := 'DEMO - PD territory factor 1.30 loaded in territory_factors (illustrative)',
      p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": 5000, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Illustrative demo defaults."}$json$::jsonb,
      p_referral_thresholds_state_specific := $json${"dui_lookback_years": 5, "sr22_fr44_required": false, "salvage_title_disclosure_rule": "Disclosure required (illustrative)", "notes": "Illustrative demo values."}$json$::jsonb,
      p_ai_governance := $json${"naic_model_bulletin_adopted": true, "naic_model_bulletin_adoption_date": "2025-12-10", "state_specific_ai_law": null, "documentation_required": ["bias_testing_records"], "citation": "HI Insurance Commissioner Memorandum No. 2025-13A (2026-08-08 research skeleton)."}$json$::jsonb,
      p_documentation := $json${"record_id": "HI-2026-DEMO-v1", "tier": "B", "source_urls": [], "last_verified_date": "2026-08-24", "verified_by": "Demo branch - based on the 2026-08-08 design-session research skeleton, illustrative data only, not a filed rate"}$json$::jsonb
    );
  END IF;

  -- ---- MICHIGAN ----
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'MI') THEN
    PERFORM onboard_state(
      'MI', 'Michigan Department of Insurance and Financial Services', 'file_and_use', 'Private Passenger Auto',
      'DEMO-SYNTHETIC-MI-01',
      tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
      1.5500,
      'Illustrative PD territory factor - demo/investor-preview synthetic data, not a filed factor',
      p_rate_manual_reference := 'DEMO - illustrative onboarding, not a filed manual',
      p_expiration_or_review_date := '2027-12-31',
      p_state_specific_application_fields := $json$[
        {"field_name": "pip_medical_coverage_level", "required": true, "description": "MI no-fault reform (2020) PIP medical coverage level selection (research skeleton)."},
        {"field_name": "pip_medicare_coordination", "required": true, "description": "MI PIP Medicare coordination-of-benefits factor (research skeleton)."},
        {"field_name": "pip_work_loss_benefits_selected", "required": false, "description": "Optional MI PIP add-on (research skeleton)."}
      ]$json$::jsonb,
      p_prohibited_variables := $json$[
        {"variable_name": "applicant.credit_based_insurance_score_band", "citation": "MI no-fault reform (2020) eliminated credit scoring as an auto rating factor", "notes": "Full ban, part of MI's 2020 no-fault reform (2026-08-08 research skeleton)."}
      ]$json$::jsonb,
      p_credit_based_insurance_score := $json${"permitted": false, "usage_context": [], "notes": "Full ban - Michigan (research skeleton)."}$json$::jsonb,
      p_gender_rating_permitted := NULL,
      p_territory_rating_basis := 'DEMO - PD territory factor 1.55 loaded in territory_factors (illustrative)',
      p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": 5000, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Illustrative demo defaults."}$json$::jsonb,
      p_referral_thresholds_state_specific := $json${"dui_lookback_years": 5, "sr22_fr44_required": false, "salvage_title_disclosure_rule": "Disclosure required (illustrative)", "notes": "MI no-fault PIP fields captured in state_specific_application_fields (research skeleton)."}$json$::jsonb,
      p_ai_governance := $json${"naic_model_bulletin_adopted": null, "naic_model_bulletin_adoption_date": null, "state_specific_ai_law": null, "documentation_required": [], "citation": "TBD - verify current MI status against the NAIC adoption tracker (2026-08-08 research skeleton)."}$json$::jsonb,
      p_documentation := $json${"record_id": "MI-2026-DEMO-v1", "tier": "B", "source_urls": [], "last_verified_date": "2026-08-24", "verified_by": "Demo branch - based on the 2026-08-08 design-session research skeleton, illustrative data only, not a filed rate"}$json$::jsonb
    );
  END IF;
END $$;

-- ============================================================================
-- TIER C - the remaining 41 states, bulk-generated placeholders. No state-
-- specific research. Standard defaults (file_and_use, credit permitted, gender
-- unspecified). Formulaic-but-varied PD territory factors. Looped over the code
-- array; each guarded so a re-run is a no-op.
-- ============================================================================
DO $$
DECLARE
  v_codes CHAR(2)[] := ARRAY[
    'AL','AK','AZ','AR','DE','GA','ID','IL','IN','IA','KS','KY','LA','ME','MD',
    'MN','MS','MO','MT','NE','NV','NH','NJ','NM','NC','ND','OH','OK','OR','PA',
    'RI','SC','SD','TN','UT','VT','VA','WA','WV','WI','WY'];
  v_code CHAR(2);
  v_idx INT := 0;
  v_factor NUMERIC;
BEGIN
  FOREACH v_code IN ARRAY v_codes LOOP
    v_idx := v_idx + 1;
    -- Varied but deterministic spread across ~0.90..1.39; not all identical.
    v_factor := ROUND(0.9000 + ((v_idx * 37) % 50) * 0.01, 4);

    IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = v_code) THEN
      PERFORM onboard_state(
        v_code, v_code || ' Department of Insurance', 'file_and_use', 'Private Passenger Auto',
        'DEMO-SYNTHETIC-' || v_code || '-01',
        tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
        v_factor,
        'Bulk-generated illustrative PD territory factor - demo/investor-preview, no state-specific research, not a filed factor',
        p_rate_manual_reference := 'DEMO - bulk-generated placeholder, not a filed manual',
        p_expiration_or_review_date := '2027-12-31',
        p_credit_based_insurance_score := $json${"permitted": true, "usage_context": ["new_business","renewal","tiering"], "notes": "Standard placeholder default (credit permitted); no state-specific research performed."}$json$::jsonb,
        p_gender_rating_permitted := NULL,
        p_territory_rating_basis := 'DEMO - bulk-generated placeholder PD territory factor loaded in territory_factors (illustrative)',
        p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": 5000, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Standard placeholder defaults; no state-specific research."}$json$::jsonb,
        p_referral_thresholds_state_specific := $json${"dui_lookback_years": 5, "sr22_fr44_required": false, "salvage_title_disclosure_rule": "TBD", "notes": "Standard placeholder defaults; no state-specific research."}$json$::jsonb,
        p_documentation := jsonb_build_object(
          'record_id', v_code || '-2026-DEMO-v1',
          'tier', 'C',
          'source_urls', '[]'::jsonb,
          'last_verified_date', '2026-08-24',
          'verified_by', 'Demo branch - bulk-generated illustrative placeholder for 50-state demo breadth, no state-specific research performed, not a filed rate')
      );
    END IF;
  END LOOP;
END $$;
