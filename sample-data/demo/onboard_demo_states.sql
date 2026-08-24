-- demo/investor-preview Step 3: onboard CA, NY, TX, FL into luxauto_demo via
-- onboard_state(). All data is CLEARLY-LABELED SYNTHETIC. Numeric/null TBDs from
-- state_rating_tables_sample.json are filled with plausible demo values.
-- Runs only against luxauto_demo. Idempotent-guarded per state.
\set ON_ERROR_STOP on

DO $$
BEGIN
  -- ---- CALIFORNIA ----
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'CA') THEN
    PERFORM onboard_state(
      'CA', 'California Department of Insurance', 'prior_approval', 'Private Passenger Auto',
      'DEMO-SYNTHETIC-CA-01',
      tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
      1.3500,
      'Illustrative PD territory factor - demo/investor-preview synthetic data, not a filed factor',
      p_rate_manual_reference := 'DEMO - illustrative onboarding, not a filed manual',
      p_expiration_or_review_date := '2027-12-31',
      p_approved_rating_variables := $json$[
        {"variable_name": "applicant.years_licensed", "permitted": true, "usage_context": ["new_business","renewal","tiering"], "notes": "Prop 103 primary factor (illustrative)."},
        {"variable_name": "vehicles[].annual_mileage", "permitted": true, "usage_context": ["new_business","renewal"], "notes": "Prop 103 primary factor (illustrative)."},
        {"variable_name": "applicant.violation_history", "permitted": true, "usage_context": ["new_business","renewal","tiering"], "notes": "Driving safety record - primary factor (illustrative)."}
      ]$json$::jsonb,
      p_prohibited_variables := $json$[
        {"variable_name": "applicant.credit_based_insurance_score_band", "citation": "Prop 103 framework (illustrative)", "notes": "Banned in CA (illustrative)."},
        {"variable_name": "gender", "citation": "CA personal-auto gender-rating prohibition (illustrative)", "notes": "Illustrative."}
      ]$json$::jsonb,
      p_credit_based_insurance_score := $json${"permitted": false, "usage_context": [], "notes": "Full ban - California (illustrative)."}$json$::jsonb,
      p_gender_rating_permitted := false,
      p_territory_rating_basis := 'DEMO - PD territory factor 1.35 loaded in territory_factors (illustrative)',
      p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": 5000, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Illustrative demo defaults."}$json$::jsonb,
      p_referral_thresholds_state_specific := $json${"dui_lookback_years": 5, "sr22_fr44_required": false, "salvage_title_disclosure_rule": "Disclosure required (illustrative)", "notes": "Illustrative demo values."}$json$::jsonb,
      p_documentation := $json${"record_id": "CA-2026-DEMO-v1", "source_urls": [], "last_verified_date": "2026-08-24", "verified_by": "Demo branch - illustrative data only, not sourced from a real filing", "note": "demo/investor-preview synthetic data."}$json$::jsonb
    );
  END IF;

  -- ---- NEW YORK ----
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'NY') THEN
    PERFORM onboard_state(
      'NY', 'New York Department of Financial Services', 'prior_approval', 'Private Passenger Auto',
      'DEMO-SYNTHETIC-NY-01',
      tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
      1.2800,
      'Illustrative PD territory factor - demo/investor-preview synthetic data, not a filed factor',
      p_rate_manual_reference := 'DEMO - illustrative onboarding, not a filed manual',
      p_expiration_or_review_date := '2027-12-31',
      p_credit_based_insurance_score := $json${"permitted": true, "usage_context": ["new_business","renewal","tiering"], "notes": "Not banned outright; any model falls under DFS AI oversight (illustrative)."}$json$::jsonb,
      p_gender_rating_permitted := NULL,
      p_territory_rating_basis := 'DEMO - PD territory factor 1.28 loaded in territory_factors (illustrative)',
      p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": 5000, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Illustrative demo defaults."}$json$::jsonb,
      p_referral_thresholds_state_specific := $json${"dui_lookback_years": 5, "sr22_fr44_required": false, "salvage_title_disclosure_rule": "Disclosure required (illustrative)", "notes": "Illustrative demo values."}$json$::jsonb,
      p_ai_governance := $json${"naic_model_bulletin_adopted": true, "naic_model_bulletin_adoption_date": "TBD - verify NAIC tracker", "state_specific_ai_law": "NY DFS Circular Letter 2024-7", "documentation_required": ["bias_testing_records","vendor_audit_rights","internal_governance_log","explainability_for_adverse_outcomes"], "citation": "NY DFS Circular Letter 2024-7 (illustrative reference)."}$json$::jsonb,
      p_documentation := $json${"record_id": "NY-2026-DEMO-v1", "source_urls": [], "last_verified_date": "2026-08-24", "verified_by": "Demo branch - illustrative data only, not sourced from a real filing", "note": "demo/investor-preview synthetic data."}$json$::jsonb
    );
  END IF;

  -- ---- TEXAS ----
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'TX') THEN
    PERFORM onboard_state(
      'TX', 'Texas Department of Insurance', 'file_and_use', 'Private Passenger Auto',
      'DEMO-SYNTHETIC-TX-01',
      tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
      1.1500,
      'Illustrative PD territory factor - demo/investor-preview synthetic data, not a filed factor',
      p_rate_manual_reference := 'DEMO - illustrative onboarding, not a filed manual',
      p_expiration_or_review_date := '2027-12-31',
      p_credit_based_insurance_score := $json${"permitted": true, "usage_context": ["new_business","renewal","tiering"], "notes": "TX permits credit-based scoring (illustrative)."}$json$::jsonb,
      p_gender_rating_permitted := true,
      p_territory_rating_basis := 'DEMO - PD territory factor 1.15 loaded in territory_factors (illustrative)',
      p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": 5000, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Illustrative demo defaults."}$json$::jsonb,
      p_referral_thresholds_state_specific := $json${"dui_lookback_years": 5, "sr22_fr44_required": true, "salvage_title_disclosure_rule": "Disclosure required (illustrative)", "notes": "Illustrative demo values."}$json$::jsonb,
      p_documentation := $json${"record_id": "TX-2026-DEMO-v1", "source_urls": [], "last_verified_date": "2026-08-24", "verified_by": "Demo branch - illustrative data only, not sourced from a real filing", "note": "demo/investor-preview synthetic data."}$json$::jsonb
    );
  END IF;

  -- ---- FLORIDA ----
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'FL') THEN
    PERFORM onboard_state(
      'FL', 'Florida Office of Insurance Regulation', 'flex_rating_band', 'Private Passenger Auto',
      'DEMO-SYNTHETIC-FL-01',
      tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
      1.4200,
      'Illustrative PD territory factor (hurricane cat load) - demo/investor-preview synthetic data, not a filed factor',
      p_rate_manual_reference := 'DEMO - illustrative onboarding, not a filed manual',
      p_expiration_or_review_date := '2027-12-31',
      p_credit_based_insurance_score := $json${"permitted": true, "usage_context": ["new_business","renewal","tiering"], "notes": "No ban identified (illustrative)."}$json$::jsonb,
      p_gender_rating_permitted := true,
      p_territory_rating_basis := 'DEMO - PD territory factor 1.42 loaded in territory_factors; FL hurricane cat structure (illustrative)',
      p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": 5000, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Illustrative demo defaults; FL PDL minimum $10,000."}$json$::jsonb,
      p_referral_thresholds_state_specific := $json${"dui_lookback_years": 5, "sr22_fr44_required": false, "salvage_title_disclosure_rule": "Disclosure required (illustrative)", "notes": "Illustrative demo values; named-storm exposure feeds cat-zone aggregate."}$json$::jsonb,
      p_documentation := $json${"record_id": "FL-2026-DEMO-v1", "source_urls": [], "last_verified_date": "2026-08-24", "verified_by": "Demo branch - illustrative data only, not sourced from a real filing", "note": "demo/investor-preview synthetic data."}$json$::jsonb
    );
  END IF;
END $$;
