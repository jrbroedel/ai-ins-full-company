-- demo/investor-preview Step 4: seed the four luxury_auto_sample_applications
-- profiles into luxauto_demo, each re-homed into one of the four onboarded demo
-- states (CA, NY, TX, FL) with a real city/ZIP, then submitted through the
-- normal submit_application() path so each moves through the referral matrix.
-- Persistent (committed). Idempotent by applicant email.
\set ON_ERROR_STOP on

-- ---- Profile 1: Miriam Ostrander -> NEW YORK (clean risk) ----
DO $$
DECLARE v_app UUID; v_appl UUID; v_action referral_action_t;
BEGIN
  IF EXISTS (SELECT 1 FROM applicants WHERE email = 'm.ostrander@example.com') THEN
    RAISE NOTICE 'Profile 1 (NY) already seeded - skipping'; RETURN;
  END IF;
  INSERT INTO applicants (first_name, last_name, date_of_birth, ssn_last4, email, phone,
    mailing_street, mailing_city, mailing_state, mailing_zip, occupation, years_licensed,
    license_number_state, license_status, credit_based_insurance_score_band)
  VALUES ('Miriam','Ostrander','1971-03-14','0000','m.ostrander@example.com','555-010-0001',
    '784 Park Avenue','New York','NY','10021','Orthopedic Surgeon',32,'NY','valid','excellent')
  RETURNING applicant_id INTO v_appl;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_appl,'draft','NY') RETURNING application_id INTO v_app;

  INSERT INTO vehicles (application_id, year, make, model, trim, vin, vehicle_category,
    purchase_price, current_appraised_value, appraisal_date, appraisal_source, agreed_value_requested,
    annual_mileage, primary_use, garaging_street, garaging_city, garaging_state, garaging_zip,
    garage_type, security_features, existing_liens)
  VALUES (v_app,2023,'Porsche','911','Turbo S','WP0AA0000PS000001','production_luxury',
    231000,215000,'2026-05-01','Manufacturer dealer invoice + independent appraiser',true,
    3200,'pleasure','784 Park Avenue','New York','NY','10021','attached_locked',
    ARRAY['alarm','GPS_tracker','immobilizer'],false);

  INSERT INTO coverage_requested (application_id, liability_bodily_injury_limits, liability_property_damage_limit,
    uninsured_underinsured_motorist, comprehensive_deductible, collision_deductible, agreed_value_endorsement,
    spare_parts_coverage, roadside_transport_flatbed_only, umbrella_policy_requested, umbrella_limit)
  VALUES (v_app,'500/500',500000,true,1000,1000,true,false,true,true,5000000);

  INSERT INTO prior_insurance (application_id, current_carrier, years_with_current_carrier,
    current_policy_expiration, reason_for_shopping, any_nonrenewal_or_cancellation_history, cancellation_reason)
  VALUES (v_app,'Chubb',9,'2026-09-15','Comparing rates at renewal',false,NULL);

  v_action := submit_application(v_app, 'demo/investor-preview seed');
  RAISE NOTICE 'Profile 1 Ostrander (NY) app % -> %', v_app, v_action;
END $$;

-- ---- Profile 2: Trevor Bianchi -> FLORIDA (moderate risk) ----
DO $$
DECLARE v_app UUID; v_appl UUID; v_action referral_action_t;
BEGIN
  IF EXISTS (SELECT 1 FROM applicants WHERE email = 't.bianchi@example.com') THEN
    RAISE NOTICE 'Profile 2 (FL) already seeded - skipping'; RETURN;
  END IF;
  INSERT INTO applicants (first_name, last_name, date_of_birth, ssn_last4, email, phone,
    mailing_street, mailing_city, mailing_state, mailing_zip, occupation, years_licensed,
    license_number_state, license_status, credit_based_insurance_score_band)
  VALUES ('Trevor','Bianchi','2001-11-02','0000','t.bianchi@example.com','555-010-0002',
    '1100 West Ave','Miami Beach','FL','33139','Real Estate Agent',6,'FL','valid','fair')
  RETURNING applicant_id INTO v_appl;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_appl,'draft','FL') RETURNING application_id INTO v_app;

  INSERT INTO vehicles (application_id, year, make, model, trim, vin, vehicle_category,
    purchase_price, current_appraised_value, appraisal_date, appraisal_source, agreed_value_requested,
    annual_mileage, primary_use, garaging_street, garaging_city, garaging_state, garaging_zip,
    garage_type, security_features, modifications, existing_liens, lienholder_name)
  VALUES (v_app,2022,'Nissan','GT-R','Nismo','JN1AR000000000002','modified_performance',
    145000,132000,'2026-04-10','Independent appraiser',true,
    9500,'pleasure','1100 West Ave','Miami Beach','FL','33139','gated_community',
    ARRAY['alarm','GPS_tracker'],'Aftermarket turbo upgrade, ECU tune, exhaust system',true,'Coastal Auto Finance');

  INSERT INTO coverage_requested (application_id, liability_bodily_injury_limits, liability_property_damage_limit,
    uninsured_underinsured_motorist, comprehensive_deductible, collision_deductible, agreed_value_endorsement,
    spare_parts_coverage, roadside_transport_flatbed_only, umbrella_policy_requested, umbrella_limit)
  VALUES (v_app,'250/500',250000,true,2500,2500,true,true,true,false,NULL);

  INSERT INTO claims_history (application_id, claim_date, claim_type, at_fault, paid_amount, description) VALUES
    (v_app,'2025-02-11','collision',true,18400,'Single-vehicle accident, lost control on wet road'),
    (v_app,'2024-06-30','liability',true,6200,'Rear-ended another vehicle at a stoplight');

  INSERT INTO prior_insurance (application_id, current_carrier, years_with_current_carrier,
    current_policy_expiration, reason_for_shopping, any_nonrenewal_or_cancellation_history, cancellation_reason)
  VALUES (v_app,'Progressive',1,'2026-08-30','Non-renewed by prior carrier due to modifications',true,
    'Carrier does not cover aftermarket performance modifications');

  v_action := submit_application(v_app, 'demo/investor-preview seed');
  RAISE NOTICE 'Profile 2 Bianchi (FL) app % -> %', v_app, v_action;
END $$;

-- ---- Profile 3: Dale Kirkwood -> TEXAS (high risk) ----
DO $$
DECLARE v_app UUID; v_appl UUID; v_drv UUID; v_action referral_action_t;
BEGIN
  IF EXISTS (SELECT 1 FROM applicants WHERE email = 'd.kirkwood@example.com') THEN
    RAISE NOTICE 'Profile 3 (TX) already seeded - skipping'; RETURN;
  END IF;
  INSERT INTO applicants (first_name, last_name, date_of_birth, ssn_last4, email, phone,
    mailing_street, mailing_city, mailing_state, mailing_zip, occupation, years_licensed,
    license_number_state, license_status, credit_based_insurance_score_band)
  VALUES ('Dale','Kirkwood','1988-07-19','0000','d.kirkwood@example.com','555-010-0003',
    '3200 Kirby Dr','Houston','TX','77098','Contractor',18,'TX','valid','poor')
  RETURNING applicant_id INTO v_appl;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_appl,'draft','TX') RETURNING application_id INTO v_app;

  INSERT INTO vehicles (application_id, year, make, model, trim, vin, vehicle_category,
    purchase_price, current_appraised_value, appraisal_date, appraisal_source, agreed_value_requested,
    annual_mileage, primary_use, garaging_street, garaging_city, garaging_state, garaging_zip,
    garage_type, security_features, existing_liens, lienholder_name)
  VALUES (v_app,2021,'Mercedes-Benz','AMG GT','63 S','WDD1J00000A000003','production_luxury',
    168000,121000,'2026-03-22','Applicant-provided estimate (no independent appraisal on file)',false,
    14200,'commute','3200 Kirby Dr','Houston','TX','77098','unsecured_street',
    ARRAY[]::TEXT[],true,'Desert Ridge Credit Union');

  INSERT INTO additional_drivers (application_id, name, relationship_to_applicant, date_of_birth,
    years_licensed, license_status, violations_last_5yr, at_fault_accidents_last_5yr)
  VALUES (v_app,'Casey Kirkwood','Spouse','1990-01-05',15,'suspended',3,1)
  RETURNING driver_id INTO v_drv;
  INSERT INTO additional_driver_sanctions (driver_id, sanctions_screen_result) VALUES (v_drv,'clear');

  INSERT INTO coverage_requested (application_id, liability_bodily_injury_limits, liability_property_damage_limit,
    uninsured_underinsured_motorist, comprehensive_deductible, collision_deductible, agreed_value_endorsement,
    spare_parts_coverage, roadside_transport_flatbed_only, umbrella_policy_requested, umbrella_limit)
  VALUES (v_app,'100/300',100000,false,500,500,false,false,false,false,NULL);

  INSERT INTO claims_history (application_id, claim_date, claim_type, at_fault, paid_amount, description) VALUES
    (v_app,'2025-09-02','collision',true,24700,'Multi-vehicle collision at intersection'),
    (v_app,'2024-12-14','theft',false,9800,'Catalytic converter theft while parked on street'),
    (v_app,'2023-05-08','collision',true,15300,'Backed into parked vehicle in commercial lot');

  INSERT INTO prior_insurance (application_id, current_carrier, years_with_current_carrier,
    current_policy_expiration, reason_for_shopping, any_nonrenewal_or_cancellation_history, cancellation_reason)
  VALUES (v_app,'State-assigned risk pool',1,'2026-07-01','Seeking standard market coverage after high-risk pool placement',
    true,'Multiple at-fault claims; non-renewed by two prior carriers');

  v_action := submit_application(v_app, 'demo/investor-preview seed');
  RAISE NOTICE 'Profile 3 Kirkwood (TX) app % -> %', v_app, v_action;
END $$;

-- ---- Profile 4: Priya Nandakumar -> CALIFORNIA (edge case, high value) ----
DO $$
DECLARE v_app UUID; v_appl UUID; v_action referral_action_t;
BEGIN
  IF EXISTS (SELECT 1 FROM applicants WHERE email = 'p.nandakumar@example.com') THEN
    RAISE NOTICE 'Profile 4 (CA) already seeded - skipping'; RETURN;
  END IF;
  INSERT INTO applicants (first_name, last_name, date_of_birth, ssn_last4, email, phone,
    mailing_street, mailing_city, mailing_state, mailing_zip, occupation, years_licensed,
    license_number_state, license_status, credit_based_insurance_score_band)
  VALUES ('Priya','Nandakumar','1965-09-27','0000','p.nandakumar@example.com','555-010-0004',
    '1600 Atlas Peak Rd','Napa','CA','94558','Retired Executive',44,'CA','valid','excellent')
  RETURNING applicant_id INTO v_appl;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_appl,'draft','CA') RETURNING application_id INTO v_app;

  INSERT INTO vehicles (application_id, year, make, model, trim, vin, vehicle_category,
    purchase_price, current_appraised_value, appraisal_date, appraisal_source, agreed_value_requested,
    annual_mileage, primary_use, garaging_street, garaging_city, garaging_state, garaging_zip,
    garage_type, security_features, existing_liens)
  VALUES (v_app,1967,'Ferrari','275 GTB/4','N/A','FER67500000000004','classic_collector',
    3200000,3850000,'2026-01-15','Certified classic car appraiser (specialty firm)',true,
    400,'show_display','1600 Atlas Peak Rd','Napa','CA','94558','climate_controlled_storage',
    ARRAY['alarm','GPS_tracker','dash_cam'],false);

  INSERT INTO coverage_requested (application_id, liability_bodily_injury_limits, liability_property_damage_limit,
    uninsured_underinsured_motorist, comprehensive_deductible, collision_deductible, agreed_value_endorsement,
    spare_parts_coverage, roadside_transport_flatbed_only, umbrella_policy_requested, umbrella_limit)
  VALUES (v_app,'500/500',500000,true,5000,5000,true,true,true,true,10000000);

  INSERT INTO prior_insurance (application_id, current_carrier, years_with_current_carrier,
    current_policy_expiration, reason_for_shopping, any_nonrenewal_or_cancellation_history, cancellation_reason)
  VALUES (v_app,'Hagerty',12,'2026-10-01','Adding vehicle to broader HNW portfolio policy',false,NULL);

  v_action := submit_application(v_app, 'demo/investor-preview seed');
  RAISE NOTICE 'Profile 4 Nandakumar (CA) app % -> %', v_app, v_action;
END $$;
