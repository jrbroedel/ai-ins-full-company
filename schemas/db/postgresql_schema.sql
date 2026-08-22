-- ============================================================================
-- Luxury Auto MGA - PostgreSQL schema
-- Target: Azure Database for PostgreSQL (Flexible Server), per ADR 0002
-- Implements: schemas/luxury_auto_application_schema.json v1.1
--             schemas/state_rating_table_schema.json v1.1
--             referral-matrices/luxury_auto_referral_matrix.json v1.1
-- See docs/decisions/0005-database-table-design.md for rationale.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- required for the state-rating-table
                                             -- exclusion constraint below

-- ============================================================================
-- ENUM TYPES
-- Mirror the enum[...] fields in the JSON schemas exactly. If a schema enum
-- changes, this file changes with it - these are not meant to drift apart.
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE license_status_t AS ENUM ('valid', 'suspended', 'revoked', 'expired');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE credit_score_band_t AS ENUM ('excellent', 'good', 'fair', 'poor', 'not_available');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE vehicle_category_t AS ENUM ('production_luxury', 'exotic', 'classic_collector', 'modified_performance',
                                          'pre_war_vintage', 'restomod_coachbuilt');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
-- ADR 0027: two categories (pre-war/vintage, restomod/coachbuilt) added to an
-- enum that already exists on live. On a fresh apply the CREATE TYPE above
-- carries all six; on an existing database the CREATE TYPE raises
-- duplicate_object (caught) and the two values arrive by ALTER instead.
-- ALTER TYPE ... ADD VALUE IF NOT EXISTS is idempotent, and because this file is
-- applied with psql autocommitting each statement (no wrapping BEGIN), it commits
-- immediately - so the PostgreSQL rule that a new enum value cannot be USED in
-- the same transaction that added it never bites here (nothing in this file uses
-- the values; data does, in later, separate transactions). Appended at the end,
-- so the existing four keep their sort order. NOTE: this is record-and-validate
-- only - no rating/pricing logic exists for these two yet (ADR 0027).
ALTER TYPE vehicle_category_t ADD VALUE IF NOT EXISTS 'pre_war_vintage';
ALTER TYPE vehicle_category_t ADD VALUE IF NOT EXISTS 'restomod_coachbuilt';
DO $$ BEGIN
  CREATE TYPE primary_use_t AS ENUM ('pleasure', 'commute', 'business', 'show_display');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE garage_type_t AS ENUM ('attached_locked', 'detached_locked', 'gated_community', 'unsecured_street', 'climate_controlled_storage');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE claim_type_t AS ENUM ('collision', 'comprehensive', 'liability', 'glass', 'theft');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE violation_type_t AS ENUM ('DUI', 'reckless_driving', 'speeding', 'other_moving_violation');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE sanctions_result_t AS ENUM ('clear', 'positive_hit', 'pending');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE title_status_t AS ENUM ('clean', 'salvage', 'rebuilt', 'flood', 'lemon_law_buyback');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE filing_status_t AS ENUM ('prior_approval', 'file_and_use', 'use_and_file', 'flex_rating_band', 'competitive_no_file');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE referral_action_t AS ENUM (
    'AUTO_PROCEED', 'AUTO_PROCEED_WITH_FLAG', 'INFORMATION_REQUEST',
    'MANUAL_REVIEW_REQUIRED', 'MANUAL_REVIEW_SENIOR',
    'DECLINE_RECOMMENDED', 'HARD_DECLINE_COMPLIANCE'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE application_status_t AS ENUM (
    'draft', 'submitted', 'information_requested', 'in_review',
    'quoted', 'bound', 'declined', 'withdrawn'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE document_type_t AS ENUM (
    'appraisal', 'loss_run', 'engineering_report', 'rendered_quote_pdf',
    'application_form', 'title_report', 'mvr_report', 'other'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE policy_status_t AS ENUM ('active', 'cancelled', 'expired', 'nonrenewed');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE endorsement_type_t AS ENUM ('premium_adjustment', 'term_change');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
-- ADR 0007 addendum: the single broker channel a placement is written through.
-- One column of this type holds exactly one value, so a dual retail+wholesale
-- placement is structurally unrepresentable - the enforcement of the confirmed
-- "either retail or wholesale, never both" rule is the data model itself.
DO $$ BEGIN
  CREATE TYPE broker_channel_t AS ENUM ('retail', 'wholesale');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- ============================================================================
-- STATE RATING TABLE REGISTRY
-- Implements state_rating_table_schema.json. This is compliance boundary
-- infrastructure, not configuration - see that schema's own header comment.
-- ============================================================================

CREATE TABLE IF NOT EXISTS state_rating_table_versions (
  record_id                       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  state                           CHAR(2) NOT NULL,
  regulator_name                  TEXT NOT NULL,
  filing_status                   filing_status_t NOT NULL,
  line_of_business_code           TEXT NOT NULL,
  serff_filing_tracking_number    TEXT NOT NULL,  -- 'never leave null in production' per schema
  rate_manual_reference           TEXT,
  effective_range                 TSTZRANGE NOT NULL,  -- lower bound = effective_date;
                                                          -- upper bound set when superseded
  superseded_by                   UUID REFERENCES state_rating_table_versions(record_id),
  expiration_or_review_date       DATE,

  approved_rating_variables       JSONB NOT NULL DEFAULT '[]',
  prohibited_variables            JSONB NOT NULL DEFAULT '[]',
  state_specific_application_fields JSONB NOT NULL DEFAULT '[]',
  credit_based_insurance_score    JSONB NOT NULL DEFAULT '{}',
  gender_rating_permitted         BOOLEAN,
  territory_rating_basis          TEXT,
  agreed_value_rules              JSONB NOT NULL DEFAULT '{}',
  referral_thresholds_state_specific JSONB NOT NULL DEFAULT '{}',
  ai_governance                   JSONB NOT NULL DEFAULT '{}',
  documentation                   JSONB NOT NULL DEFAULT '{}',

  created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- The whole point of this table: two versions for the same state can never
  -- have overlapping active periods. The database enforces this, not
  -- application logic that could silently break. This is the range-type /
  -- exclusion-constraint mechanism referenced in ADR 0001's rationale.
  CONSTRAINT no_overlapping_state_versions
    EXCLUDE USING gist (state WITH =, effective_range WITH &&)
);

CREATE INDEX IF NOT EXISTS idx_state_rating_state ON state_rating_table_versions(state);

COMMENT ON TABLE state_rating_table_versions IS
  'One row per state per effective-date version. rate quotes must pin to a specific record_id (see quotes.state_rating_table_record_id) so a later rate change never silently re-rates an in-flight quote.';
COMMENT ON COLUMN state_rating_table_versions.approved_rating_variables IS
  'Array of {variable_name, permitted, usage_context, notes}. Rating engine must reject any variable not in this list for the applicable state - see referral rule CP-03.';

-- ============================================================================
-- APPLICANTS
-- Normalized separately from applications: one applicant may have multiple
-- applications over time (renewals, additional vehicles).
-- ============================================================================

CREATE TABLE IF NOT EXISTS applicants (
  applicant_id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  first_name                      TEXT NOT NULL,
  last_name                       TEXT NOT NULL,
  date_of_birth                   DATE,
  ssn_last4                       CHAR(4),
  email                           TEXT,
  phone                           TEXT,
  mailing_street                  TEXT,
  mailing_city                    TEXT,
  mailing_state                   CHAR(2),
  mailing_zip                     TEXT,
  occupation                      TEXT,
  years_licensed                  SMALLINT,
  license_number_state            CHAR(2),
  license_status                  license_status_t,
  credit_based_insurance_score_band credit_score_band_t,
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- APPLICATIONS
-- The central record. state_specific_extensions is a JSONB namespace matching
-- the application schema's mechanism exactly (see ADR re: state-specific
-- attributes) - no per-state migrations needed.
-- ============================================================================

CREATE TABLE IF NOT EXISTS applications (
  application_id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  applicant_id                    UUID NOT NULL REFERENCES applicants(applicant_id),
  status                          application_status_t NOT NULL DEFAULT 'draft',
  garaging_state                  CHAR(2) NOT NULL,  -- drives which state_rating_table_versions
                                                        -- record applies - keyed off the vehicle's
                                                        -- garaging state, not the applicant's mailing
                                                        -- address, per the registry's own design note
  state_specific_extensions       JSONB NOT NULL DEFAULT '{}',
  submitted_at                    TIMESTAMPTZ,
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_applications_applicant ON applications(applicant_id);
CREATE INDEX IF NOT EXISTS idx_applications_garaging_state ON applications(garaging_state);
CREATE INDEX IF NOT EXISTS idx_applications_status ON applications(status);

COMMENT ON COLUMN applications.state_specific_extensions IS
  'Namespace for per-state supplemental fields (e.g. MI PIP tiers). What belongs here is driven by state_rating_table_versions.state_specific_application_fields for this application''s garaging_state, not hardcoded - see application schema v1.1 changelog.';

-- ============================================================================
-- ADDITIONAL DRIVERS
-- ============================================================================

CREATE TABLE IF NOT EXISTS additional_drivers (
  driver_id                       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                  UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  name                             TEXT NOT NULL,
  relationship_to_applicant       TEXT,
  date_of_birth                   DATE,
  years_licensed                  SMALLINT,
  license_status                  license_status_t,
  violations_last_5yr             SMALLINT,
  at_fault_accidents_last_5yr     SMALLINT
);

CREATE INDEX IF NOT EXISTS idx_additional_drivers_application ON additional_drivers(application_id);

-- ============================================================================
-- VEHICLES
-- ============================================================================

CREATE TABLE IF NOT EXISTS vehicles (
  vehicle_id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                  UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  year                             SMALLINT NOT NULL,
  make                             TEXT NOT NULL,
  model                            TEXT NOT NULL,
  trim                             TEXT,
  vin                              TEXT,
  vehicle_category                 vehicle_category_t NOT NULL,
  purchase_price                  NUMERIC(12,2),
  current_appraised_value         NUMERIC(12,2),
  appraisal_date                  DATE,
  appraisal_source                TEXT,
  agreed_value_requested          BOOLEAN NOT NULL DEFAULT false,
  annual_mileage                  INTEGER,
  primary_use                     primary_use_t,
  garaging_street                 TEXT,
  garaging_city                   TEXT,
  garaging_state                  CHAR(2) NOT NULL,
  garaging_zip                    TEXT,
  garage_type                     garage_type_t,
  security_features               TEXT[] NOT NULL DEFAULT '{}',  -- app-layer validated against
                                                                    -- {alarm, GPS_tracker, steering_lock,
                                                                    -- dash_cam, immobilizer}
  modifications                   TEXT,
  existing_liens                  BOOLEAN,
  lienholder_name                 TEXT
);

CREATE INDEX IF NOT EXISTS idx_vehicles_application ON vehicles(application_id);
CREATE INDEX IF NOT EXISTS idx_vehicles_vin ON vehicles(vin);

-- ============================================================================
-- COVERAGE REQUESTED / PRIOR INSURANCE
-- 1:1 with applications - split out for clarity, not normalization purity.
-- ============================================================================

CREATE TABLE IF NOT EXISTS coverage_requested (
  application_id                   UUID PRIMARY KEY REFERENCES applications(application_id) ON DELETE CASCADE,
  liability_bodily_injury_limits   TEXT,
  liability_property_damage_limit  NUMERIC(12,2),
  uninsured_underinsured_motorist  BOOLEAN,
  comprehensive_deductible        NUMERIC(10,2),
  collision_deductible            NUMERIC(10,2),
  agreed_value_endorsement        BOOLEAN,
  spare_parts_coverage             BOOLEAN,
  roadside_transport_flatbed_only  BOOLEAN,
  umbrella_policy_requested       BOOLEAN,
  umbrella_limit                   NUMERIC(12,2)
);

CREATE TABLE IF NOT EXISTS prior_insurance (
  application_id                   UUID PRIMARY KEY REFERENCES applications(application_id) ON DELETE CASCADE,
  current_carrier                  TEXT,
  years_with_current_carrier      SMALLINT,
  current_policy_expiration       DATE,
  reason_for_shopping              TEXT,
  any_nonrenewal_or_cancellation_history BOOLEAN,
  cancellation_reason              TEXT
);

CREATE TABLE IF NOT EXISTS claims_history (
  claim_id                         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                   UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  claim_date                       DATE NOT NULL,
  claim_type                       claim_type_t NOT NULL,
  at_fault                         BOOLEAN NOT NULL,
  paid_amount                      NUMERIC(12,2),
  description                      TEXT
);

CREATE INDEX IF NOT EXISTS idx_claims_application ON claims_history(application_id);

-- ============================================================================
-- ENRICHMENT (populated by the pipeline post-intake, pre-referral - implements
-- application schema v1.1's enrichment_computed section)
-- ============================================================================

CREATE TABLE IF NOT EXISTS applicant_enrichment (
  application_id                   UUID PRIMARY KEY REFERENCES applications(application_id) ON DELETE CASCADE,
  sanctions_screen_result          sanctions_result_t NOT NULL DEFAULT 'pending',
  household_unlisted_resident_found BOOLEAN NOT NULL DEFAULT false,
  household_relationship_guess     TEXT,
  household_notes                  TEXT,
  enriched_at                      TIMESTAMPTZ
);

-- Unified violation history for both the applicant and additional drivers -
-- subject_driver_id NULL means "the applicant"; otherwise references a
-- specific additional_drivers row. Avoids two near-identical tables.
CREATE TABLE IF NOT EXISTS person_violations (
  violation_id                     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                   UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  subject_driver_id                UUID REFERENCES additional_drivers(driver_id),  -- NULL = applicant
  violation_date                   DATE NOT NULL,
  violation_type                   violation_type_t NOT NULL,
  conviction                       BOOLEAN NOT NULL,
  bac_level                        NUMERIC(4,3),  -- DUI only
  source                           TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_person_violations_application ON person_violations(application_id);

CREATE TABLE IF NOT EXISTS additional_driver_sanctions (
  driver_id                        UUID PRIMARY KEY REFERENCES additional_drivers(driver_id) ON DELETE CASCADE,
  sanctions_screen_result          sanctions_result_t NOT NULL DEFAULT 'pending'
);

CREATE TABLE IF NOT EXISTS vehicle_enrichment (
  vehicle_id                       UUID PRIMARY KEY REFERENCES vehicles(vehicle_id) ON DELETE CASCADE,
  decoded_make                     TEXT,
  decoded_model                    TEXT,
  decoded_year                     SMALLINT,
  decoded_trim                     TEXT,
  vin_matches_declared             BOOLEAN,
  vin_discrepancy_notes            TEXT,
  title_status                     title_status_t,
  title_disclosed_by_applicant     BOOLEAN,
  title_source                     TEXT,
  enriched_at                      TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS producer_verification (
  application_id                   UUID PRIMARY KEY REFERENCES applications(application_id) ON DELETE CASCADE,
  verified                         BOOLEAN NOT NULL DEFAULT false,
  license_status                   TEXT,
  toba_executed                    BOOLEAN NOT NULL DEFAULT false,
  notes                            TEXT
);

-- ============================================================================
-- UNDERWRITING FLAGS (pipeline output)
-- ============================================================================

CREATE TABLE IF NOT EXISTS underwriting_flags (
  application_id                   UUID PRIMARY KEY REFERENCES applications(application_id) ON DELETE CASCADE,
  risk_score                       NUMERIC(6,2),
  vehicle_theft_risk_index         NUMERIC(6,2),
  driver_risk_index                NUMERIC(6,2),
  referral_required                BOOLEAN NOT NULL DEFAULT false,
  referral_reason                  TEXT,
  computed_at                      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- DECISION LOG (append-only)
-- This is the table the NY DFS Circular Letter 2024-7 / Colorado C.R.S.
-- 10-3-1104.9 documentation requirements are built from. Every referral
-- matrix rule evaluation gets a row here, whether or not it fired, per
-- the referral matrix's own "how_this_is_used" item 4: "Every rule that
-- fires must write a reason_code to the application's decision log,
-- unredacted, even if the ultimate outcome is 'proceed.'"
-- ============================================================================

CREATE TABLE IF NOT EXISTS decision_log (
  log_id                            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                    UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  rule_id                           TEXT NOT NULL,           -- e.g. 'DH-01', matches
                                                                -- referral matrix rule_id
  reason_code                       TEXT NOT NULL,            -- e.g. 'DH01_DUI_WITHIN_LOOKBACK'
  action_taken                      referral_action_t NOT NULL,
  fired                             BOOLEAN NOT NULL,          -- did the rule's trigger condition
                                                                -- actually match, or is this a
                                                                -- non-firing audit row
  decided_by                        TEXT NOT NULL,             -- 'system' or a specific underwriter
                                                                -- user identifier
  notes                             TEXT,
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_decision_log_application ON decision_log(application_id);
CREATE INDEX IF NOT EXISTS idx_decision_log_rule ON decision_log(rule_id);

-- Enforce append-only at the database level: no UPDATE, no DELETE, ever.
-- A logging mistake gets corrected with a new row referencing the old one
-- in `notes`, not by editing history - the same discipline the Energy
-- manual requires for declination reason codes (Chapter 3).
CREATE OR REPLACE FUNCTION reject_decision_log_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'decision_log is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER decision_log_no_update
  BEFORE UPDATE ON decision_log
  FOR EACH ROW EXECUTE FUNCTION reject_decision_log_mutation();

CREATE OR REPLACE TRIGGER decision_log_no_delete
  BEFORE DELETE ON decision_log
  FOR EACH ROW EXECUTE FUNCTION reject_decision_log_mutation();

-- ============================================================================
-- REFERRAL ENGINE (ADR 0026)
-- The first referral-matrix evaluation logic. The data model it reads
-- (applications, vehicles, claims_history, person_violations,
-- state_rating_table_versions), the append-only decision_log it writes, and the
-- referral_action_t taxonomy all already exist (ADR 0005); only the evaluation
-- was missing.
--
-- Scope: exactly the four confirmed-and-queued rules AL-01, CP-02, DH-01, PC-03.
-- The other 11 rules in luxury_auto_referral_matrix.json (VV-01..04, DH-02..04,
-- AL-02, CP-01/CP-03, PC-01/02/04) are OUT OF SCOPE for this ADR and are future
-- work - each will be its own evaluate_<rule>() called from the orchestrator.
--
-- Shape (per the design proposal): one small function per rule, each writing
-- exactly one decision_log row (fired or not, reason_code always set - the
-- unredacted-audit requirement in decision_log's own comment), plus a thin
-- orchestrator that composes them and returns the most-severe action. Small
-- purpose-built functions over a monolith, the same idiom as reinstate_policy /
-- link_reinstated_policy / cancel_policy.
--
-- p_decided_by defaults to 'system' so each rule is callable as evaluate_xx(id)
-- while still satisfying decision_log.decided_by (NOT NULL); the pipeline or an
-- underwriter can override it.
--
-- Two documented assumptions, both confirmed for build:
--  * "agreed value" == current_appraised_value throughout (there is no distinct
--    agreed-value dollar column today; AL-01 severity and CP-02 both use it).
--  * AL-01's per-claim denominator is MAX(current_appraised_value) across the
--    application's vehicles (claims_history has no vehicle link).
-- ============================================================================

-- AL-01: adverse loss history. 2+ at-fault claims in the 5 years before the
-- application date, OR any single claim whose paid_amount is >= 30% of the
-- priciest vehicle's appraised value. Claims with a NULL paid_amount are skipped
-- in the severity limb (nothing to compare) but still counted in the frequency
-- limb if at-fault.
CREATE OR REPLACE FUNCTION evaluate_al01(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_ref TIMESTAMPTZ;
  v_fault_count INT;
  v_max_value NUMERIC;
  v_severe BOOLEAN;
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  SELECT COALESCE(submitted_at, now()) INTO v_ref
  FROM applications WHERE application_id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'evaluate_al01: application % does not exist', p_application_id;
  END IF;

  SELECT count(*) INTO v_fault_count
  FROM claims_history c
  WHERE c.application_id = p_application_id
    AND c.at_fault
    AND c.claim_date >= (v_ref - interval '5 years')::date;

  SELECT max(current_appraised_value) INTO v_max_value
  FROM vehicles WHERE application_id = p_application_id;

  v_severe := EXISTS (
    SELECT 1 FROM claims_history c
    WHERE c.application_id = p_application_id
      AND c.paid_amount IS NOT NULL
      AND v_max_value IS NOT NULL
      AND c.paid_amount >= 0.30 * v_max_value
  );

  v_fired := (v_fault_count >= 2) OR v_severe;
  v_action := CASE WHEN v_fired THEN 'MANUAL_REVIEW_REQUIRED'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'AL-01', 'AL01_ADVERSE_LOSS_HISTORY', v_action, v_fired, p_decided_by,
          format('at_fault_claims_5yr=%s, max_vehicle_value=%s, severe_single_claim=%s',
                 v_fault_count, v_max_value, v_severe));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- CP-02: aggregate TIV authority cap. Combined appraised value across all
-- vehicles on the application STRICTLY over $2,000,000 (a working default,
-- revisitable against real binding authority - see ADR 0026). At or under does
-- not fire.
CREATE OR REPLACE FUNCTION evaluate_cp02(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_tiv NUMERIC;
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM applications WHERE application_id = p_application_id) THEN
    RAISE EXCEPTION 'evaluate_cp02: application % does not exist', p_application_id;
  END IF;

  SELECT COALESCE(SUM(current_appraised_value), 0) INTO v_tiv
  FROM vehicles WHERE application_id = p_application_id;

  v_fired := v_tiv > 2000000;
  v_action := CASE WHEN v_fired THEN 'MANUAL_REVIEW_SENIOR'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'CP-02', 'CP02_AUTHORITY_LIMIT_EXCEEDED', v_action, v_fired, p_decided_by,
          format('aggregate_tiv=%s, cap=2000000', v_tiv));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- DH-01: DUI OR reckless-driving conviction within 5 years. Spans the applicant
-- and every additional driver (person_violations is application-scoped:
-- subject_driver_id NULL is the applicant, otherwise an additional driver).
-- Reckless driving was folded in at ADR 0036 - same 5-year look-back, same
-- MANUAL_REVIEW_SENIOR severity as DUI (the insurance colleague's confirmation:
-- "same five year look to keep it simple"), no separate threshold. Convictions
-- only (the threshold is "conviction"). Look-back measured from the application
-- date.
--
-- Type-aware reason_code, still ONE decision_log row per rule (the invariant the
-- orchestrator, the read views' latest-per-rule dedup, and the row-count
-- assertions all rely on - a second 'DH-01' row would break all three). DUI
-- takes precedence over reckless driving when both are present within the window;
-- the matched type(s) are recorded in notes. A non-firing audit row keeps the
-- rule's canonical DUI code.
CREATE OR REPLACE FUNCTION evaluate_dh01(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_ref TIMESTAMPTZ;
  v_dui BOOLEAN;
  v_reckless BOOLEAN;
  v_fired BOOLEAN;
  v_action referral_action_t;
  v_reason TEXT;
  v_matched TEXT;
BEGIN
  SELECT COALESCE(submitted_at, now()) INTO v_ref
  FROM applications WHERE application_id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'evaluate_dh01: application % does not exist', p_application_id;
  END IF;

  -- Which serious conviction types matched inside the 5-year window (bool_or over
  -- the empty set is NULL, hence the COALESCE to false).
  SELECT bool_or(pv.violation_type = 'DUI'),
         bool_or(pv.violation_type = 'reckless_driving')
    INTO v_dui, v_reckless
  FROM person_violations pv
  WHERE pv.application_id = p_application_id
    AND pv.violation_type IN ('DUI', 'reckless_driving')
    AND pv.conviction
    AND pv.violation_date >= (v_ref - interval '5 years')::date;

  v_dui := COALESCE(v_dui, false);
  v_reckless := COALESCE(v_reckless, false);
  v_fired := v_dui OR v_reckless;

  v_reason := CASE
                WHEN v_dui THEN 'DH01_DUI_WITHIN_LOOKBACK'          -- DUI precedence
                WHEN v_reckless THEN 'DH01_RECKLESS_WITHIN_LOOKBACK'
                ELSE 'DH01_DUI_WITHIN_LOOKBACK'                      -- non-firing audit row
              END;
  v_matched := concat_ws(',',
                 CASE WHEN v_dui THEN 'DUI' END,
                 CASE WHEN v_reckless THEN 'reckless_driving' END);

  v_action := CASE WHEN v_fired THEN 'MANUAL_REVIEW_SENIOR'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'DH-01', v_reason, v_action, v_fired, p_decided_by,
          format('serious_conviction_within_5yr=%s, matched_types=[%s] (DUI or reckless driving; ADR 0036)',
                 v_fired, v_matched));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- PC-03: out-of-licensed-territory. The application's garaging_state has no
-- state_rating_table_versions record active at now(). Routes to
-- AUTO_PROCEED_WITH_FLAG (ADR 0036, changed from MANUAL_REVIEW_REQUIRED): the
-- platform's v1 scope is all 50 US states and onboarding is a rollout in
-- progress, so "no active rating record" is the expected interim state for any
-- state not yet onboarded, not a licensing red flag. The rule still FIRES and
-- still writes its reason_code (PC03_OUT_OF_LICENSED_TERRITORY) to the decision
-- log per the matrix's rule 4 - the flag is attached to the file for later
-- review, it just no longer routes to a human before proceeding.
--
-- This does NOT make an un-onboarded state quotable: create_quote() still needs
-- a real rating record + territory factor and fails with
-- TERRITORY_FACTOR_NOT_CONFIGURED for any state that hasn't gone through
-- onboard_state() (ADR 0035). PC-03 firing <=> no rating data <=> that same
-- create_quote() failure downstream - so the change affects the disposition a
-- flagged application shows, not whether it can produce a quote.
CREATE OR REPLACE FUNCTION evaluate_pc03(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_state CHAR(2);
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  SELECT garaging_state INTO v_state
  FROM applications WHERE application_id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'evaluate_pc03: application % does not exist', p_application_id;
  END IF;

  v_fired := NOT EXISTS (
    SELECT 1 FROM state_rating_table_versions s
    WHERE s.state = v_state AND s.effective_range @> now()
  );
  v_action := CASE WHEN v_fired THEN 'AUTO_PROCEED_WITH_FLAG'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'PC-03', 'PC03_OUT_OF_LICENSED_TERRITORY', v_action, v_fired, p_decided_by,
          format('garaging_state=%s, active_rating_table=%s', v_state, NOT v_fired));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- EL-01 (ADR 0028): the $100,000 agreed-value eligibility floor as a referral
-- rule. A risk below the floor is DECLINED, not rated - the source workbook's own
-- language. Fires when ANY vehicle on the application is below the floor
-- (min agreed value < $100,000); a NULL/unknown agreed value is not a floor
-- violation (that is a missing-data question, not this rule's). Emits
-- DECLINE_RECOMMENDED (a human confirms the auto-decline, matching the matrix's
-- "no pure auto-decline except sanctions" philosophy), logged like every other
-- rule. The rating function compute_indicative_premium() enforces the same floor
-- independently, so an ineligible risk can never be rated even if this rule is
-- bypassed.
CREATE OR REPLACE FUNCTION evaluate_el01(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_min_value NUMERIC;
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM applications WHERE application_id = p_application_id) THEN
    RAISE EXCEPTION 'evaluate_el01: application % does not exist', p_application_id;
  END IF;

  SELECT min(current_appraised_value) INTO v_min_value
  FROM vehicles WHERE application_id = p_application_id;

  v_fired := (v_min_value IS NOT NULL AND v_min_value < 100000);
  v_action := CASE WHEN v_fired THEN 'DECLINE_RECOMMENDED'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'EL-01', 'EL01_BELOW_AGREED_VALUE_FLOOR', v_action, v_fired, p_decided_by,
          format('min_agreed_value=%s, floor=100000', v_min_value));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- ADR 0037: seven more referral rules. Same pattern as the rules above -
-- SECURITY DEFINER, exactly one decision_log row per rule per call (fired or
-- not), reads only fields already present in the schema. VV-01/VV-02/DH-02/
-- PC-02/PC-04 are deliberately NOT added here: they need external data sources
-- (VIN decode, title history, household check, sanctions/OFAC, producer
-- verification) that do not exist yet.
-- ============================================================================

-- VV-03: agreed value stale/unsupported. INFORMATION_REQUEST when a vehicle
-- requests agreed value but the appraisal supporting it is missing or stale.
--
-- Scope note (ADR 0037): the matrix's other VV-03 limb - "agreed value > 115%
-- of appraised value" - is NOT implemented, because there is no requested
-- agreed-value AMOUNT field anywhere in the schema (only the boolean
-- agreed_value_requested and current_appraised_value; in this data model the
-- agreed value IS the appraised value). That limb is deferred pending a
-- requested-amount field and its data source. This function is the currency/
-- completeness limb, which the present fields fully support.
--
-- The reappraisal interval is read LIVE from the applicable state's registry
-- record (agreed_value_rules.reappraisal_interval_years) - never hardcoded per
-- state - falling back to a national default when the state is not yet onboarded
-- or the value is null/"TBD"/non-numeric. Real per-state intervals are expected
-- to land shortly, so this must read live.
CREATE OR REPLACE FUNCTION evaluate_vv03(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  c_default_interval CONSTANT INT := 3;  -- national default reappraisal cadence (years), ADR 0037
  v_ref TIMESTAMPTZ;
  v_state CHAR(2);
  v_interval_txt TEXT;
  v_interval INT;
  v_source TEXT;
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  SELECT COALESCE(submitted_at, now()), garaging_state INTO v_ref, v_state
  FROM applications WHERE application_id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'evaluate_vv03: application % does not exist', p_application_id;
  END IF;

  SELECT (agreed_value_rules ->> 'reappraisal_interval_years') INTO v_interval_txt
  FROM state_rating_table_versions
  WHERE state = v_state AND effective_range @> now()
  LIMIT 1;

  IF v_interval_txt IS NULL OR v_interval_txt = 'TBD' OR v_interval_txt !~ '^\d+$' THEN
    v_interval := c_default_interval;
    v_source := 'national_default';
  ELSE
    v_interval := v_interval_txt::int;
    v_source := 'state_registry';
  END IF;

  -- Any vehicle that requests agreed value with a missing or stale appraisal.
  v_fired := EXISTS (
    SELECT 1 FROM vehicles v
    WHERE v.application_id = p_application_id
      AND v.agreed_value_requested
      AND (v.appraisal_date IS NULL
           OR v.appraisal_date < (v_ref - make_interval(years => v_interval))::date)
  );
  v_action := CASE WHEN v_fired THEN 'INFORMATION_REQUEST'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'VV-03', 'VV03_STALE_OR_UNSUPPORTED_AGREED_VALUE', v_action, v_fired, p_decided_by,
          format('stale_or_missing_appraisal=%s, reappraisal_interval_years=%s (%s); 115%%-overvaluation limb not implemented - no requested-amount field',
                 v_fired, v_interval, v_source));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- VV-04: undeclared modification impact. MANUAL_REVIEW_REQUIRED when a vehicle
-- carries modifications but is still categorised production_luxury rather than
-- modified_performance - the value/risk basis and the rating class disagree.
-- A blank/whitespace-only modifications string is not a real modification.
CREATE OR REPLACE FUNCTION evaluate_vv04(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM applications WHERE application_id = p_application_id) THEN
    RAISE EXCEPTION 'evaluate_vv04: application % does not exist', p_application_id;
  END IF;

  v_fired := EXISTS (
    SELECT 1 FROM vehicles v
    WHERE v.application_id = p_application_id
      AND v.modifications IS NOT NULL
      AND btrim(v.modifications) <> ''
      AND v.vehicle_category = 'production_luxury'
  );
  v_action := CASE WHEN v_fired THEN 'MANUAL_REVIEW_REQUIRED'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'VV-04', 'VV04_UNDECLARED_MODIFICATION_IMPACT', v_action, v_fired, p_decided_by,
          format('modified_but_still_production_luxury=%s', v_fired));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- DH-03: suspended/revoked license. MANUAL_REVIEW_SENIOR when the applicant or
-- any additional driver has a suspended or revoked license status. 'expired' is
-- deliberately NOT included (only suspended/revoked, per the matrix threshold).
CREATE OR REPLACE FUNCTION evaluate_dh03(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM applications WHERE application_id = p_application_id) THEN
    RAISE EXCEPTION 'evaluate_dh03: application % does not exist', p_application_id;
  END IF;

  v_fired := EXISTS (
    SELECT 1 FROM applications app
    JOIN applicants a ON a.applicant_id = app.applicant_id
    WHERE app.application_id = p_application_id
      AND a.license_status IN ('suspended', 'revoked')
  ) OR EXISTS (
    SELECT 1 FROM additional_drivers d
    WHERE d.application_id = p_application_id
      AND d.license_status IN ('suspended', 'revoked')
  );
  v_action := CASE WHEN v_fired THEN 'MANUAL_REVIEW_SENIOR'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'DH-03', 'DH03_SUSPENDED_OR_REVOKED_LICENSE', v_action, v_fired, p_decided_by,
          format('suspended_or_revoked_license=%s (applicant or additional driver)', v_fired));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- DH-04: insufficient data for risk computation. INFORMATION_REQUEST when a
-- SUBMITTED (not draft) application is missing a risk-critical field:
-- applicant date_of_birth / license_status / years_licensed, or any vehicle's
-- vin / garaging street address. A draft is never nagged - the completeness gate
-- applies only once the application is submitted. (submit_application sets
-- status to 'submitted' BEFORE it evaluates, ADR 0037, so a first submission is
-- checked here, not just re-submissions.) Vehicle-field checks fire only when a
-- vehicle with a null field exists; a no-vehicle application is out of this
-- rule's scope.
CREATE OR REPLACE FUNCTION evaluate_dh04(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_status application_status_t;
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  SELECT status INTO v_status FROM applications WHERE application_id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'evaluate_dh04: application % does not exist', p_application_id;
  END IF;

  IF v_status = 'draft' THEN
    v_fired := false;
  ELSE
    v_fired := EXISTS (
      SELECT 1 FROM applications app
      JOIN applicants a ON a.applicant_id = app.applicant_id
      WHERE app.application_id = p_application_id
        AND (a.date_of_birth IS NULL OR a.license_status IS NULL OR a.years_licensed IS NULL)
    ) OR EXISTS (
      SELECT 1 FROM vehicles v
      WHERE v.application_id = p_application_id
        AND (v.vin IS NULL OR v.garaging_street IS NULL)
    );
  END IF;

  v_action := CASE WHEN v_fired THEN 'INFORMATION_REQUEST'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'DH-04', 'DH04_INSUFFICIENT_DATA_FOR_RISK_COMPUTATION', v_action, v_fired, p_decided_by,
          format('insufficient_data=%s, status=%s (draft is not gated)', v_fired, v_status));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- AL-02: prior non-renewal/cancellation. MANUAL_REVIEW_REQUIRED when the
-- application's prior_insurance record flags any non-renewal or cancellation
-- history. A missing prior_insurance row is treated as "not flagged" (the fact
-- was not disclosed/discovered), not as a trigger.
CREATE OR REPLACE FUNCTION evaluate_al02(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM applications WHERE application_id = p_application_id) THEN
    RAISE EXCEPTION 'evaluate_al02: application % does not exist', p_application_id;
  END IF;

  v_fired := EXISTS (
    SELECT 1 FROM prior_insurance p
    WHERE p.application_id = p_application_id
      AND p.any_nonrenewal_or_cancellation_history IS TRUE
  );
  v_action := CASE WHEN v_fired THEN 'MANUAL_REVIEW_REQUIRED'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'AL-02', 'AL02_PRIOR_NONRENEWAL_OR_CANCELLATION', v_action, v_fired, p_decided_by,
          format('prior_nonrenewal_or_cancellation=%s', v_fired));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- CP-01: suspected undisclosed business use. MANUAL_REVIEW_REQUIRED heuristic
-- (ADR 0037). Fires on EITHER signal:
--   (1) mileage: a pleasure/commute vehicle with annual_mileage >= 20000 - a
--       business-territory figure inconsistent with the declared use;
--   (2) occupation: a bounded commercial-driving keyword in occupation, AND a
--       pleasure vehicle, AND exactly one vehicle on the application (the
--       matrix's "only vehicle on the policy" qualifier, which cuts false
--       positives for multi-vehicle households).
-- The 20000 threshold and the keyword list are the tunable knobs. Action is
-- review, not decline, so a false positive is a human check, not a harm.
CREATE OR REPLACE FUNCTION evaluate_cp01(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_mileage_hit BOOLEAN;
  v_occ_hit BOOLEAN;
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM applications WHERE application_id = p_application_id) THEN
    RAISE EXCEPTION 'evaluate_cp01: application % does not exist', p_application_id;
  END IF;

  v_mileage_hit := EXISTS (
    SELECT 1 FROM vehicles v
    WHERE v.application_id = p_application_id
      AND v.primary_use IN ('pleasure', 'commute')
      AND v.annual_mileage IS NOT NULL
      AND v.annual_mileage >= 20000
  );

  v_occ_hit := EXISTS (
    SELECT 1 FROM applications app
    JOIN applicants a ON a.applicant_id = app.applicant_id
    WHERE app.application_id = p_application_id
      AND a.occupation ILIKE ANY (ARRAY[
        '%rideshare%', '%ride-share%', '%uber%', '%lyft%', '%livery%', '%taxi%',
        '%chauffeur%', '%courier%', '%delivery%', '%real estate%', '%realtor%'])
  )
  AND EXISTS (
    SELECT 1 FROM vehicles v
    WHERE v.application_id = p_application_id AND v.primary_use = 'pleasure'
  )
  AND (SELECT count(*) FROM vehicles v WHERE v.application_id = p_application_id) = 1;

  v_fired := v_mileage_hit OR v_occ_hit;
  v_action := CASE WHEN v_fired THEN 'MANUAL_REVIEW_REQUIRED'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'CP-01', 'CP01_SUSPECTED_UNDISCLOSED_BUSINESS_USE', v_action, v_fired, p_decided_by,
          format('suspected_business_use=%s (mileage_signal=%s, occupation_signal=%s)', v_fired, v_mileage_hit, v_occ_hit));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- PC-01: garaging address mismatch. MANUAL_REVIEW_REQUIRED when the
-- application's garaging state differs from the applicant's mailing state - the
-- single highest-value rate-evasion signal available before a human looks.
-- Compared at the state grain (applications.garaging_state, the value the system
-- already keys on, vs applicants.mailing_state); the state_override_hook
-- territory_rating_basis is descriptive metadata about HOW a state derives
-- territory, not rule logic, so it does not gate this rule. A null mailing_state
-- means the comparison cannot be made -> not fired (a completeness question, not
-- this rule's). The matrix's "documented reason" exception (seasonal residence,
-- storage) is not representable yet - the human reviewer weighs it.
CREATE OR REPLACE FUNCTION evaluate_pc01(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_garaging CHAR(2);
  v_mailing CHAR(2);
  v_fired BOOLEAN;
  v_action referral_action_t;
BEGIN
  SELECT app.garaging_state, a.mailing_state INTO v_garaging, v_mailing
  FROM applications app
  JOIN applicants a ON a.applicant_id = app.applicant_id
  WHERE app.application_id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'evaluate_pc01: application % does not exist', p_application_id;
  END IF;

  v_fired := (v_mailing IS NOT NULL AND v_garaging <> v_mailing);
  v_action := CASE WHEN v_fired THEN 'MANUAL_REVIEW_REQUIRED'::referral_action_t
                   ELSE 'AUTO_PROCEED'::referral_action_t END;

  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by, notes)
  VALUES (p_application_id, 'PC-01', 'PC01_GARAGING_ADDRESS_MISMATCH', v_action, v_fired, p_decided_by,
          format('garaging_state=%s, mailing_state=%s, mismatch=%s', v_garaging, COALESCE(v_mailing, 'NULL'), v_fired));
  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Orchestrator: evaluates the confirmed rules for one application in a
-- single transaction (one decision_log row written per rule - TWELVE now, after
-- ADR 0037 added seven - fired or not) and returns the single most-severe action.
--
-- referral_action_t is DEFINED in ascending severity order (AUTO_PROCEED lowest
-- ... HARD_DECLINE_COMPLIANCE highest), so GREATEST over the enum is the
-- most-severe action, and a non-firing rule returns AUTO_PROCEED (the floor) -
-- which reduces GREATEST to "the most severe rule that fired, else AUTO_PROCEED".
-- That ordering is an invariant of the enum's definition; tests/0026 asserts it,
-- so a future reorder of the enum fails a test rather than silently mis-routing.
-- The taxonomy is now largely exercised by real rules: INFORMATION_REQUEST
-- (VV-03/DH-04, ADR 0037), AUTO_PROCEED_WITH_FLAG (PC-03), DECLINE_RECOMMENDED
-- (EL-01); only HARD_DECLINE_COMPLIANCE has no producer (PC-02, unbuilt).
CREATE OR REPLACE FUNCTION evaluate_application_referrals(p_application_id UUID, p_decided_by TEXT DEFAULT 'system')
RETURNS referral_action_t AS $$
DECLARE
  v_al referral_action_t;
  v_cp referral_action_t;
  v_dh referral_action_t;
  v_pc referral_action_t;
  v_el referral_action_t;
  v_vv03 referral_action_t;
  v_vv04 referral_action_t;
  v_dh03 referral_action_t;
  v_dh04 referral_action_t;
  v_al02 referral_action_t;
  v_cp01 referral_action_t;
  v_pc01 referral_action_t;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM applications WHERE application_id = p_application_id) THEN
    RAISE EXCEPTION 'evaluate_application_referrals: application % does not exist', p_application_id;
  END IF;

  -- ADR 0026's four rules, EL-01 (ADR 0028), and ADR 0037's seven. The still-
  -- unimplemented matrix rules (VV-01/VV-02, DH-02, CP-03, PC-02/PC-04) need
  -- external data sources and each get added here as their own evaluate_<rule>()
  -- call when those land.
  v_al   := evaluate_al01(p_application_id, p_decided_by);
  v_cp   := evaluate_cp02(p_application_id, p_decided_by);
  v_dh   := evaluate_dh01(p_application_id, p_decided_by);
  v_pc   := evaluate_pc03(p_application_id, p_decided_by);
  v_el   := evaluate_el01(p_application_id, p_decided_by);
  v_vv03 := evaluate_vv03(p_application_id, p_decided_by);
  v_vv04 := evaluate_vv04(p_application_id, p_decided_by);
  v_dh03 := evaluate_dh03(p_application_id, p_decided_by);
  v_dh04 := evaluate_dh04(p_application_id, p_decided_by);
  v_al02 := evaluate_al02(p_application_id, p_decided_by);
  v_cp01 := evaluate_cp01(p_application_id, p_decided_by);
  v_pc01 := evaluate_pc01(p_application_id, p_decided_by);

  RETURN GREATEST(v_al, v_cp, v_dh, v_pc, v_el,
                  v_vv03, v_vv04, v_dh03, v_dh04, v_al02, v_cp01, v_pc01);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- REFERRAL GATE (ADR 0031)
-- The referral engine above was built (ADR 0026/0028) but called nowhere in a
-- real flow - only test fixtures ran it. These two functions wire it in: one
-- triggers evaluation at submission, the other reads the current disposition so
-- create_quote() can refuse to auto-quote a non-clean application. Neither
-- touches the rules or the orchestrator - they only call and read.
-- ============================================================================

-- The current most-severe referral action for an application, derived from
-- decision_log EXACTLY as luxauto_application_referral_view does (ADR 0029):
-- the latest row per rule (DISTINCT ON ... created_at DESC), then max() over the
-- enum's ascending severity order. decision_log is append-only, so re-evaluation
-- appends a fresh set of rows and this always reflects the newest run - no change
-- was needed to support re-evaluation. Returns NULL when the application has
-- never been evaluated (no rows), which the caller treats as distinct from any
-- real disposition. SECURITY DEFINER so a least-privilege caller (or a guard in
-- another SECURITY DEFINER function) can read the disposition without a direct
-- decision_log grant, mirroring how the ADR 0029 view exposes the same fact.
CREATE OR REPLACE FUNCTION current_referral_action(p_application_id UUID)
RETURNS referral_action_t AS $$
  WITH latest_per_rule AS (
    SELECT DISTINCT ON (d.rule_id) d.action_taken
    FROM decision_log d
    WHERE d.application_id = p_application_id
    ORDER BY d.rule_id, d.created_at DESC
  )
  SELECT max(action_taken) FROM latest_per_rule;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Submit an application: the first applications-lifecycle transition. Moves a
-- draft to submitted, stamps submitted_at, and evaluates the referral engine
-- (writing the decision_log rows), returning the most-severe action so the
-- caller sees the disposition. Re-runnable for re-evaluation: allowed from
-- 'draft' (first submission) or 'submitted' (a later re-evaluation after the
-- application's data changed - e.g. a document resolves a flagged item). Each
-- call appends a fresh decision_log set; submitted_at is kept from the FIRST
-- submission (COALESCE), since re-evaluation is not re-submission.
--
-- Minimal status wiring (ADR 0031 decision): status only ever becomes
-- 'submitted' here - the richer disposition->status mapping (recommend-decline ->
-- in_review, hard-decline -> declined, etc.) is a deliberate follow-up, NOT this
-- pass. decision_log, not applications.status, is the sole source of truth for
-- the auto-quote gate, so status staying coarse here is fine.
CREATE OR REPLACE FUNCTION submit_application(p_application_id UUID, p_performed_by TEXT)
RETURNS referral_action_t AS $$
DECLARE
  v_status application_status_t;
  v_action referral_action_t;
BEGIN
  SELECT status INTO v_status
  FROM applications WHERE application_id = p_application_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUBMIT_APPLICATION_NOT_FOUND: application % does not exist', p_application_id;
  END IF;
  IF v_status NOT IN ('draft', 'submitted') THEN
    RAISE EXCEPTION 'SUBMIT_APPLICATION_INVALID_STATE: application % is % - only a draft or already-submitted application can be (re-)submitted', p_application_id, v_status
      USING HINT = 'This minimal lifecycle (ADR 0031) only wires draft->submitted; a bound/declined/withdrawn application is out of its scope.';
  END IF;

  -- Record the transition BEFORE evaluating (ADR 0037, reordered from ADR 0031's
  -- evaluate-then-update): DH-04 gates on a submitted (not draft) status, so the
  -- status must already be 'submitted' when the orchestrator runs for a first
  -- submission to be checked - otherwise DH-04 could only ever fire on a
  -- re-submission. Safe: no rule other than DH-04 reads status, and the
  -- end-state and error/rollback behaviour are identical (both run in one
  -- transaction). submitted_at is stamped here too, so VV-03/DH-01's look-back
  -- reference date is the true submission time.
  UPDATE applications
  SET status = 'submitted',
      submitted_at = COALESCE(submitted_at, now())
  WHERE application_id = p_application_id;

  v_action := evaluate_application_referrals(p_application_id, p_performed_by);

  RETURN v_action;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- UNDERWRITER SUPERVISED RELEASE / REFERRAL OVERRIDE (ADR 0032)
-- The referral gate (ADR 0031) permanently blocks any application worse than
-- AUTO_PROCEED_WITH_FLAG. The taxonomy says a MANUAL_REVIEW_* application is
-- still quotable - just not automatically - so a human underwriter must be able
-- to supervise-release it. This adds that override path AROUND the gate; it does
-- not change what triggers a referral (the rules/orchestrator/submit_application/
-- current_referral_action are untouched).
--
-- THE HARD CONSTRAINT, structurally enforced: HARD_DECLINE_COMPLIANCE
-- (sanctions/compliance) is NEVER overridable by anyone. A sanctions hit has no
-- human discretion, and an AI-driven decline released with no human in the loop
-- is exactly the fact pattern that draws regulatory scrutiny. This is enforced by
-- the whitelist CHECK on referral_overrides below (a row overriding it CANNOT be
-- inserted) AND by an explicit guard in create_quote() - belt and suspenders.
-- DECLINE_RECOMMENDED is different: a human confirming or reversing a
-- recommendation is normal, so it IS overridable.
-- ============================================================================

-- The two authority tiers the referral matrix actually distinguishes - no finer.
-- An enum, matching broker_channel_t / cancellation_type_t (small fixed sets).
DO $$ BEGIN
  CREATE TYPE underwriter_authority_t AS ENUM ('standard', 'senior');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- The first backed-identity concept in the schema: a small MUTABLE reference
-- roster (unlike the append-only audit tables - people join, leave, get
-- promoted). `active` closes a real hole: a departed underwriter must not retain
-- authorization power. Deliberately minimal - no HR/roster system.
CREATE TABLE IF NOT EXISTS underwriters (
  underwriter_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name             TEXT NOT NULL,
  authority_level  underwriter_authority_t NOT NULL,
  active           BOOLEAN NOT NULL DEFAULT true,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The smallest controlled write path onto the roster (same idiom as
-- add_program_participant_with_reallocation). Promotion / deactivation (updating
-- authority_level / active) is a trivial future update_underwriter(), not this
-- pass. NOT schema-seeded: underwriters are operational people, not fixed rate
-- content.
CREATE OR REPLACE FUNCTION add_underwriter(p_name TEXT, p_authority_level underwriter_authority_t)
RETURNS UUID AS $$
DECLARE v_id UUID;
BEGIN
  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'ADD_UNDERWRITER_NAME_REQUIRED: an underwriter must have a name';
  END IF;
  INSERT INTO underwriters (name, authority_level)
  VALUES (p_name, p_authority_level) RETURNING underwriter_id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- The counterpart write path add_underwriter() anticipated (ADR 0038): promote/
-- demote (authority_level), (de/re)activate (active), and rename (name) an
-- existing roster row. Partial update - a NULL argument leaves that field
-- unchanged (COALESCE) - so a caller changes only what it means to. underwriter_id
-- and created_at are immutable (identity and the creation record never change).
-- Same conventions as add_underwriter: SECURITY DEFINER, UPPER_SNAKE error codes,
-- granted to odoo. Like add_underwriter it is the sanctioned wrapper, NOT a lock:
-- underwriters is a deliberately mutable roster (no append-only trigger), so a
-- direct UPDATE is still possible - this just gives one validated place to do it.
--
-- Demotion is allowed. It does NOT retroactively invalidate a past override: a
-- referral_overrides row is append-only and proves valid authorization AT INSERT
-- (the authority trigger enforced it then); create_quote()'s gate reads that row's
-- existence, never the authorizer's current level. The only residual is that a
-- live join of referral_overrides -> underwriters shows the authorizer's CURRENT
-- roster status, not their status at authorization time - an accepted, separately
-- tracked audit gap (a future authorized_by_authority_level snapshot column on
-- referral_overrides, out of scope here because it changes ADR 0032's append-only
-- table). See ADR 0038.
CREATE OR REPLACE FUNCTION update_underwriter(
  p_underwriter_id UUID,
  p_name TEXT DEFAULT NULL,
  p_authority_level underwriter_authority_t DEFAULT NULL,
  p_active BOOLEAN DEFAULT NULL
) RETURNS UUID AS $$
DECLARE v_id UUID;
BEGIN
  IF p_name IS NULL AND p_authority_level IS NULL AND p_active IS NULL THEN
    RAISE EXCEPTION 'UPDATE_UNDERWRITER_NO_CHANGES: at least one of name, authority_level, or active must be supplied';
  END IF;
  IF p_name IS NOT NULL AND length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'UPDATE_UNDERWRITER_NAME_REQUIRED: an underwriter name cannot be blank';
  END IF;

  UPDATE underwriters
  SET name            = COALESCE(p_name, name),
      authority_level = COALESCE(p_authority_level, authority_level),
      active          = COALESCE(p_active, active)
  WHERE underwriter_id = p_underwriter_id
  RETURNING underwriter_id INTO v_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'UPDATE_UNDERWRITER_NOT_FOUND: underwriter % does not exist', p_underwriter_id;
  END IF;

  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- The supervised-release audit record. Append-only, like decision_log /
-- policy_reinstatements. The whitelist CHECK is the STRUCTURAL guarantee that
-- HARD_DECLINE_COMPLIANCE is never overridable - a row overriding it cannot
-- physically be inserted, and the whitelist (not a <> blacklist) also excludes
-- INFORMATION_REQUEST (a data-completeness gate, resolved by re-evaluation, not a
-- risk override) and the AUTO levels, and can't be widened by a future enum value
-- by accident. evaluated_at pins the override to the SPECIFIC evaluation the
-- underwriter reviewed: a later re-evaluation moves current_referral_evaluated_at
-- and this override stops satisfying the guard, so an override can never clear a
-- newer, unreviewed disposition (even one with the same action value).
CREATE TABLE IF NOT EXISTS referral_overrides (
  override_id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  overridden_action             referral_action_t NOT NULL,
  evaluated_at                  TIMESTAMPTZ NOT NULL,
  reason                        TEXT NOT NULL,
  authorized_by_underwriter_id  UUID NOT NULL REFERENCES underwriters(underwriter_id),
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- HARD_DECLINE_COMPLIANCE is absent by construction: this is the hard constraint.
  CONSTRAINT referral_overrides_overridable_ck
    CHECK (overridden_action IN ('MANUAL_REVIEW_REQUIRED', 'MANUAL_REVIEW_SENIOR', 'DECLINE_RECOMMENDED')),
  -- A supervised override with no stated reason defeats the point of a human in the loop.
  CONSTRAINT referral_overrides_reason_nonblank_ck
    CHECK (length(btrim(reason)) > 0)
);
CREATE INDEX IF NOT EXISTS idx_referral_overrides_application ON referral_overrides(application_id);

-- Append-only: no UPDATE, no DELETE, ever - same discipline as decision_log.
CREATE OR REPLACE FUNCTION reject_referral_overrides_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'referral_overrides is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER referral_overrides_no_update
  BEFORE UPDATE ON referral_overrides
  FOR EACH ROW EXECUTE FUNCTION reject_referral_overrides_mutation();

CREATE OR REPLACE TRIGGER referral_overrides_no_delete
  BEFORE DELETE ON referral_overrides
  FOR EACH ROW EXECUTE FUNCTION reject_referral_overrides_mutation();

-- Authority enforcement, STRUCTURAL (a plain CHECK can't subquery underwriters):
-- MANUAL_REVIEW_SENIOR requires a senior; an inactive authorizer is refused; an
-- unknown authorizer is refused (the FK would also catch it, but this gives a
-- clear message). Runs on every INSERT - including a direct one that bypasses
-- authorize_referral_override() - so it is the real enforcement, with the
-- function's pre-check below just providing a friendlier early error.
CREATE OR REPLACE FUNCTION enforce_referral_override_authority()
RETURNS TRIGGER AS $$
DECLARE
  v_level underwriter_authority_t;
  v_active BOOLEAN;
BEGIN
  SELECT authority_level, active INTO v_level, v_active
  FROM underwriters WHERE underwriter_id = NEW.authorized_by_underwriter_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'OVERRIDE_AUTHORIZER_UNKNOWN: underwriter % does not exist', NEW.authorized_by_underwriter_id;
  END IF;
  IF NOT v_active THEN
    RAISE EXCEPTION 'OVERRIDE_AUTHORIZER_INACTIVE: underwriter % is not active and cannot authorize overrides', NEW.authorized_by_underwriter_id;
  END IF;
  IF NEW.overridden_action = 'MANUAL_REVIEW_SENIOR'::referral_action_t AND v_level <> 'senior' THEN
    RAISE EXCEPTION 'OVERRIDE_SENIOR_AUTHORITY_REQUIRED: overriding MANUAL_REVIEW_SENIOR requires a senior underwriter, but % is %', NEW.authorized_by_underwriter_id, v_level;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER referral_overrides_authority_check
  BEFORE INSERT ON referral_overrides
  FOR EACH ROW EXECUTE FUNCTION enforce_referral_override_authority();

-- The evaluation timestamp of the current disposition: max(created_at) over the
-- latest row per rule, exactly the evaluated_at luxauto_application_referral_view
-- (ADR 0029) reports. NULL when never evaluated. The staleness pin reads this.
CREATE OR REPLACE FUNCTION current_referral_evaluated_at(p_application_id UUID)
RETURNS TIMESTAMPTZ AS $$
  WITH latest_per_rule AS (
    SELECT DISTINCT ON (d.rule_id) d.created_at
    FROM decision_log d
    WHERE d.application_id = p_application_id
    ORDER BY d.rule_id, d.created_at DESC
  )
  SELECT max(created_at) FROM latest_per_rule;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Record a supervised override: the single controlled write path onto
-- referral_overrides. Validates that the override targets the application's ACTUAL
-- current disposition, refuses a compliance decline with a clear message (the
-- table CHECK is the structural backstop), pins the override to the current
-- evaluation, and does a friendly authority pre-check (the trigger is the real
-- enforcement). p_underwriter_id is a FK into underwriters - the ONE deliberately
-- backed-identity argument in the system; every other function's free-text
-- performed_by/decided_by convention is untouched (ADR 0032), because override
-- authorization is the one action whose whole point is a specific, authority-
-- bearing human standing behind it.
CREATE OR REPLACE FUNCTION authorize_referral_override(
  p_application_id UUID,
  p_overridden_action referral_action_t,
  p_reason TEXT,
  p_underwriter_id UUID
) RETURNS UUID AS $$
DECLARE
  v_current referral_action_t;
  v_eval TIMESTAMPTZ;
  v_level underwriter_authority_t;
  v_active BOOLEAN;
  v_override_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM applications WHERE application_id = p_application_id) THEN
    RAISE EXCEPTION 'OVERRIDE_APPLICATION_NOT_FOUND: application % does not exist', p_application_id;
  END IF;

  v_current := current_referral_action(p_application_id);
  IF v_current IS NULL THEN
    RAISE EXCEPTION 'OVERRIDE_APPLICATION_NOT_EVALUATED: application % has no referral evaluation to override', p_application_id;
  END IF;
  IF v_current <= 'AUTO_PROCEED_WITH_FLAG'::referral_action_t THEN
    RAISE EXCEPTION 'OVERRIDE_NOTHING_TO_OVERRIDE: application % is already clear (disposition %) - no override needed', p_application_id, v_current;
  END IF;
  IF v_current = 'HARD_DECLINE_COMPLIANCE'::referral_action_t THEN
    RAISE EXCEPTION 'OVERRIDE_COMPLIANCE_DECLINE_FORBIDDEN: a HARD_DECLINE_COMPLIANCE (sanctions/compliance) disposition is never overridable by anyone'
      USING HINT = 'Structurally enforced by the referral_overrides CHECK as well - no such row can be recorded.';
  END IF;
  IF p_overridden_action IS DISTINCT FROM v_current THEN
    RAISE EXCEPTION 'OVERRIDE_DISPOSITION_MISMATCH: override targets % but the application''s current disposition is % - only the current disposition can be overridden', p_overridden_action, v_current;
  END IF;

  -- Friendly authority pre-check; the BEFORE INSERT trigger is the real enforcement.
  SELECT authority_level, active INTO v_level, v_active
  FROM underwriters WHERE underwriter_id = p_underwriter_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'OVERRIDE_AUTHORIZER_UNKNOWN: underwriter % does not exist', p_underwriter_id;
  END IF;
  IF NOT v_active THEN
    RAISE EXCEPTION 'OVERRIDE_AUTHORIZER_INACTIVE: underwriter % is not active and cannot authorize overrides', p_underwriter_id;
  END IF;
  IF p_overridden_action = 'MANUAL_REVIEW_SENIOR'::referral_action_t AND v_level <> 'senior' THEN
    RAISE EXCEPTION 'OVERRIDE_SENIOR_AUTHORITY_REQUIRED: overriding MANUAL_REVIEW_SENIOR requires a senior underwriter, but % is %', p_underwriter_id, v_level;
  END IF;

  -- Pin to the evaluation being reviewed (staleness): a later re-evaluation moves
  -- this, and the override then stops satisfying create_quote()'s guard.
  v_eval := current_referral_evaluated_at(p_application_id);

  INSERT INTO referral_overrides
    (application_id, overridden_action, evaluated_at, reason, authorized_by_underwriter_id)
  VALUES (p_application_id, p_overridden_action, v_eval, p_reason, p_underwriter_id)
  RETURNING override_id INTO v_override_id;

  RETURN v_override_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- RATING ENGINE v1 - MINIMAL CORE (ADR 0028)
-- Deliberately simplified: base rate (by rating class + agreed-value band) x
-- per-state territory factor, grossed up to an INDICATIVE premium. All other
-- factors in the source workbook (driver/claims/deductible/cat-zone/ALAE/ULAE/
-- risk margin/liability/underwriter judgment - 28 total) are OUT of v1 scope.
-- The output is called "indicative_premium", NOT "technical premium", which in
-- the source material means the full multi-factor calculation. All loaded rate
-- numbers are illustrative benchmarks, not actuarially certified or filed. See
-- ADR 0028.
-- ============================================================================

-- Base rate per $100 of agreed value, keyed by a 12-class rating taxonomy that
-- is INDEPENDENT of the 6-value vehicle_category enum (the workbook classes are
-- finer than the enum and do not align 1:1, so keying on the enum could neither
-- hold all 12 nor future-proof for classes not yet in the enum). value bands are
-- [lower, upper); a NULL upper is the open-ended top band. effective_range
-- versions the table the way state_rating_table_versions and short_rate_factors
-- are versioned.
CREATE TABLE IF NOT EXISTS rating_base_rates (
  base_rate_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  rating_vehicle_class  SMALLINT NOT NULL,
  rating_class_label    TEXT NOT NULL,
  value_band_lower      NUMERIC(14,2) NOT NULL,
  value_band_upper      NUMERIC(14,2),
  base_rate             NUMERIC(8,4) NOT NULL,
  effective_range       TSTZRANGE NOT NULL,
  source_reference      TEXT NOT NULL
    DEFAULT 'Illustrative underwriting benchmark, not actuarially certified - see workbook README disclaimer',
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT rating_base_rates_class_ck CHECK (rating_vehicle_class BETWEEN 1 AND 12),
  CONSTRAINT rating_base_rates_band_ck  CHECK (value_band_upper IS NULL OR value_band_upper > value_band_lower),
  CONSTRAINT rating_base_rates_rate_ck  CHECK (base_rate >= 0),
  CONSTRAINT no_overlapping_base_rate_bands
    EXCLUDE USING gist (rating_vehicle_class WITH =,
                        numrange(value_band_lower, value_band_upper) WITH &&,
                        effective_range WITH &&)
);

-- The confirmed 12 x 7 benchmark table (84 rows). Loaded once (guarded on an
-- empty table) as a class-array cross-joined with the seven value bands, so the
-- 84 rows are 12 rate arrays x 7 band definitions rather than 84 hand-typed
-- lines - less transcription risk, same result.
INSERT INTO rating_base_rates (rating_vehicle_class, rating_class_label, value_band_lower, value_band_upper, base_rate, effective_range)
SELECT c.cls, c.label, b.lo, b.hi, c.rates[b.idx],
       tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)')
FROM (VALUES
  (1::smallint,  '01 Luxury Sedan/SUV',                ARRAY[0.92,0.75,0.65,0.55,0.48,0.42,0.38]::numeric[]),
  (2::smallint,  '02 Sports/GT',                       ARRAY[1.18,0.95,0.82,0.70,0.58,0.50,0.42]::numeric[]),
  (3::smallint,  '03 Supercar',                        ARRAY[1.42,1.15,0.95,0.80,0.65,0.55,0.45]::numeric[]),
  (4::smallint,  '04 Hypercar',                        ARRAY[1.75,1.45,1.20,1.00,0.82,0.68,0.55]::numeric[]),
  (5::smallint,  '05 Limited Edition/Track',           ARRAY[1.65,1.35,1.10,0.92,0.78,0.64,0.52]::numeric[]),
  (6::smallint,  '06 Vintage Pre-War (pre-1946)',      ARRAY[0.50,0.42,0.38,0.34,0.30,0.27,0.24]::numeric[]),
  (7::smallint,  '07 Post-War Classic (1946-1972)',    ARRAY[0.57,0.48,0.43,0.38,0.33,0.29,0.26]::numeric[]),
  (8::smallint,  '08 Modern Classic (1973-1999)',      ARRAY[0.74,0.62,0.55,0.48,0.42,0.36,0.32]::numeric[]),
  (9::smallint,  '09 Youngtimer (2000-2010)',          ARRAY[0.86,0.72,0.63,0.55,0.47,0.41,0.35]::numeric[]),
  (10::smallint, '10 Competition/Race (non-comp use)', ARRAY[1.00,0.85,0.75,0.65,0.56,0.48,0.42]::numeric[]),
  (11::smallint, '11 Restomod/Coachbuilt',             ARRAY[1.05,0.88,0.78,0.68,0.58,0.50,0.43]::numeric[]),
  (12::smallint, '12 Performance EV/Electric Hyper',   ARRAY[1.58,1.30,1.10,0.95,0.80,0.66,0.55]::numeric[])
) c(cls, label, rates)
CROSS JOIN (VALUES
  (1,   100000::numeric,   250000::numeric),
  (2,   250000::numeric,   500000::numeric),
  (3,   500000::numeric,  1000000::numeric),
  (4,  1000000::numeric,  2000000::numeric),
  (5,  2000000::numeric,  5000000::numeric),
  (6,  5000000::numeric, 10000000::numeric),
  (7, 10000000::numeric,     NULL::numeric)
) b(idx, lo, hi)
WHERE NOT EXISTS (SELECT 1 FROM rating_base_rates);

-- Maps the vehicle_category enum onto a rating class (data-driven, no CASE - the
-- anti-pattern ADR 0027 flagged). Five of six categories map; modified_performance
-- deliberately has NO row (confirmed: not worth a rate class in v1). It stays a
-- valid intake category; it just cannot be auto-rated, and the rating function
-- raises RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY rather than guessing a class.
CREATE TABLE IF NOT EXISTS vehicle_category_rating_class (
  vehicle_category      vehicle_category_t PRIMARY KEY,
  rating_vehicle_class  SMALLINT NOT NULL,
  CONSTRAINT vehicle_category_rating_class_class_ck CHECK (rating_vehicle_class BETWEEN 1 AND 12)
);

INSERT INTO vehicle_category_rating_class (vehicle_category, rating_vehicle_class) VALUES
  ('production_luxury',   1),   -- 01 Luxury Sedan/SUV
  ('exotic',              3),   -- 03 Supercar
  ('classic_collector',   7),   -- 07 Post-War Classic (1946-1972)
  ('pre_war_vintage',     6),   -- 06 Vintage Pre-War
  ('restomod_coachbuilt', 11)   -- 11 Restomod/Coachbuilt
ON CONFLICT (vehicle_category) DO NOTHING;

-- Per-state PD territory factor. Loaded MANUALLY per state as part of onboarding
-- (real proprietary rate content with no sensible universal default), NOT
-- auto-seeded like the flat-10% short-rate factor - a neutral 1.00 auto-seed
-- would silently mis-price real business. The lookup fails loud
-- (TERRITORY_FACTOR_NOT_CONFIGURED) for any state with no row, like
-- short_rate_factor(). v1 ships exactly one placeholder row for test state 'T0'.
CREATE TABLE IF NOT EXISTS territory_factors (
  territory_factor_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  state                CHAR(2) NOT NULL,
  pd_territory_factor  NUMERIC(6,4) NOT NULL,
  effective_range      TSTZRANGE NOT NULL,
  source_reference     TEXT NOT NULL
    DEFAULT 'Illustrative underwriting benchmark, not actuarially certified - see workbook README disclaimer',
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT territory_factors_factor_ck CHECK (pd_territory_factor >= 0),
  CONSTRAINT no_overlapping_territory_factors
    EXCLUDE USING gist (state WITH =, effective_range WITH &&)
);

INSERT INTO territory_factors (state, pd_territory_factor, effective_range, source_reference)
SELECT 'T0', 1.0000, tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
       'Placeholder/test territory factor (neutral 1.00) - not a real state; real per-state factors are loaded during onboarding'
WHERE NOT EXISTS (SELECT 1 FROM territory_factors WHERE state = 'T0');

-- The v1 indicative-premium computation: base rate x territory factor, grossed
-- up by the 0.53 divisor (1 - 0.47: target profit 10% + reinsurance 5% + admin
-- 2% + acquisition commission 30%). The 30% acquisition is the platform's own
-- confirmed figure - ADR 0007's addendum makes broker + MGA commission sum to
-- exactly 30% by construction - overriding the workbook's illustrative 27.5%.
--
-- Below the $100,000 agreed-value floor a risk is DECLINED, not rated: this
-- function refuses (RATING_BELOW_AGREED_VALUE_FLOOR), and EL-01 in the referral
-- engine records the decline. Every "not configured" case fails loud rather than
-- guessing. Returns the premium plus an auditable JSONB breakdown for
-- quotes.rating_basis.
CREATE OR REPLACE FUNCTION compute_indicative_premium(
  p_vehicle_category vehicle_category_t,
  p_agreed_value NUMERIC,
  p_state CHAR(2),
  p_as_of TIMESTAMPTZ DEFAULT now()
) RETURNS TABLE (
  indicative_premium NUMERIC,
  rating_vehicle_class SMALLINT,
  base_rate NUMERIC,
  territory_factor NUMERIC,
  breakdown JSONB
) AS $$
DECLARE
  v_class SMALLINT; v_label TEXT;
  v_base_rate NUMERIC; v_band_lower NUMERIC; v_band_upper NUMERIC;
  v_terr NUMERIC; v_base_loss_cost NUMERIC; v_adjusted NUMERIC; v_premium NUMERIC;
BEGIN
  IF p_agreed_value < 100000 THEN
    RAISE EXCEPTION 'RATING_BELOW_AGREED_VALUE_FLOOR: agreed value % is below the $100,000 eligibility floor - the risk is declined, not rated', p_agreed_value
      USING HINT = 'A risk below the $100,000 agreed-value floor is auto-declined (EL-01 in the referral engine), never rated.';
  END IF;

  SELECT m.rating_vehicle_class INTO v_class
  FROM vehicle_category_rating_class m WHERE m.vehicle_category = p_vehicle_category;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY: vehicle_category % has no rating class mapping and cannot be auto-rated', p_vehicle_category
      USING HINT = 'The category is valid for intake but has no row in vehicle_category_rating_class (e.g. modified_performance in v1). It cannot be auto-rated until a class mapping is configured - no default is substituted.';
  END IF;

  SELECT r.base_rate, r.rating_class_label, r.value_band_lower, r.value_band_upper
    INTO v_base_rate, v_label, v_band_lower, v_band_upper
  FROM rating_base_rates r
  WHERE r.rating_vehicle_class = v_class
    AND p_agreed_value >= r.value_band_lower
    AND (r.value_band_upper IS NULL OR p_agreed_value < r.value_band_upper)
    AND r.effective_range @> p_as_of;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RATING_BASE_RATE_NOT_CONFIGURED: no base rate for rating class % at agreed value % (as of %)', v_class, p_agreed_value, p_as_of;
  END IF;

  SELECT tf.pd_territory_factor INTO v_terr
  FROM territory_factors tf
  WHERE tf.state = p_state AND tf.effective_range @> p_as_of;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TERRITORY_FACTOR_NOT_CONFIGURED: no territory factor loaded for state % (as of %)', p_state, p_as_of
      USING HINT = 'Territory factors are real per-state rate content loaded during state onboarding; there is no default. Load the state factor before rating there.';
  END IF;

  v_base_loss_cost := p_agreed_value / 100 * v_base_rate;
  v_adjusted := v_base_loss_cost * v_terr;
  v_premium := ROUND(v_adjusted / 0.53, 2);

  RETURN QUERY SELECT
    v_premium, v_class, v_base_rate, v_terr,
    jsonb_build_object(
      'model', 'indicative_premium_v1',
      'note', 'Indicative premium (v1: base rate x territory factor, grossed up). NOT the full technical premium.',
      'disclaimer', 'Illustrative underwriting benchmark, not actuarially certified.',
      'agreed_value', p_agreed_value,
      'rating_vehicle_class', v_class,
      'rating_class_label', v_label,
      'value_band', jsonb_build_object('lower', v_band_lower, 'upper', v_band_upper),
      'base_rate_per_100', v_base_rate,
      'base_loss_cost', v_base_loss_cost,
      'territory_state', p_state,
      'territory_factor', v_terr,
      'gross_up_divisor', 0.53,
      'indicative_premium', v_premium
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- QUOTA SHARE / COMMISSION WATERFALL (ADR 0007)
-- Direct analogue to the Energy manual's Ch.10 commission waterfall and
-- Ch.11 market panel structure. In the admitted market this more often
-- represents a reinsurance/participation arrangement behind a single
-- fronting carrier than a Lloyd's-style multi-syndicate policy panel, but
-- the accounting shape is identical either way - see ADR 0007 for the
-- full scoping discussion.
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE participant_type_t AS ENUM ('capacity_provider', 'reinsurer', 'mga_retention');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS insurance_programs (
  program_id                        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  program_name                      TEXT NOT NULL,
  capacity_provider_name            TEXT NOT NULL,  -- the admitted fronting carrier
  effective_range                   TSTZRANGE NOT NULL,
  estimated_premium_income          NUMERIC(14,2),
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS program_participants (
  participant_id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  program_id                        UUID NOT NULL REFERENCES insurance_programs(program_id) ON DELETE CASCADE,
  participant_type                  participant_type_t NOT NULL,
  participant_name                  TEXT NOT NULL,
  share_percentage                  NUMERIC(5,2) NOT NULL CHECK (share_percentage > 0 AND share_percentage <= 100),
  commission_rate                   NUMERIC(5,2),  -- % of premium retained as commission, where applicable
                                                       -- (e.g. the MGA's own fee under the program)
  profit_commission_formula         TEXT,  -- free text pending underwriting/finance sign-off - see
                                              -- ADR 0007's open items, not yet a computed formula
  effective_range                   TSTZRANGE NOT NULL,

  -- ADR 0017. Scoped per (program_id, participant_name, participant_type),
  -- not per program_id: multiple participants are legitimately concurrent on
  -- one program, exactly as multiple vehicles are on one policy (ADR 0016).
  -- The same named entity may hold two different roles on one program (a
  -- fronting carrier that also takes a reinsurance share), so the role is
  -- part of the key; what can never happen is the same entity holding the
  -- same role twice at once, which is a duplicate that the waterfall would
  -- silently pay twice.
  CONSTRAINT no_overlapping_program_participants
    EXCLUDE USING gist (program_id WITH =, participant_name WITH =,
                        participant_type WITH =, effective_range WITH &&)
);

CREATE INDEX IF NOT EXISTS idx_program_participants_program ON program_participants(program_id);

-- ADR 0017: append-only, same discipline as policy_endorsements/
-- policy_vehicles/policy_drivers. A participant's share changing over the
-- life of a program is a new row, never an edit to the old one - the old
-- row is what a settlement report for a past period has to be able to read.
--
-- The ONE mechanical difference from the policy-side append-only tables, and
-- the reason for the escape hatch below: those tables let their correction
-- function run `ALTER TABLE ... DISABLE TRIGGER` for a single statement.
-- That is impossible here. This table also carries a DEFERRABLE constraint
-- trigger (the share-sum check), so any UPDATE leaves pending trigger events,
-- and Postgres refuses `ALTER TABLE ... ENABLE TRIGGER` while a table has
-- pending trigger events - the re-enable fails and the supersession cannot
-- complete. Verified against luxauto-pg, not assumed; see ADR 0017.
--
-- So the exception is expressed in the trigger instead, and narrowly: the one
-- mutation a supersession actually needs is closing a row's upper bound,
-- leaving every other column and the lower bound untouched. That is stricter
-- than DISABLE TRIGGER, which turns the rule off entirely for the duration.
-- The flag is transaction-local (set_config's is_local) and cleared by
-- correct_program_participant() immediately after its UPDATE. It is not a
-- privilege boundary - `odoo` has no UPDATE grant on this table at all, and
-- anyone who could set the flag and hand-craft the matching UPDATE could
-- equally drop the trigger - it is a guard against the function's own
-- escape hatch being reachable by accident from ordinary application writes.
CREATE OR REPLACE FUNCTION reject_program_participants_mutation()
RETURNS TRIGGER AS $$
BEGIN
  -- Same two permitted shapes as the policy-side tables (ADR 0016 addendum 3):
  -- close the upper bound, or empty the row when the corrected one starts at
  -- or before it. ADR 0017's explicit column list is folded into the same
  -- to_jsonb comparison the other three use - identical in effect, minus the
  -- one column it silently omitted (created_at), and a column added to this
  -- table later is covered without anyone remembering.
  IF TG_OP = 'UPDATE'
     AND current_setting('luxauto.superseding_participant', true) = 'on'
     AND NOT isempty(OLD.effective_range)
     AND (isempty(NEW.effective_range)
          OR lower(NEW.effective_range) IS NOT DISTINCT FROM lower(OLD.effective_range))
     AND to_jsonb(NEW) - 'effective_range' = to_jsonb(OLD) - 'effective_range'
  THEN
    RETURN NEW;  -- correct_program_participant() closing or emptying this row
  END IF;

  RAISE EXCEPTION 'program_participants is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER program_participants_no_update
  BEFORE UPDATE ON program_participants
  FOR EACH ROW EXECUTE FUNCTION reject_program_participants_mutation();

CREATE OR REPLACE TRIGGER program_participants_no_delete
  BEFORE DELETE ON program_participants
  FOR EACH ROW EXECUTE FUNCTION reject_program_participants_mutation();

-- Risk-bearing participant shares (capacity_provider + reinsurer) must sum to
-- 100% per program - at every instant of the program's own term, not summed
-- across all history (ADR 0017; ADR 0007 shipped the non-temporal version and
-- flagged it, ADR 0014 and ADR 0016 both name-checked the gap as still open).
--
-- Why "at every instant" rather than "at each version boundary": those are
-- the same rule. Shares are piecewise-constant in time - the active set only
-- changes where some row's range starts or ends - so checking every boundary
-- point IS checking every instant, with finitely many probes. This function
-- returns the earliest instant inside the program term where the risk-bearing
-- shares don't total 100, or no rows if the program is sound. One
-- implementation, used by both the constraint trigger and the migration guard
-- below, rather than the same logic written twice.
--
-- A program with no risk-bearing participants at all is not checked (the
-- EXISTS below): that's a program whose panel hasn't been set up yet, which
-- has to remain insertable, and it's the same escape the original
-- `total_share != 0` clause provided.
-- ADR 0021 splits this in two. `program_share_gaps()` is the probe engine and
-- returns EVERY bad instant, each labelled 'under' or 'over';
-- `first_program_share_gap()` is the LIMIT 1 wrapper ADR 0017's callers
-- already use, now carrying the same third column.
--
-- The split is forced by ADR 0021's suppression rule, not cosmetic. ADR 0021
-- lets an under-100% stretch exist while it is tracked by an open
-- program_coverage_gaps row, but keeps over-100% an unconditional hard block.
-- A function that reports only the *earliest* bad instant cannot express that
-- pair: on a program with an under at March and an over at September, the
-- suppressed under is all the caller would ever see, and the overlap - the
-- case where the waterfall pays someone twice - would pass silently. The
-- trigger therefore asks for the two directions separately, which needs a
-- function that returns more than one row. The probe logic itself is still
-- written exactly once, here, per ADR 0017's single-source-of-truth point.
--
-- Returns no rows for a sound program. `direction` is derived from the same
-- total the row reports, so the two can never disagree.
--
-- ADR 0021 addendum adds `p_term_override`. The insurance_programs term
-- trigger has to ask this question about a term that does not exist yet - it
-- runs BEFORE UPDATE, so `NEW.effective_range` is not what a read of
-- insurance_programs would return. A parameter was chosen over a sibling
-- function for the reason ADR 0017 and ADR 0021 both gave: the probe set, the
-- containment semantics and the tolerance band are the rule, and the rule
-- lives in one place. Passing NULL (the default, and what every pre-existing
-- caller does implicitly) reads the committed term exactly as before.
--
-- Both one-argument forms are dropped rather than left in place: adding a
-- defaulted parameter creates an OVERLOAD, not a replacement, and a bare
-- program_share_gaps(uuid) call would then be ambiguous between the two.
DROP FUNCTION IF EXISTS first_program_share_gap(UUID);
DROP FUNCTION IF EXISTS program_share_gaps(UUID);

CREATE OR REPLACE FUNCTION program_share_gaps(
  p_program_id UUID,
  p_term_override TSTZRANGE DEFAULT NULL
)
RETURNS TABLE (bad_instant TIMESTAMPTZ, total_share NUMERIC, direction TEXT) AS $$
  WITH prog AS (
    SELECT COALESCE(p_term_override,
                    (SELECT effective_range FROM insurance_programs
                      WHERE program_id = p_program_id)) AS term
  ),
  risk AS (
    SELECT share_percentage, effective_range
    FROM program_participants
    WHERE program_id = p_program_id
      AND participant_type IN ('capacity_provider', 'reinsurer')
  ),
  -- Every point where the active set can change, plus the start of the
  -- program term itself (which catches a panel that starts late).
  probes AS (
    SELECT COALESCE(lower(term), '-infinity'::TIMESTAMPTZ) AS t FROM prog
    UNION
    SELECT lower(effective_range) FROM risk
    UNION
    SELECT upper(effective_range) FROM risk
  ),
  -- The total per probe, computed once rather than twice as ADR 0017's
  -- version did (it repeated the correlated SUM in the select list and the
  -- WHERE clause); same result, and 'direction' now has a single source.
  totals AS (
    SELECT p.t,
           COALESCE((SELECT SUM(r.share_percentage) FROM risk r
                     WHERE r.effective_range @> p.t), 0) AS total
    FROM probes p, prog
    WHERE p.t IS NOT NULL               -- an unbounded row bound; the program's own probe covers it
      AND prog.term @> p.t              -- '[)' semantics: the term's own upper bound isn't inside it
      AND EXISTS (SELECT 1 FROM risk)
  )
  SELECT t, total, CASE WHEN total < 100 THEN 'under' ELSE 'over' END
  FROM totals
  WHERE total NOT BETWEEN 99.99 AND 100.01
  ORDER BY t;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION first_program_share_gap(
  p_program_id UUID,
  p_term_override TSTZRANGE DEFAULT NULL
)
RETURNS TABLE (bad_instant TIMESTAMPTZ, total_share NUMERIC, direction TEXT) AS $$
  SELECT bad_instant, total_share, direction
  FROM program_share_gaps(p_program_id, p_term_override)
  ORDER BY bad_instant
  LIMIT 1;
$$ LANGUAGE sql STABLE;

-- ADR 0021. Placed here rather than beside the other ADR 0021 objects further
-- down because check_program_shares_sum_to_100() immediately below is its
-- first reader, and a table should exist above the code that reads it even
-- where plpgsql's run-time name resolution would forgive the reverse.
--
-- An open (unresolved) row here suppresses the under-100% branch of the share
-- check for its whole program. The suppression is deliberately coarse -
-- per-program, not per-stranded-window - and ADR 0021 section 2 argues why:
-- matching a gap row to the exact interval it excuses would be a second
-- temporal model layered on the first, and would have to be kept correct as
-- the panel moves underneath it.
--
-- participant_id_removed is nullable on purpose. Every gap this ADR can
-- currently open comes from remove_program_participant(), but a gap is a
-- statement about a program's coverage, not about a removal, and a future
-- reason to open one (a reinsurer failing mid-term, a treaty voided from
-- inception) should not have to invent a participant row to point at.
CREATE TABLE IF NOT EXISTS program_coverage_gaps (
  gap_id                            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  program_id                        UUID NOT NULL REFERENCES insurance_programs(program_id) ON DELETE CASCADE,
  participant_id_removed            UUID REFERENCES program_participants(participant_id),
  removal_date                      TIMESTAMPTZ NOT NULL,
  reason                            TEXT NOT NULL,
  resolved                          BOOLEAN NOT NULL DEFAULT false,
  resolved_at                       TIMESTAMPTZ,
  resolution_note                   TEXT,
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The share check asks exactly one question of this table on every write to
-- program_participants: "are there unresolved rows for this program?"
CREATE INDEX IF NOT EXISTS idx_program_coverage_gaps_program_resolved
  ON program_coverage_gaps(program_id, resolved);

CREATE OR REPLACE FUNCTION check_program_shares_sum_to_100()
RETURNS TRIGGER AS $$
DECLARE
  v_program_id UUID;
  v_term TSTZRANGE;
  v_outside RECORD;
  v_gap RECORD;
  v_open_gaps INTEGER;
BEGIN
  v_program_id := COALESCE(NEW.program_id, OLD.program_id);

  SELECT effective_range INTO v_term
  FROM insurance_programs
  WHERE program_id = v_program_id;

  -- The program itself went away in this transaction (ON DELETE CASCADE);
  -- there is no term left to validate the panel against.
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Participation outside the program's own term is what makes "100% at
  -- every instant of the term" a well-defined question in the first place.
  SELECT participant_name, participant_type, effective_range INTO v_outside
  FROM program_participants
  WHERE program_id = v_program_id
    AND NOT (effective_range <@ v_term)
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'PROGRAM_PARTICIPANT_OUTSIDE_TERM: % (%) on program % is effective % , which is not contained in the program term %',
      v_outside.participant_name, v_outside.participant_type, v_program_id,
      v_outside.effective_range, v_term
      USING HINT = 'A participant cannot bear risk when the program is not in force. Either shorten the participant''s effective_range to fit the program term, or change the program term first.';
  END IF;

  -- ADR 0021 asks the two directions as two separate questions, earliest
  -- first within each. Asking once for "the earliest bad instant" and then
  -- branching on its direction would be wrong: on a panel that is under at
  -- March and over at September, the March row is the only one such a query
  -- returns, and suppressing it would carry the September overlap through
  -- unexamined. Over-100% is never suppressible, so it is asked first and on
  -- its own.
  --
  -- (The percent signs that used to sit against these numbers are gone. RAISE
  -- scans its format left to right, so the old '%%%' resolved as a literal '%'
  -- followed by a placeholder and printed "%60.00" - the sign on the wrong
  -- side of the value. There is no ordering of those three characters that
  -- yields "60.00%", so the wording carries the unit instead.)
  SELECT * INTO v_gap FROM program_share_gaps(v_program_id)
  WHERE direction = 'over'
  ORDER BY bad_instant
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'PROGRAM_SHARES_NOT_100_AT_INSTANT: program % risk-bearing participant shares total % percent as of %, must equal 100',
      v_program_id, v_gap.total_share, v_gap.bad_instant
      USING HINT = 'Over 100 is an overlap - usually an old row that was not closed when its replacement was added - and is never permitted. An unresolved program_coverage_gaps row does NOT suppress this case; it only ever suppresses an under-100 gap. This trigger is DEFERRABLE INITIALLY DEFERRED, so close the outgoing row and add the incoming one in the same transaction.';
  END IF;

  SELECT * INTO v_gap FROM program_share_gaps(v_program_id)
  WHERE direction = 'under'
  ORDER BY bad_instant
  LIMIT 1;

  IF FOUND THEN
    SELECT count(*) INTO v_open_gaps
    FROM program_coverage_gaps
    WHERE program_id = v_program_id AND NOT resolved;

    IF v_open_gaps > 0 THEN
      -- Suppressed, but not silent. The gap table records that someone
      -- accepted an under-placed panel; a NOTICE records that the database
      -- acted on that acceptance, and puts the instant and the total in the
      -- Postgres log where a later "why did this program pay out short?"
      -- has something to find. Costing one log line per suppressed write is
      -- the cheapest available alternative to the state being invisible.
      RAISE NOTICE 'PROGRAM_COVERAGE_GAP_OPEN: program % is under-placed (risk-bearing shares total % percent as of %); permitted because % unresolved program_coverage_gaps row(s) exist for it',
        v_program_id, v_gap.total_share, v_gap.bad_instant, v_open_gaps;
    ELSE
      RAISE EXCEPTION 'PROGRAM_SHARES_NOT_100_AT_INSTANT: program % risk-bearing participant shares total % percent as of %, must equal 100',
        v_program_id, v_gap.total_share, v_gap.bad_instant
        USING HINT = 'Under 100 means part of the risk is unplaced at that instant. If this is a deliberate mid-term removal, use remove_program_participant() - it opens a program_coverage_gaps row, which suppresses this check for the program until resolve_program_coverage_gap() closes it. This trigger is DEFERRABLE INITIALLY DEFERRED, so close the outgoing row and add the incoming one in the same transaction.';
    END IF;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN
  CREATE CONSTRAINT TRIGGER program_participants_sum_check
    AFTER INSERT OR UPDATE OR DELETE ON program_participants
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_program_shares_sum_to_100();
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- ADR 0017 migration, same guarded shape as the ADR 0016 addendum's: the
-- CREATE TABLE above carries the exclusion constraint, but it's CREATE TABLE
-- IF NOT EXISTS, so a database that already has this table would never get
-- it. Existing rows are counted and reported before anything is enforced -
-- these are capacity agreements, and a schema file that "fixes" them to
-- apply cleanly is worse than one that refuses.
--
-- The identity columns (participant_name, participant_type, effective_range)
-- were already NOT NULL from ADR 0007 - nothing to change, stated explicitly
-- and re-asserted idempotently so the ADR 0015 verifier checks them rather
-- than the file merely assuming them.
DO $$
DECLARE
  v_overlaps INTEGER;
  v_bad_programs INTEGER;
BEGIN
  SELECT count(*) INTO v_overlaps
  FROM program_participants a
  JOIN program_participants b
    ON a.participant_id < b.participant_id
   AND a.program_id = b.program_id
   AND a.participant_name = b.participant_name
   AND a.participant_type = b.participant_type
   AND a.effective_range && b.effective_range;

  IF v_overlaps > 0 THEN
    RAISE EXCEPTION 'ADR 0017: cannot add no_overlapping_program_participants - % overlapping pair(s) of rows share a (program, participant, role) and an effective period', v_overlaps
      USING HINT = 'Each pair is one participant counted twice for the same period - the waterfall pays both. Close the superseded row''s effective_range (or delete the duplicate) before re-running this file.';
  END IF;

  SELECT count(*) INTO v_bad_programs
  FROM insurance_programs p
  WHERE EXISTS (SELECT 1 FROM first_program_share_gap(p.program_id));

  IF v_bad_programs > 0 THEN
    RAISE EXCEPTION 'ADR 0017: cannot enforce the temporal 100%% share rule - % existing program(s) do not total 100%% at every instant of their term', v_bad_programs
      USING HINT = 'Run: SELECT p.program_id, g.* FROM insurance_programs p, LATERAL first_program_share_gap(p.program_id) g; to see the first bad instant per program. Fix the panels, then re-run this file.';
  END IF;

  ALTER TABLE program_participants ALTER COLUMN participant_name SET NOT NULL;
  ALTER TABLE program_participants ALTER COLUMN participant_type SET NOT NULL;
  ALTER TABLE program_participants ALTER COLUMN effective_range SET NOT NULL;

  -- Checked explicitly rather than wrapped in EXCEPTION WHEN duplicate_object
  -- like the enum types above: an EXCLUDE constraint builds an index behind
  -- itself, so re-adding an existing one raises duplicate_table ("relation
  -- ... already exists"), not duplicate_object, and a duplicate_object
  -- handler silently fails to catch it. Found by re-running this file, which
  -- is the entire point of ADR 0015's idempotency requirement.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'no_overlapping_program_participants'
      AND conrelid = 'program_participants'::regclass
  ) THEN
    ALTER TABLE program_participants
      ADD CONSTRAINT no_overlapping_program_participants
      EXCLUDE USING gist (program_id WITH =, participant_name WITH =,
                          participant_type WITH =, effective_range WITH &&);
  END IF;
END $$;

-- Supersedes one participant row with a corrected/renegotiated one, mirroring
-- correct_policy_endorsement()/correct_policy_vehicle() (ADR 0014/0016):
-- close the old row's range at the new row's start, insert the new row, never
-- mutate in place. Same shape, different escape hatch - see the append-only
-- trigger function above for why this one can't use DISABLE TRIGGER.
-- No audit-log write, unlike its policy-side siblings -
-- policy_events is foreign-keyed to a policy and there is no program-level
-- event table; the append-only row history is this table's only audit trail
-- today, and it records what changed and when, but not who. Named as an open
-- item in ADR 0017 rather than fixed by inventing a table here.
--
-- A share change usually needs a second call in the same transaction (drop
-- one participant to 30%, raise another to 70%): the sum trigger is DEFERRED
-- precisely so a panel change can be several statements and still be checked
-- as one.
CREATE OR REPLACE FUNCTION correct_program_participant(
  p_participant_id UUID,
  p_new_effective_range TSTZRANGE,
  p_new_participant_type participant_type_t,
  p_new_participant_name TEXT,
  p_new_share_percentage NUMERIC,
  p_new_commission_rate NUMERIC,
  p_new_profit_commission_formula TEXT
) RETURNS UUID AS $$
DECLARE
  v_program_id UUID;
  v_old_range TSTZRANGE;
  v_new_id UUID;
BEGIN
  SELECT program_id, effective_range INTO v_program_id, v_old_range
  FROM program_participants
  WHERE participant_id = p_participant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'correct_program_participant: participant % does not exist', p_participant_id;
  END IF;

  IF p_new_participant_name IS NULL OR p_new_participant_type IS NULL THEN
    RAISE EXCEPTION 'PROGRAM_PARTICIPANT_IDENTITY_REQUIRED: correcting participant % requires both a participant_name and a participant_type', p_participant_id
      USING HINT = 'The overlap constraint keys on (program_id, participant_name, participant_type) - a row missing either half would be exempt from it.';
  END IF;

  PERFORM set_config('luxauto.superseding_participant', 'on', true);
  UPDATE program_participants
  -- GREATEST, not the bare new lower bound: correcting a row to a start at or
  -- before its own leaves it no period during which it was ever right, so it
  -- is emptied rather than given an impossible range (ADR 0016 addendum 3).
  SET effective_range = tstzrange(lower(v_old_range),
                                  GREATEST(lower(v_old_range), lower(p_new_effective_range)))
  WHERE participant_id = p_participant_id;
  PERFORM set_config('luxauto.superseding_participant', 'off', true);

  INSERT INTO program_participants (
    program_id, participant_type, participant_name, share_percentage,
    commission_rate, profit_commission_formula, effective_range
  )
  VALUES (
    v_program_id, p_new_participant_type, p_new_participant_name, p_new_share_percentage,
    p_new_commission_rate, p_new_profit_commission_formula, p_new_effective_range
  )
  RETURNING participant_id INTO v_new_id;

  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- ADR 0021: mid-term participant removal, program-term protection, and
-- bundled add-with-reallocation. Closes the three items ADR 0017 deferred.
-- The program_coverage_gaps table itself is defined above, next to the share
-- check that reads it.
-- ============================================================================

-- Removes a participant mid-term with no replacement - the case
-- correct_program_participant() cannot express, because it always inserts a
-- successor row and a removal has none.
--
-- The close-out half is character-for-character the same shape as
-- correct_program_participant()'s: FOR UPDATE lock, transaction-local
-- superseding flag, and the GREATEST()-based bound so that a removal_date at
-- or before the row's own start empties the row rather than asking for an
-- inverted range (ADR 0016 addendum 3's fix, reused rather than re-derived -
-- writing `tstzrange(lower(v_old_range), p_removal_date)` here would
-- reintroduce exactly the bug that addendum closed).
--
-- The gap row is inserted in the same transaction and that ordering is
-- load-bearing: the share-sum trigger is DEFERRABLE INITIALLY DEFERRED and
-- fires at commit, so by the time it looks for an unresolved gap the INSERT
-- below is visible to it. A caller who closed the row in one transaction and
-- recorded the gap in the next would have the first transaction rejected.
CREATE OR REPLACE FUNCTION remove_program_participant(
  p_participant_id UUID,
  p_removal_date TIMESTAMPTZ,
  p_reason TEXT
) RETURNS UUID AS $$
DECLARE
  v_program_id UUID;
  v_old_range TSTZRANGE;
  v_gap_id UUID;
BEGIN
  SELECT program_id, effective_range INTO v_program_id, v_old_range
  FROM program_participants
  WHERE participant_id = p_participant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'remove_program_participant: participant % does not exist', p_participant_id;
  END IF;

  IF p_removal_date IS NULL THEN
    RAISE EXCEPTION 'PROGRAM_REMOVAL_DATE_REQUIRED: removing participant % requires a removal date', p_participant_id
      USING HINT = 'The removal date is what closes the outgoing row''s effective_range; there is no defensible default for it.';
  END IF;

  -- A gap row whose reason is blank is a gap nobody can act on later, and the
  -- whole mechanism rests on someone eventually acting on it.
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'PROGRAM_REMOVAL_REASON_REQUIRED: removing participant % requires a non-empty reason', p_participant_id
      USING HINT = 'The reason is the only description of why this program is under-placed that resolve_program_coverage_gap() will ever show a reader.';
  END IF;

  PERFORM set_config('luxauto.superseding_participant', 'on', true);
  UPDATE program_participants
  SET effective_range = tstzrange(lower(v_old_range),
                                  GREATEST(lower(v_old_range), p_removal_date))
  WHERE participant_id = p_participant_id;
  PERFORM set_config('luxauto.superseding_participant', 'off', true);

  INSERT INTO program_coverage_gaps (program_id, participant_id_removed, removal_date, reason)
  VALUES (v_program_id, p_participant_id, p_removal_date, p_reason)
  RETURNING gap_id INTO v_gap_id;

  RETURN v_gap_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Closes a gap, refusing while the panel it excuses is still under-placed.
--
-- The check is the point of the function. Without it, "resolved" would be a
-- flag anyone could set on a still-broken program, and the consequence would
-- land on whoever made the *next* unrelated write to that panel - they would
-- get PROGRAM_SHARES_NOT_100_AT_INSTANT for a hole somebody else left, with
-- no indication of where it came from. Raising here puts the failure in front
-- of the person holding the context.
--
-- Only the share math is checked, not whether this is the program's last open
-- gap: two removals can be recorded separately and closed by one panel
-- rebuild, and the second resolve call should not fail merely because the
-- first row is still open. Over-100% is deliberately not checked either - an
-- overlap is a hard block on every write to the panel already, and it is not
-- this gap's business.
CREATE OR REPLACE FUNCTION resolve_program_coverage_gap(
  p_gap_id UUID,
  p_resolution_note TEXT
) RETURNS VOID AS $$
DECLARE
  v_program_id UUID;
  v_resolved BOOLEAN;
  v_gap RECORD;
BEGIN
  SELECT program_id, resolved INTO v_program_id, v_resolved
  FROM program_coverage_gaps
  WHERE gap_id = p_gap_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'resolve_program_coverage_gap: gap % does not exist', p_gap_id;
  END IF;

  IF v_resolved THEN
    RAISE EXCEPTION 'PROGRAM_COVERAGE_GAP_ALREADY_RESOLVED: gap % is already resolved', p_gap_id;
  END IF;

  SELECT * INTO v_gap FROM program_share_gaps(v_program_id)
  WHERE direction = 'under'
  ORDER BY bad_instant
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'PROGRAM_COVERAGE_GAP_STILL_UNPLACED: cannot resolve gap % - program % risk-bearing shares still total % percent as of %',
      p_gap_id, v_program_id, v_gap.total_share, v_gap.bad_instant
      USING HINT = 'Rebuild the panel to 100 percent at every instant of the program term first (add a replacement participant, or extend an existing one), then resolve the gap. Marking it resolved now would push the failure onto the next unrelated write to this program.';
  END IF;

  UPDATE program_coverage_gaps
  SET resolved = true,
      resolved_at = now(),
      resolution_note = p_resolution_note
  WHERE gap_id = p_gap_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ADR 0017 named this as an open item and left it: the share check lives on
-- program_participants and never fires for a write to insurance_programs, so
-- shortening a program's term silently stranded its whole panel outside it.
-- Reproduced against luxauto-pg before this trigger was written.
--
-- Hard block, no repair. Auto-truncating the participant rows to fit would be
-- this schema editing capacity agreements to make a statement succeed, and
-- auto-closing them would invent a removal date nobody chose. The caller
-- closes or adjusts participation first - remove_program_participant() or
-- correct_program_participant() - and then shortens the term.
--
-- Widening needs no special case for *containment* and gets none: containment
-- against a superset is satisfied by every row that was contained in the
-- subset, so a widen finds nothing to strand. Tested, not assumed.
--
-- ADR 0021 addendum: but widening does stretch the window the 100% share rule
-- is evaluated over, and the share check lives on program_participants and
-- never fires for a write to this table. ADR 0021 shipped that as a named open
-- item; the addendum closes it here. A term change that exposes instants the
-- old term did not cover now evaluates the share rule against the incoming
-- range and, if the newly reachable stretch is under-placed, opens a
-- program_coverage_gaps row in the same transaction rather than blocking.
--
-- Blocking was rejected: the panel is not wrong, the term is simply longer
-- than the panel currently reaches, and that is a normal thing to do while a
-- renewal is being placed. Leaving it untracked was the bug. Opening the gap
-- makes the state exactly the state a deliberate mid-term removal produces,
-- which the rest of ADR 0021 already knows how to reason about.
CREATE OR REPLACE FUNCTION check_program_term_contains_participants()
RETURNS TRIGGER AS $$
DECLARE
  v_offenders TEXT;
  v_count INTEGER;
  v_gap RECORD;
  v_open_gaps INTEGER;
BEGIN
  SELECT count(*),
         string_agg(format('%s (%s) effective %s',
                           participant_name, participant_type, effective_range),
                    '; ' ORDER BY participant_name)
  INTO v_count, v_offenders
  FROM program_participants
  WHERE program_id = NEW.program_id
    AND NOT (effective_range <@ NEW.effective_range);

  IF v_count > 0 THEN
    RAISE EXCEPTION 'PROGRAM_TERM_STRANDS_PARTICIPANT: changing program % term from % to % would leave % participant row(s) outside it: %',
      NEW.program_id, OLD.effective_range, NEW.effective_range, v_count, v_offenders
      USING HINT = 'A participant cannot bear risk when the program is not in force. Close or adjust the participant rows first - remove_program_participant() for a departure, correct_program_participant() for a shortened participation - then change the program term.';
  END IF;

  -- Does the incoming term reach any instant the outgoing one did not?
  --
  -- `NOT (NEW <@ OLD)` is the whole test, and it is not the same as "the
  -- upper bound went up". Two cases break the bound-comparison version, both
  -- reproduced before this was written:
  --   * a lower-bound-only extension - [2026-06,2027-01) -> [2026-01,2027-01)
  --     leaves upper() identical while exposing six months;
  --   * a shift - [2026-01,2027-01) -> [2026-06,2027-06) - where neither
  --     range contains the other, so `OLD <@ NEW` is false too, yet five
  --     months at the top end are newly reachable.
  -- Containment is what "exposes new instants" actually means for a range
  -- type, so the range operator states it directly instead of a pair of
  -- bound comparisons that have to be got right in both directions. A pure
  -- narrow satisfies NEW <@ OLD and is skipped: every instant it keeps was
  -- already inside the old term and already checked.
  IF NOT (NEW.effective_range <@ OLD.effective_range) THEN
    SELECT * INTO v_gap
    FROM program_share_gaps(NEW.program_id, NEW.effective_range)
    WHERE direction = 'under'
    ORDER BY bad_instant
    LIMIT 1;

    -- Filtered to 'under' deliberately. An 'over' finding here is reachable -
    -- the participants sum check is DEFERRABLE INITIALLY DEFERRED, so an
    -- overlapping row inserted earlier in this same transaction is visible to
    -- this BEFORE trigger while its own check is still pending - and it must
    -- not be touched. Over-100% is a hard block everywhere else in the
    -- schema, and silently opening a gap row for one would make a term change
    -- the single way to suppress an overlap. Left alone, the deferred check
    -- raises on it at commit exactly as it always does.
    IF FOUND THEN
      -- Suppression is per-program and coarse (ADR 0021 section 1), so one
      -- open row already covers this program's whole timeline; a second would
      -- be noise and an extra thing for someone to resolve. Resolving is
      -- still safe, because resolve_program_coverage_gap() re-evaluates the
      -- share math fresh and refuses while any hole remains.
      SELECT count(*) INTO v_open_gaps
      FROM program_coverage_gaps
      WHERE program_id = NEW.program_id AND NOT resolved;

      IF v_open_gaps = 0 THEN
        -- participant_id_removed stays NULL: no participant left. This is the
        -- case ADR 0021 made that column nullable for, arriving sooner than
        -- that ADR expected it to.
        INSERT INTO program_coverage_gaps (program_id, participant_id_removed, removal_date, reason)
        VALUES (NEW.program_id, NULL, v_gap.bad_instant,
                format('program term widened from %s to %s; risk-bearing shares total %s percent at %s',
                       OLD.effective_range, NEW.effective_range,
                       v_gap.total_share, v_gap.bad_instant));

        RAISE NOTICE 'PROGRAM_TERM_WIDENED_GAP_OPENED: program % term now reaches % where shares total % percent; opened a program_coverage_gaps row rather than blocking the term change',
          NEW.program_id, v_gap.bad_instant, v_gap.total_share;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- WHEN clause rather than an early RETURN inside the function: a program's
-- name or estimated premium changing is not this trigger's business, and the
-- condition belongs where the reader looks for it.
CREATE OR REPLACE TRIGGER insurance_programs_term_check
  BEFORE UPDATE ON insurance_programs
  FOR EACH ROW
  WHEN (NEW.effective_range IS DISTINCT FROM OLD.effective_range)
  EXECUTE FUNCTION check_program_term_contains_participants();

-- Adds a participant and restates the shares of existing ones in a single
-- call, so the deferred share check judges the finished panel once instead of
-- rejecting each intermediate state.
--
-- **Every target share is an explicit input.** No proportional scaling, no
-- equal split, no residual-to-the-largest-participant rule. This project ships
-- undecided business formulas as mechanism and refuses to guess the numbers -
-- the same treatment profit_commission_formula got in ADR 0007 (free text
-- pending sign-off) and short-rate cancellation got in ADR 0018 (a factor
-- table that starts empty and raises rather than assuming a curve). How a
-- panel dilutes to make room for a new reinsurer is a negotiated commercial
-- outcome, not arithmetic this schema can derive.
--
-- Parallel arrays rather than a composite type: this schema has never defined
-- a composite (every CREATE TYPE in it is an enum), and one row shape used by
-- one function is a thin reason to introduce the first. The lengths are
-- checked, which is the only thing the composite would have bought.
--
-- On reusing correct_program_participant() rather than adding a share-only
-- variant: its signature *is* awkward for a share change - a direct caller
-- must resupply type, name, commission and formula or silently null them, and
-- it rejects a null name or type outright (PROGRAM_PARTICIPANT_IDENTITY_REQUIRED).
-- But this function has already read the outgoing row to find its end date, so
-- forwarding those four columns is free here, and a second supersession path
-- would be a second place for the append-only discipline to drift. Reused.
--
-- The adjusted rows take their new share from the instant the incoming
-- participant starts, and keep whatever end date they already had. That is a
-- mechanism choice, not an invented number: "add a participant and adjust the
-- others" only has one coherent changeover instant, and moving anyone's end
-- date would be a second, unrequested decision.
CREATE OR REPLACE FUNCTION add_program_participant_with_reallocation(
  p_program_id UUID,
  p_participant_type participant_type_t,
  p_participant_name TEXT,
  p_share_percentage NUMERIC,
  p_commission_rate NUMERIC,
  p_profit_commission_formula TEXT,
  p_effective_range TSTZRANGE,
  p_adjust_participant_ids UUID[] DEFAULT '{}',
  p_adjust_new_shares NUMERIC[] DEFAULT '{}'
) RETURNS UUID AS $$
DECLARE
  v_new_id UUID;
  v_n INTEGER;
  v_i INTEGER;
  v_pid UUID;
  v_share NUMERIC;
  v_old RECORD;
  v_start TIMESTAMPTZ;
BEGIN
  IF p_adjust_participant_ids IS NULL OR p_adjust_new_shares IS NULL THEN
    RAISE EXCEPTION 'PROGRAM_REALLOCATION_MALFORMED: pass empty arrays, not NULL, when no existing participant is being adjusted';
  END IF;

  -- array_length of an empty array is NULL, not 0, so both sides are
  -- coalesced before they are compared.
  v_n := COALESCE(array_length(p_adjust_participant_ids, 1), 0);
  IF v_n <> COALESCE(array_length(p_adjust_new_shares, 1), 0) THEN
    RAISE EXCEPTION 'PROGRAM_REALLOCATION_MALFORMED: % participant id(s) but % share(s) - each adjusted participant needs exactly one target share',
      v_n, COALESCE(array_length(p_adjust_new_shares, 1), 0);
  END IF;

  IF p_effective_range IS NULL OR isempty(p_effective_range) OR lower(p_effective_range) IS NULL THEN
    RAISE EXCEPTION 'PROGRAM_REALLOCATION_MALFORMED: the incoming participant needs an effective_range with a bounded start - it is the instant every adjusted share changes at';
  END IF;
  v_start := lower(p_effective_range);

  FOR v_i IN 1 .. v_n LOOP
    v_pid := p_adjust_participant_ids[v_i];
    v_share := p_adjust_new_shares[v_i];

    SELECT program_id, participant_type, participant_name, commission_rate,
           profit_commission_formula, effective_range
    INTO v_old
    FROM program_participants
    WHERE participant_id = v_pid;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'add_program_participant_with_reallocation: participant % does not exist', v_pid;
    END IF;

    IF v_old.program_id <> p_program_id THEN
      RAISE EXCEPTION 'PROGRAM_REALLOCATION_WRONG_PROGRAM: participant % belongs to program %, not %',
        v_pid, v_old.program_id, p_program_id;
    END IF;

    -- Without this the tstzrange() below would be asked for an inverted range
    -- and fail with a range-bounds error naming neither participant.
    IF upper(v_old.effective_range) IS NOT NULL AND upper(v_old.effective_range) <= v_start THEN
      RAISE EXCEPTION 'PROGRAM_REALLOCATION_ALREADY_ENDED: participant % (%) ends at %, at or before the incoming participant starts (%) - there is no remaining period to reallocate',
        v_old.participant_name, v_pid, upper(v_old.effective_range), v_start;
    END IF;

    PERFORM correct_program_participant(
      v_pid,
      tstzrange(v_start, upper(v_old.effective_range)),
      v_old.participant_type,
      v_old.participant_name,
      v_share,
      v_old.commission_rate,
      v_old.profit_commission_formula
    );
  END LOOP;

  INSERT INTO program_participants (
    program_id, participant_type, participant_name, share_percentage,
    commission_rate, profit_commission_formula, effective_range
  )
  VALUES (
    p_program_id, p_participant_type, p_participant_name, p_share_percentage,
    p_commission_rate, p_profit_commission_formula, p_effective_range
  )
  RETURNING participant_id INTO v_new_id;

  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- No GRANTs for any of the above, and none for program_coverage_gaps. ADR
-- 0017 withheld them from program_participants on the grounds that a grant
-- with no consumer is only extra reachable surface, and nothing has changed:
-- there is still no Odoo model over either table. Gaps are opened and
-- resolved through psql by whoever is doing the panel work, exactly as
-- participant corrections are today. Named as an open item in ADR 0021.

-- ============================================================================
-- QUOTES
-- Pins the exact state_rating_table_versions record used, so a later rate
-- change never silently re-rates an already-issued quote (see that table's
-- own comment, and the registry schema's "how_this_is_used" item 6).
-- ============================================================================

CREATE TABLE IF NOT EXISTS quotes (
  quote_id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                    UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  state_rating_table_record_id      UUID NOT NULL REFERENCES state_rating_table_versions(record_id),
  program_id                        UUID REFERENCES insurance_programs(program_id),  -- which capacity/
                                                                                        -- participant panel
                                                                                        -- this was written
                                                                                        -- under - see
                                                                                        -- ADR 0007
  premium_amount                    NUMERIC(12,2) NOT NULL,
  -- ADR 0007 addendum: broker + MGA acquisition commission on gross premium,
  -- decided at quote time and inherited by the bound policy via quote_id, the
  -- same way premium_amount is. Rates are PERCENTAGES (matching
  -- program_participants.commission_rate, which the waterfall divides by 100),
  -- not fractions. broker_channel is required - every placement legally goes
  -- through one broker channel. mga_commission_rate is GENERATED, never
  -- independently set: it fills the remainder under the 30% combined ceiling, so
  -- broker + MGA = 30 is a schema fact; the 15% broker ceiling is the CHECK.
  broker_channel                    broker_channel_t NOT NULL,
  broker_commission_rate            NUMERIC(5,2) NOT NULL
                                      CONSTRAINT quotes_broker_commission_rate_ck
                                      CHECK (broker_commission_rate >= 0 AND broker_commission_rate <= 15),
  mga_commission_rate               NUMERIC(5,2) GENERATED ALWAYS AS (30 - broker_commission_rate) STORED,
  rating_basis                      JSONB NOT NULL,  -- which permitted variables/values drove the
                                                         -- price - the per-quote decision-log
                                                         -- attachment referenced in the registry schema
  status                            TEXT NOT NULL DEFAULT 'draft'
                                       CHECK (status IN ('draft', 'issued', 'bound', 'expired', 'declined')),
  -- ADR 0030: who created the quote. A normal audit column, the same provenance
  -- every other write path records (policy_cancellations.performed_by,
  -- policy_reinstatements.performed_by): create_quote() persists its
  -- p_performed_by here. Added by ALTER too (below) so it lands on an already-
  -- created quotes table, same idiom as the ADR 0007 addendum's broker columns.
  quoted_by                         TEXT NOT NULL,
  quoted_at                         TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at                        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_quotes_application ON quotes(application_id);
CREATE INDEX IF NOT EXISTS idx_quotes_program ON quotes(program_id);

-- ADR 0007 addendum, idempotent apply against an already-created quotes table:
-- on a fresh apply the CREATE TABLE above carries these columns; on an existing
-- database the CREATE TABLE IF NOT EXISTS is a no-op, so they arrive by ALTER.
-- Added nullable first, then SET NOT NULL under a guard - the same discipline as
-- the ADR 0016 addendum's vin/identity columns: quotes is empty today, but the
-- schema checks rather than assumes, and refuses with a clear message rather
-- than a bare NOT NULL violation if a real quote ever lacks a channel/rate. The
-- CHECK is guarded by a pg_constraint lookup because ADD CONSTRAINT is not
-- idempotent; the inline CONSTRAINT above carries the same name, so a fresh
-- apply adds it once, not twice.
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS broker_channel broker_channel_t;
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS broker_commission_rate NUMERIC(5,2);
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS mga_commission_rate NUMERIC(5,2)
  GENERATED ALWAYS AS (30 - broker_commission_rate) STORED;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'quotes_broker_commission_rate_ck'
      AND conrelid = 'quotes'::regclass
  ) THEN
    ALTER TABLE quotes
      ADD CONSTRAINT quotes_broker_commission_rate_ck
      CHECK (broker_commission_rate >= 0 AND broker_commission_rate <= 15);
  END IF;
END $$;
DO $$
DECLARE v_missing INTEGER;
BEGIN
  SELECT count(*) INTO v_missing
  FROM quotes WHERE broker_channel IS NULL OR broker_commission_rate IS NULL;
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'ADR 0007 addendum: cannot enforce NOT NULL on quote broker commission - % quotes row(s) have a null broker_channel or broker_commission_rate',
      v_missing
      USING HINT = 'Every placement legally requires a broker channel and rate. Supply broker_channel and broker_commission_rate for these quotes, then re-run this file. This schema will not invent a channel or a rate to make itself apply.';
  END IF;
  ALTER TABLE quotes ALTER COLUMN broker_channel SET NOT NULL;
  ALTER TABLE quotes ALTER COLUMN broker_commission_rate SET NOT NULL;
END $$;

-- ADR 0030: quoted_by, the quote-creation audit column, on an already-created
-- quotes table. Same discipline as the broker columns above - ADD nullable, then
-- SET NOT NULL under a guard that fails loud rather than inventing a creator for
-- a pre-existing row that lacks one. quotes is empty today, so this applies
-- cleanly; a real row without a creator would refuse with a clear message.
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS quoted_by TEXT;
DO $$
DECLARE v_missing INTEGER;
BEGIN
  SELECT count(*) INTO v_missing FROM quotes WHERE quoted_by IS NULL;
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'ADR 0030: cannot enforce NOT NULL on quotes.quoted_by - % row(s) have a null quoted_by', v_missing
      USING HINT = 'Every quote records who created it. Backfill quoted_by for these rows, then re-run this file. This schema will not invent a creator to make itself apply.';
  END IF;
  ALTER TABLE quotes ALTER COLUMN quoted_by SET NOT NULL;
END $$;

-- ============================================================================
-- QUOTE CREATION (ADR 0030)
-- The first real write path into quotes. Until now a quote was only ever
-- INSERTed by test fixtures; ADR 0028 built compute_indicative_premium() and
-- named quotes.premium_amount / quotes.rating_basis as its destination, but
-- nothing called it on quote creation, so every real quote's rating view read
-- all-NULL. This wires the two together.
--
-- A thin composition, the same idiom as bind_policy / reinstate_policy: it does
-- NOT reimplement rating. compute_indicative_premium() remains the single source
-- of both the premium and the breakdown, and its own guards are surfaced
-- unchanged rather than duplicated here - a below-floor risk
-- (RATING_BELOW_AGREED_VALUE_FLOOR), an unmapped category
-- (RATING_CLASS_NOT_CONFIGURED_FOR_CATEGORY) and - the resolved failure mode -
-- an unconfigured territory (TERRITORY_FACTOR_NOT_CONFIGURED) each propagate out
-- of this function and NO quote row is written. Fail-loud, no partial state: the
-- same discipline short_rate_factor() and territory_factor() already follow, and
-- consistent with the FK to state_rating_table_versions that already blocks a
-- quote for an un-onboarded state. A state is not ready for quoting until BOTH
-- its state_rating_table_versions row AND its territory_factors row exist (ADR
-- 0030): this function is where that second, previously-implicit precondition
-- becomes observable.
--
-- Single vehicle only. Rating v1 is explicitly single-vehicle (ADR 0028), and a
-- quote reaches vehicle data only through its application (1:N). Zero or 2+
-- vehicles fail loud rather than pick one silently or aggregate (aggregation is
-- deferred out of v1) - QUOTE_RATING_MULTI_VEHICLE_UNSUPPORTED / _NO_VEHICLE.
--
-- p_agreed_value for the rating call is the vehicle's current_appraised_value:
-- there is no separate numeric agreed-value column (agreed_value_requested is a
-- boolean flag), and this is the same value ADR 0028's tests and evaluate_el01()
-- already use. The state driving the territory lookup is the vehicle's
-- garaging_state (== applications.garaging_state, which is keyed off it).
--
-- Scope note: this pass wires RATING only. The referral engine
-- (evaluate_application_referrals / evaluate_el01 and the rest) is also unwired
-- in production and is a separate follow-up - referral evaluation belongs at
-- application submission, a different moment than quote creation. Until that
-- lands, EL-01's audited below-floor decline does not fire; only
-- compute_indicative_premium()'s own hard RATING_BELOW_AGREED_VALUE_FLOOR guard
-- protects quote creation, which is sufficient to stop a below-floor quote here.
--
-- The created quote is 'issued' (rated and bindable): ADR 0028 frames a clean
-- rated risk as final and bindable, bind_policy() requires 'issued', and there
-- is no separate issue step - creating it 'draft' would strand it with nothing
-- able to advance or bind it. A later draft->issued acceptance lifecycle, if
-- ever wanted, is a separate concern.
--
-- p_performed_by is persisted into quotes.quoted_by, the same provenance every
-- other write function records (cancel_policy/reinstate_policy's performed_by) -
-- an accepted-but-discarded argument would be a real inconsistency, so the column
-- carries it rather than the function dropping it (ADR 0030).
CREATE OR REPLACE FUNCTION create_quote(
  p_application_id UUID,
  p_broker_channel broker_channel_t,
  p_broker_commission_rate NUMERIC,
  p_state_rating_table_record_id UUID,
  p_program_id UUID,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_garaging_state CHAR(2);
  v_vehicle_count INT;
  v_category vehicle_category_t;
  v_appraised NUMERIC;
  v_veh_state CHAR(2);
  v_premium NUMERIC;
  v_basis JSONB;
  v_quote_id UUID;
  v_referral referral_action_t;
BEGIN
  SELECT garaging_state INTO v_garaging_state
  FROM applications WHERE application_id = p_application_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'QUOTE_APPLICATION_NOT_FOUND: application % does not exist', p_application_id;
  END IF;

  -- Referral gate (ADR 0031). An automatic, bindable quote may only be produced
  -- for an application the referral engine has cleared. The taxonomy permits it
  -- for AUTO_PROCEED and AUTO_PROCEED_WITH_FLAG (the latter is explicitly "not
  -- blocking"); INFORMATION_REQUEST and up route to a human before any quote is
  -- issued. decision_log is the sole source of truth (never applications.status),
  -- read via current_referral_action() - the latest-per-rule disposition, so it
  -- reflects the most recent evaluation.
  v_referral := current_referral_action(p_application_id);
  IF v_referral IS NULL THEN
    RAISE EXCEPTION 'QUOTE_APPLICATION_NOT_EVALUATED: application % has no referral evaluation - submit it (submit_application) before quoting', p_application_id
      USING HINT = 'create_quote requires the referral engine to have cleared the application first (ADR 0031).';
  END IF;
  IF v_referral > 'AUTO_PROCEED_WITH_FLAG'::referral_action_t THEN
    -- ADR 0032: a flagged application may still be quoted if a human underwriter
    -- has recorded a valid supervised override (authorize_referral_override).
    -- HARD_DECLINE_COMPLIANCE is never overridable - stated explicitly here as
    -- well as being un-insertable in referral_overrides (belt and suspenders).
    IF v_referral = 'HARD_DECLINE_COMPLIANCE'::referral_action_t THEN
      RAISE EXCEPTION 'QUOTE_APPLICATION_COMPLIANCE_DECLINE: application % is a HARD_DECLINE_COMPLIANCE (sanctions/compliance) decline and can never be quoted, by anyone', p_application_id
        USING HINT = 'No override applies to a compliance decline (ADR 0032); this is structurally enforced, not a policy.';
    END IF;
    -- A valid override must match BOTH the current disposition and the current
    -- evaluation (evaluated_at) - so a re-evaluation invalidates a stale override.
    IF NOT EXISTS (
      SELECT 1 FROM referral_overrides o
      WHERE o.application_id = p_application_id
        AND o.overridden_action = v_referral
        AND o.evaluated_at = current_referral_evaluated_at(p_application_id)
    ) THEN
      RAISE EXCEPTION 'QUOTE_APPLICATION_NOT_CLEAR_TO_QUOTE: application % referral disposition is % - not eligible for an automatic bindable quote', p_application_id, v_referral
        USING HINT = 'The application is flagged for a human underwriter; a senior/standard underwriter can supervise-release it via authorize_referral_override (ADR 0032). See decision_log for the reason codes.';
    END IF;
    -- A valid supervised override is present - proceed to rate and quote.
  END IF;

  -- Single-vehicle only (ADR 0028 v1 scope). Fail loud on 0 or 2+.
  SELECT count(*) INTO v_vehicle_count FROM vehicles WHERE application_id = p_application_id;
  IF v_vehicle_count = 0 THEN
    RAISE EXCEPTION 'QUOTE_RATING_NO_VEHICLE: application % has no vehicle to rate', p_application_id
      USING HINT = 'A quote is rated from exactly one vehicle in v1; this application has none.';
  ELSIF v_vehicle_count > 1 THEN
    RAISE EXCEPTION 'QUOTE_RATING_MULTI_VEHICLE_UNSUPPORTED: application % has % vehicles; rating v1 rates exactly one', p_application_id, v_vehicle_count
      USING HINT = 'Multi-vehicle aggregation is deferred out of rating v1 (ADR 0028). Rate manually.';
  END IF;

  SELECT vehicle_category, current_appraised_value, garaging_state
    INTO v_category, v_appraised, v_veh_state
  FROM vehicles WHERE application_id = p_application_id;

  -- Thin call: the number and the breakdown both come from here, and every one
  -- of this function's guards propagates out un-caught (below-floor, unmapped
  -- category, unconfigured territory) - no quote is written when it raises.
  SELECT indicative_premium, breakdown INTO v_premium, v_basis
  FROM compute_indicative_premium(v_category, v_appraised, v_veh_state);

  -- rating_basis stored verbatim - no reshaping. The ADR 0029 rating view reads
  -- exactly the v1 keys this breakdown carries.
  INSERT INTO quotes (
    application_id, state_rating_table_record_id, program_id,
    premium_amount, rating_basis, status,
    broker_channel, broker_commission_rate, quoted_by
  ) VALUES (
    p_application_id, p_state_rating_table_record_id, p_program_id,
    v_premium, v_basis, 'issued',
    p_broker_channel, p_broker_commission_rate, p_performed_by
  ) RETURNING quote_id INTO v_quote_id;

  RETURN v_quote_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- POLICIES (ADR 0010)
-- The result of binding a quote - one policy per bound quote, enforced by the
-- UNIQUE constraint on quote_id below. quotes.status transitions to 'bound'
-- in the same transaction that inserts this row (the bind server action -
-- ADR 0010 section 4), so a policy's existence and its quote's 'bound' status
-- are set together, not independently. Endorsements (mid-term changes to an
-- already-bound policy) are explicitly out of scope for this table - see
-- ADR 0010's own note and the follow-on ADR it calls for.
-- ============================================================================

CREATE TABLE IF NOT EXISTS policies (
  policy_id                         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  quote_id                          UUID NOT NULL UNIQUE REFERENCES quotes(quote_id),
  policy_number                     TEXT,
  effective_range                   TSTZRANGE NOT NULL,
  status                            policy_status_t NOT NULL DEFAULT 'active',
  -- ADR 0023: the ">14-day" reinstatement path. A policy reinstated more than
  -- 14 days after a prior policy's cancellation is genuine NEW business (a
  -- permanent coverage gap means it is not a reversal), bound through the
  -- ordinary flow - so it is a normal policies row that additionally points
  -- back at the cancelled policy it succeeds, for traceability. Nullable
  -- (most policies have no predecessor) and set once, by link_reinstated_policy()
  -- after bind - NOT the append-only correction machinery used for
  -- endorsements/participants, because "which policy this one reinstated" is a
  -- single immutable fact, not a corrected temporal one. The self-reference
  -- CHECK is a cheap guard against the most obvious linking mistake; it does
  -- NOT (and cannot) prove the target is really a predecessor - that is
  -- link_reinstated_policy()'s job.
  reinstated_from_policy_id         UUID REFERENCES policies(policy_id),
  -- ADR 0033 renewal linkage. renewed_from_policy_id is the IMMEDIATE
  -- predecessor (distinct from reinstated_from_policy_id: renewal is a
  -- successive term, reinstatement is restored coverage after a lapse - kept
  -- separable at the schema level). original_policy_id is the chain HEAD,
  -- denormalized so cumulative tenure is an O(1) lookup rather than an
  -- unbounded walk back through renewed_from_policy_id (a 20-year annually-
  -- renewed policy would be 20 hops). NULL on an original; contiguous terms
  -- mean the head's inception -> now is the continuous time with the carrier.
  -- renewal_generation is 0 on an original, +1 each renewal - cheap "how many
  -- terms" for audit/display without walking the chain. All set once at
  -- renewal by renew_policy(), never superseded, same as reinstated_from.
  renewed_from_policy_id            UUID REFERENCES policies(policy_id),
  original_policy_id                UUID REFERENCES policies(policy_id),
  renewal_generation                INTEGER NOT NULL DEFAULT 0,
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT policies_no_self_reinstatement
    CHECK (reinstated_from_policy_id IS NULL OR reinstated_from_policy_id <> policy_id),
  CONSTRAINT policies_no_self_renewal
    CHECK (renewed_from_policy_id IS NULL OR renewed_from_policy_id <> policy_id),
  CONSTRAINT policies_original_not_self
    CHECK (original_policy_id IS NULL OR original_policy_id <> policy_id)
);

CREATE INDEX IF NOT EXISTS idx_policies_quote ON policies(quote_id);
CREATE INDEX IF NOT EXISTS idx_policies_status ON policies(status);

-- ADR 0023, idempotent apply against an already-created policies table (the
-- CREATE TABLE IF NOT EXISTS above is a no-op there, so the new column and
-- CHECK have to be added by ALTER too - same fresh-apply-plus-existing-DB
-- pattern as no_overlapping_program_participants). ADD COLUMN IF NOT EXISTS is
-- idempotent on its own; the CHECK is guarded by a pg_constraint lookup because
-- ADD CONSTRAINT is not. This MUST run before idx_policies_reinstated_from
-- below: on an existing database the column does not exist until this ALTER
-- adds it, and an index over a not-yet-existing column would fail there (it
-- did, on the first apply to the live server - fixed by this ordering).
ALTER TABLE policies ADD COLUMN IF NOT EXISTS reinstated_from_policy_id UUID REFERENCES policies(policy_id);
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'policies_no_self_reinstatement'
      AND conrelid = 'policies'::regclass
  ) THEN
    ALTER TABLE policies
      ADD CONSTRAINT policies_no_self_reinstatement
      CHECK (reinstated_from_policy_id IS NULL OR reinstated_from_policy_id <> policy_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_policies_reinstated_from ON policies(reinstated_from_policy_id);

-- ADR 0033 renewal columns, idempotent apply against an already-created policies
-- table (same fresh-apply-plus-existing-DB pattern as reinstated_from above).
ALTER TABLE policies ADD COLUMN IF NOT EXISTS renewed_from_policy_id UUID REFERENCES policies(policy_id);
ALTER TABLE policies ADD COLUMN IF NOT EXISTS original_policy_id UUID REFERENCES policies(policy_id);
ALTER TABLE policies ADD COLUMN IF NOT EXISTS renewal_generation INTEGER NOT NULL DEFAULT 0;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'policies_no_self_renewal' AND conrelid = 'policies'::regclass) THEN
    ALTER TABLE policies ADD CONSTRAINT policies_no_self_renewal
      CHECK (renewed_from_policy_id IS NULL OR renewed_from_policy_id <> policy_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'policies_original_not_self' AND conrelid = 'policies'::regclass) THEN
    ALTER TABLE policies ADD CONSTRAINT policies_original_not_self
      CHECK (original_policy_id IS NULL OR original_policy_id <> policy_id);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_policies_renewed_from ON policies(renewed_from_policy_id);
CREATE INDEX IF NOT EXISTS idx_policies_original ON policies(original_policy_id);

-- Cumulative tenure with the carrier, in years, as of a given instant (ADR 0033).
-- Contiguous renewals mean the CHAIN HEAD's inception -> as_of is the continuous
-- time on risk, so this resolves the head (original_policy_id, or self on an
-- original) and measures from its inception. O(1) via the denormalized head - no
-- walk back through renewed_from_policy_id. This is what finally makes
-- nonrenewal_notice_requirements.min_policy_years reachable (a single policy's
-- own age is always < 1 year). Returns NULL for a policy that does not exist.
CREATE OR REPLACE FUNCTION policy_tenure_years(p_policy_id UUID, p_as_of TIMESTAMPTZ)
RETURNS NUMERIC AS $$
  SELECT EXTRACT(EPOCH FROM (p_as_of - lower(head.effective_range))) / (365.25 * 86400)
  FROM policies self
  JOIN policies head ON head.policy_id = COALESCE(self.original_policy_id, self.policy_id)
  WHERE self.policy_id = p_policy_id;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- POLICY EVENTS (ADR 0010)
-- Append-only audit trail for policy lifecycle actions (bind, cancel, and
-- later renewal/endorsement events once those are designed). Kept separate
-- from decision_log, which is shaped around referral-rule firings against an
-- application (rule_id, action_taken against referral_action_t) and doesn't
-- fit a policy lifecycle event without weakening that shape - see ADR 0010
-- section 4 for the full "why a new table, not a widened decision_log"
-- rationale. Same append-only discipline as decision_log: no UPDATE, no
-- DELETE, ever - a mistaken entry gets corrected with a new row referencing
-- the old one in notes, not by editing history.
-- ============================================================================

CREATE TABLE IF NOT EXISTS policy_events (
  event_id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id                         UUID NOT NULL REFERENCES policies(policy_id) ON DELETE CASCADE,
  event_type                        TEXT NOT NULL,             -- e.g. 'bound', 'cancelled'
  performed_by                      TEXT NOT NULL,             -- 'system' or a specific user identifier
  notes                             TEXT,
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_policy_events_policy ON policy_events(policy_id);

CREATE OR REPLACE FUNCTION reject_policy_events_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'policy_events is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER policy_events_no_update
  BEFORE UPDATE ON policy_events
  FOR EACH ROW EXECUTE FUNCTION reject_policy_events_mutation();

CREATE OR REPLACE TRIGGER policy_events_no_delete
  BEFORE DELETE ON policy_events
  FOR EACH ROW EXECUTE FUNCTION reject_policy_events_mutation();

-- ============================================================================
-- WATERFALL AND POLICY-LIFECYCLE WRITE FUNCTIONS (ADR 0010, ADR 0014)
-- Placed here, after quotes/policies/policy_events, rather than up near
-- program_participants where they originally lived: LANGUAGE sql functions
-- are parsed against the catalog at CREATE time (unlike plpgsql, which only
-- checks syntax until first call), so a function referencing quotes/policies/
-- policy_events genuinely cannot be created before those tables exist. That
-- original placement worked in every session that tested it only because
-- each one applied incremental changes to an already-populated database -
-- never a true fresh apply. Caught here, while adding ADR 0014's new
-- functions, by testing a fresh apply against an empty database
-- (schemas/db/ has no automated fresh-apply check yet - this is exactly the
-- kind of drift ADR 0011 flagged as a process gap). Fixed by moving these
-- functions after their dependencies instead of leaving the bug in place and
-- adding more functions with the same hazard on top of it.
-- ============================================================================

-- Commission waterfall (ADR 0010, refactored for ADR 0014): given a bound/
-- issued quote, compute each program participant's share of gross premium
-- and their net-due amount after their own commission_rate. Single source of
-- truth for every consumer - the Odoo Premium/Waterfall view, the settlement
-- report (ADR 0013), and now endorsements (ADR 0014) - all read this
-- function rather than each re-deriving the math. Computes only what the
-- schema currently models (a flat share_percentage and a single
-- commission_rate per participant) - does not resolve the layered
-- retail/wholesale broker commission tiers from the Energy manual's Ch.10
-- waterfall, or the still-free-text profit_commission_formula. See ADR
-- 0007's open items and ADR 0010's note on this function's scope.
--
-- SECURITY DEFINER, not the default SECURITY INVOKER: unlike a plain view
-- (which transparently runs with its owner's table privileges), a function
-- called from within a view does NOT inherit the view owner's rights - it
-- runs as whichever role actually queries it. The least-privilege `odoo`
-- Postgres role (ADR 0009) has no direct grant on quotes/program_participants
-- - only on the views. SECURITY DEFINER makes this function a controlled
-- read gateway, the same role a view already plays, without widening
-- `odoo`'s privileges to the base tables themselves. search_path is pinned
-- to close the standard SECURITY DEFINER search-path-injection gotcha.
--
-- ADR 0014 split the original single-argument function into this raw
-- (program_id, amount, as_of) overload - the actual arithmetic - plus two
-- thin entrypoints below that each resolve a different kind of row into
-- these three inputs and delegate to it: the original quote-based form, and
-- calculate_endorsement_waterfall() for an endorsement's premium_delta. The
-- math is written exactly once; a sibling function that recomputed it
-- independently would be the "two copies of the truth" problem this
-- function exists to avoid, just avoided for two callers and reintroduced
-- for a third.
CREATE OR REPLACE FUNCTION calculate_premium_waterfall(
  p_program_id UUID,
  p_amount NUMERIC,
  p_as_of TIMESTAMPTZ
)
RETURNS TABLE (
  participant_id      UUID,
  participant_name    TEXT,
  participant_type    participant_type_t,
  share_percentage    NUMERIC(5,2),
  commission_rate     NUMERIC(5,2),
  gross_share          NUMERIC(14,2),
  commission_amount    NUMERIC(14,2),
  net_due               NUMERIC(14,2)
) AS $$
  SELECT
    pp.participant_id,
    pp.participant_name,
    pp.participant_type,
    pp.share_percentage,
    pp.commission_rate,
    ROUND(p_amount * pp.share_percentage / 100, 2) AS gross_share,
    ROUND(p_amount * pp.share_percentage / 100
          * COALESCE(pp.commission_rate, 0) / 100, 2) AS commission_amount,
    ROUND(p_amount * pp.share_percentage / 100
          * (1 - COALESCE(pp.commission_rate, 0) / 100), 2) AS net_due
  FROM program_participants pp
  WHERE pp.program_id = p_program_id
    AND pp.effective_range @> p_as_of;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Original entrypoint: now a thin wrapper over the overload above. Same
-- signature, same behavior - luxauto_premium_waterfall_view and
-- luxauto_settlement_view keep working unchanged.
CREATE OR REPLACE FUNCTION calculate_premium_waterfall(p_quote_id UUID)
RETURNS TABLE (
  participant_id      UUID,
  participant_name    TEXT,
  participant_type    participant_type_t,
  share_percentage    NUMERIC(5,2),
  commission_rate     NUMERIC(5,2),
  gross_share          NUMERIC(14,2),
  commission_amount    NUMERIC(14,2),
  net_due               NUMERIC(14,2)
) AS $$
  SELECT w.*
  FROM quotes q
  CROSS JOIN LATERAL calculate_premium_waterfall(q.program_id, q.premium_amount, q.quoted_at) w
  WHERE q.quote_id = p_quote_id;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Bind and cancel (ADR 0010 section 4): the two policy-lifecycle actions that
-- must be atomic across policies/quotes/policy_events, and therefore can't be
-- Odoo's default ORM save. Implemented here rather than as raw multi-statement
-- SQL in an Odoo server action, for the same reason the waterfall math lives
-- here and not in Odoo Python (ADR 0010): one definition, callable from
-- anywhere that needs it, not re-derived per caller. SECURITY DEFINER with a
-- pinned search_path, same pattern as calculate_premium_waterfall (ADR 0012)
-- and for the same reason: `odoo` has no direct grant on policies, quotes, or
-- policy_events - only on the read-side views - and these functions are the
-- controlled gateway that lets `odoo` write to those tables without widening
-- that grant.
--
-- Both use SELECT ... FOR UPDATE on the row being checked, closing the gap
-- between "check the current state" and "act on it": without the row lock,
-- two concurrent calls could both pass the precondition check before either
-- commits. The UNIQUE constraint on policies.quote_id is the last line of
-- defense against a double-bind either way, but the explicit check here is
-- what turns that into a clear application-level error instead of a raw
-- constraint-violation message reaching the caller.
-- Extended for ADR 0016: also snapshots the application's vehicles and
-- additional_drivers into policy_vehicles/policy_drivers, atomically with
-- everything else. Signature unchanged; only the body grows.
-- Extended again by the ADR 0016 addendum: refuses to bind an application
-- whose vehicles/drivers are missing the identity fields the snapshot
-- tables' exclusion constraints key on (BIND_BLOCKED_MISSING_VEHICLE_VIN /
-- BIND_BLOCKED_MISSING_DRIVER_IDENTITY). Signature still unchanged.
-- ADR 0024: bind_policy() gains an optional inception date. NULL preserves the
-- original behaviour exactly (term starts at now()); a supplied date backdates
-- the whole term, which is what lets a reinstatement bound as new business close
-- the coverage gap (see reinstate_policy() below). This is the general
-- term-selection hook bind_policy() always flagged as an open item, not the
-- reinstatement-specific prior-policy reference ADR 0023 kept out of it.
--
-- A defaulted parameter OVERLOADS rather than replaces (Postgres keys functions
-- on their argument list), so the old three-argument bind_policy(quote, number,
-- by) call would become ambiguous between the two forms. The three-argument
-- form is DROPped first - the same idiom ADR 0021's addendum used for
-- program_share_gaps - so there is exactly one bind_policy() and existing
-- three-argument callers bind at now() through the default, unchanged.
DROP FUNCTION IF EXISTS bind_policy(UUID, TEXT, TEXT);
CREATE OR REPLACE FUNCTION bind_policy(
  p_quote_id UUID,
  p_policy_number TEXT,
  p_performed_by TEXT,
  p_inception_date TIMESTAMPTZ DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_quote_status TEXT;
  v_application_id UUID;
  v_policy_id UUID;
  v_inception TIMESTAMPTZ;
  v_effective_range TSTZRANGE;
  v_blocking_count INTEGER;
BEGIN
  SELECT status, application_id INTO v_quote_status, v_application_id
  FROM quotes
  WHERE quote_id = p_quote_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'bind_policy: quote % does not exist', p_quote_id;
  END IF;

  IF v_quote_status <> 'issued' THEN
    RAISE EXCEPTION 'bind_policy: quote % is not in issued status (current status: %)',
      p_quote_id, v_quote_status;
  END IF;

  IF EXISTS (SELECT 1 FROM policies WHERE quote_id = p_quote_id) THEN
    RAISE EXCEPTION 'bind_policy: quote % already has a policy', p_quote_id;
  END IF;

  -- ADR 0016 addendum: the snapshot columns below are NOT NULL, which is
  -- what actually closes the exclusion constraints' null-identity gap. That
  -- constraint alone would report a null VIN as a bare NOT NULL violation on
  -- policy_vehicles - technically correct, useless to whoever hit it. These
  -- two checks name the condition instead, and name it as a bind
  -- precondition rather than a snapshot mishap: DH-04 in
  -- luxury_auto_referral_matrix.json already routes an application missing a
  -- vin or driver identity to INFORMATION_REQUEST, so an application that
  -- reaches bind with either still null did not have that rule applied to
  -- it. Checked before the policies INSERT: nothing is written at all, so
  -- there is no partially-bound policy to clean up.
  SELECT count(*) INTO v_blocking_count
  FROM vehicles v
  WHERE v.application_id = v_application_id AND v.vin IS NULL;

  IF v_blocking_count > 0 THEN
    RAISE EXCEPTION 'BIND_BLOCKED_MISSING_VEHICLE_VIN: quote % cannot bind - % vehicle(s) on application % have a null vin',
      p_quote_id, v_blocking_count, v_application_id
      USING HINT = 'Referral matrix DH-04 (DH04_INSUFFICIENT_DATA_FOR_RISK_COMPUTATION) routes an application with a null vin to INFORMATION_REQUEST. Supply the VIN on the application, then bind.';
  END IF;

  SELECT count(*) INTO v_blocking_count
  FROM additional_drivers d
  WHERE d.application_id = v_application_id
    AND (d.name IS NULL OR d.date_of_birth IS NULL);

  IF v_blocking_count > 0 THEN
    RAISE EXCEPTION 'BIND_BLOCKED_MISSING_DRIVER_IDENTITY: quote % cannot bind - % additional driver(s) on application % have a null name or date_of_birth',
      p_quote_id, v_blocking_count, v_application_id
      USING HINT = 'Referral matrix DH-04 (DH04_INSUFFICIENT_DATA_FOR_RISK_COMPUTATION) routes an application with missing driver identity fields to INFORMATION_REQUEST. Supply the driver''s name and date of birth on the application, then bind.';
  END IF;

  -- effective_range: a standard one-year term. Inception defaults to now()
  -- (the ADR 0010 behaviour); a supplied p_inception_date backdates it - ADR
  -- 0024's backdated reinstatement pins it to the gap start. The vehicle/driver
  -- snapshots below inherit the same term through this variable. Premium is
  -- untouched either way: it is the quote's full annual written premium and
  -- nothing here prorates it, so a backdated term is charged the full year, not
  -- a stub for the remaining days.
  v_inception := COALESCE(p_inception_date, now());
  v_effective_range := tstzrange(v_inception, v_inception + interval '1 year');

  INSERT INTO policies (policy_id, quote_id, policy_number, effective_range, status)
  VALUES (uuid_generate_v4(), p_quote_id, p_policy_number, v_effective_range, 'active')
  RETURNING policy_id INTO v_policy_id;

  -- ADR 0016: snapshot vehicles/drivers onto the policy at bind time - a
  -- bound policy owns its own copy rather than continuing to point at the
  -- application's, which can keep changing after bind with no effect on
  -- what's actually insured. Mid-term add/remove of a vehicle or driver is
  -- still deferred - see ADR 0016 section 2. Set-based INSERT...SELECT, not
  -- a per-row loop: if any row conflicts (e.g. two vehicles on the same
  -- application sharing a VIN by data-entry mistake), the whole INSERT
  -- fails and the exception aborts this entire function - the policies row
  -- and quote status flip above roll back too, not just this insert.
  INSERT INTO policy_vehicles (
    policy_vehicle_id, policy_id, source_vehicle_id, effective_range,
    year, make, model, trim, vin, vehicle_category, purchase_price,
    current_appraised_value, appraisal_date, appraisal_source,
    agreed_value_requested, annual_mileage, primary_use,
    garaging_street, garaging_city, garaging_state, garaging_zip,
    garage_type, security_features, modifications, existing_liens, lienholder_name
  )
  SELECT
    uuid_generate_v4(), v_policy_id, v.vehicle_id, v_effective_range,
    v.year, v.make, v.model, v.trim, v.vin, v.vehicle_category, v.purchase_price,
    v.current_appraised_value, v.appraisal_date, v.appraisal_source,
    v.agreed_value_requested, v.annual_mileage, v.primary_use,
    v.garaging_street, v.garaging_city, v.garaging_state, v.garaging_zip,
    v.garage_type, v.security_features, v.modifications, v.existing_liens, v.lienholder_name
  FROM vehicles v
  WHERE v.application_id = v_application_id;

  INSERT INTO policy_drivers (
    policy_driver_id, policy_id, source_driver_id, effective_range,
    name, relationship_to_applicant, date_of_birth, years_licensed,
    license_status, violations_last_5yr, at_fault_accidents_last_5yr
  )
  SELECT
    uuid_generate_v4(), v_policy_id, d.driver_id, v_effective_range,
    d.name, d.relationship_to_applicant, d.date_of_birth, d.years_licensed,
    d.license_status, d.violations_last_5yr, d.at_fault_accidents_last_5yr
  FROM additional_drivers d
  WHERE d.application_id = v_application_id;

  UPDATE quotes SET status = 'bound' WHERE quote_id = p_quote_id;

  INSERT INTO policy_events (policy_id, event_type, performed_by)
  VALUES (v_policy_id, 'bound', p_performed_by);

  RETURN v_policy_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Links a freshly-bound policy back to the cancelled policy it reinstates
-- (ADR 0023, the ">14-day" path). Deliberately a SEPARATE step called AFTER a
-- normal bind_policy(), not a widened bind_policy() signature: the >14-day
-- reinstatement runs through the ordinary application -> quote -> bind flow
-- exactly like any other new business, so every existing bind call site and
-- every non-reinstatement bind stays untouched. Widening bind_policy() to carry
-- an optional prior-policy reference is exactly the overload trap ADR 0021's
-- addendum documented for program_share_gaps - one function quietly doing two
-- jobs - and is avoided for the same reason. (ADR 0024 later gives bind_policy()
-- an optional inception DATE - a general term-selection hook, the open item it
-- always flagged - so the backdated-reinstatement wrapper can pin inception to
-- the gap start. That is a different thing from threading a prior-policy
-- reference: the linkage stays here and in that wrapper, not in bind_policy().)
--
-- The link is set once. reinstated_from_policy_id is a single immutable fact
-- ("this policy reinstated that one"), not a corrected temporal one, so this
-- rejects a second call rather than overwriting - no append-only correction
-- machinery, by design (ADR 0023).
--
-- NOT enforced here, deliberately: that both policies belong to the same
-- insured. A >14-day reinstatement is new business, so the returning customer
-- is re-keyed through a fresh application, and this schema does not resolve
-- applicant identity across separate application chains - two applications by
-- the same real person get two applicant_ids (there is no natural key or dedup
-- on applicants). A hard "same applicant_id" check would therefore REJECT the
-- ordinary, correct case this path exists for. Whether the operator picked the
-- right predecessor is a human judgement best confirmed at the UI (the Odoo
-- wizard shows the prior policy's insured for the operator to eyeball), not a
-- SQL invariant that would be wrong as often as right. See ADR 0023 section 3.
CREATE OR REPLACE FUNCTION link_reinstated_policy(
  p_new_policy_id UUID,
  p_prior_policy_id UUID,
  p_performed_by TEXT
) RETURNS VOID AS $$
DECLARE
  v_existing_link UUID;
  v_prior_status policy_status_t;
BEGIN
  IF p_new_policy_id = p_prior_policy_id THEN
    RAISE EXCEPTION 'REINSTATEMENT_SELF_REFERENCE: a policy cannot reinstate itself (%)', p_new_policy_id;
  END IF;

  -- The new policy: must exist, and must not already carry a link. Locked so a
  -- concurrent second call blocks here rather than racing the set-once check.
  SELECT reinstated_from_policy_id INTO v_existing_link
  FROM policies
  WHERE policy_id = p_new_policy_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'link_reinstated_policy: policy % does not exist', p_new_policy_id;
  END IF;

  IF v_existing_link IS NOT NULL THEN
    RAISE EXCEPTION 'REINSTATEMENT_ALREADY_LINKED: policy % is already linked to prior policy % and the link is set-once',
      p_new_policy_id, v_existing_link
      USING HINT = 'The reinstated_from link is immutable. If it was set to the wrong predecessor, that is a data-repair question for a DBA, not a second call to this function.';
  END IF;

  -- The prior policy: must exist, and must be cancelled. policies.status is a
  -- plain mutable column (cancel_policy() sets it with a direct UPDATE; there
  -- is no policies-history/correction table), so reading it straight off the
  -- row IS the current status - confirmed against the schema before relying on
  -- it, because this project has been burned by mis-reading "the current row"
  -- on tables that DO carry correction history.
  SELECT status INTO v_prior_status
  FROM policies
  WHERE policy_id = p_prior_policy_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'link_reinstated_policy: prior policy % does not exist', p_prior_policy_id;
  END IF;

  IF v_prior_status <> 'cancelled' THEN
    RAISE EXCEPTION 'REINSTATEMENT_PRIOR_NOT_CANCELLED: prior policy % is % , not cancelled - only a cancelled policy can be reinstated',
      p_prior_policy_id, v_prior_status
      USING HINT = 'A >14-day reinstatement succeeds a CANCELLED policy. An active, expired or nonrenewed policy is not a reinstatement target.';
  END IF;

  -- updated_at is maintained by the policies_updated_at BEFORE UPDATE trigger,
  -- so it is not set here - the same way cancel_policy() leaves it to the trigger.
  UPDATE policies
  SET reinstated_from_policy_id = p_prior_policy_id
  WHERE policy_id = p_new_policy_id;

  -- A row on BOTH policies so the relationship is visible from either side's
  -- own event history, not just the new policy's. event_type follows the
  -- existing verb-in-past-tense convention ('bound', 'cancelled',
  -- 'cancellation_corrected'); notes name the counterpart policy in each
  -- direction the way cancel_policy()'s notes carry their context.
  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (p_new_policy_id, 'reinstatement_linked', p_performed_by,
          format('reinstates cancelled policy %s (>14-day path, new business)', p_prior_policy_id));

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (p_prior_policy_id, 'reinstatement_linked', p_performed_by,
          format('reinstated by new policy %s (>14-day path, new business)', p_new_policy_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ADR 0012's original signature, superseded by ADR 0018's seven-argument
-- cancel_policy() further down this file. It stays callable, and refuses:
-- it has nowhere to record who initiated the cancellation, and that is the
-- input deciding whether a filed short-rate table applies instead of
-- pro-rata. It also never computed a return premium, never closed out the
-- policy's vehicle/driver snapshots, and truncated coverage to now() with no
-- way to say otherwise - so silently forwarding to the new function under
-- assumed arguments would be picking, on the caller's behalf, exactly the
-- things ADR 0018 exists to make explicit. Same reasoning as
-- SHORT_RATE_TABLE_NOT_CONFIGURED: a loud failure beats a plausible-looking
-- default on a number someone gets paid.
CREATE OR REPLACE FUNCTION cancel_policy(
  p_policy_id UUID,
  p_performed_by TEXT,
  p_notes TEXT
) RETURNS VOID AS $$
BEGIN
  RAISE EXCEPTION 'CANCELLATION_TYPE_REQUIRED: cancel_policy(policy, performed_by, notes) cannot record who initiated the cancellation or how the return premium is computed (policy %, requested by %)',
    p_policy_id, COALESCE(p_performed_by, 'unknown')
    USING HINT = 'Call cancel_policy(policy_id, cancellation_type, reason_code, refund_method, cancelled_at, notes, performed_by) instead - ADR 0018. insured_initiated vs company_initiated decides pro-rata vs short-rate, and pro_rata is always available.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- POLICY ENDORSEMENTS (ADR 0014)
-- v1 scope: premium_adjustment and term_change only. Structural endorsements
-- (vehicle/coverage changes) are explicitly deferred - vehicles and
-- coverage_requested are currently scoped to applications, not policies, and
-- that's a real schema-design decision this table doesn't attempt to make.
-- Versioned rows, not mutation of the policies row - same discipline as
-- state_rating_table_versions and program_participants.
-- ============================================================================

CREATE TABLE IF NOT EXISTS policy_endorsements (
  endorsement_id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id           UUID NOT NULL REFERENCES policies(policy_id),
  effective_range     TSTZRANGE NOT NULL,
  endorsement_type    endorsement_type_t NOT NULL,
  premium_delta       NUMERIC(12,2),  -- nullable: a pure term_change may have no premium impact
  reason              TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Closes ADR 0007's temporal-overlap gap now instead of repeating it: two
  -- endorsements on the same policy can never have overlapping
  -- effective_range - enforced at the database level, same btree_gist
  -- pattern as state_rating_table_versions' own exclusion constraint.
  CONSTRAINT no_overlapping_policy_endorsements
    EXCLUDE USING gist (policy_id WITH =, effective_range WITH &&)
);

CREATE INDEX IF NOT EXISTS idx_policy_endorsements_policy ON policy_endorsements(policy_id);

-- Append-only, same reasoning as decision_log/policy_events: the exclusion
-- constraint above only stops a *conflicting* write. It does nothing to stop
-- a silent UPDATE that changes an otherwise-valid row's reason or
-- premium_delta in place, with no overlap and therefore nothing for the
-- constraint to catch. correct_policy_endorsement() below is the one
-- legitimate way to correct a mistaken row.
-- The escape hatch below (ADR 0014 addendum) replaces the ALTER TABLE ...
-- DISABLE TRIGGER that correct_policy_endorsement() used to reach for. That
-- call fails outright - "cannot ALTER TABLE because it is being used by
-- active queries in this session" - whenever the caller's own statement is
-- scanning this table, which is what
--   SELECT correct_policy_endorsement((SELECT endorsement_id FROM
--          policy_endorsements WHERE ...), ...)
-- does. Reproduced on all three policy-side correction functions before this
-- change; see ADR 0017 section 4, where the same trap was first found.
--
-- The replacement is narrower than what it replaces: DISABLE TRIGGER turns
-- append-only off for the whole table and everyone in it, while this permits
-- exactly one mutation - closing a row's upper bound, with the lower bound
-- and every other column byte-identical - and only while the correction
-- function's transaction-local flag is set. The row comparison is
-- to_jsonb(NEW) minus effective_range rather than a column list, so a column
-- added to this table later is covered without anyone remembering to add it
-- here. DELETE is never permitted, flag or no flag.
CREATE OR REPLACE FUNCTION reject_policy_endorsements_mutation()
RETURNS TRIGGER AS $$
BEGIN
  -- Two permitted supersession shapes, and only these (ADR 0016 addendum 3):
  -- closing the row's upper bound, or emptying it outright when the corrected
  -- row starts at or before this one did. An empty range normalises to
  -- 'empty', so lower(NEW) is NULL and the "lower bound unchanged" test
  -- cannot carry that case - which is why it needs naming separately rather
  -- than falling out of the same condition.
  IF TG_OP = 'UPDATE'
     AND current_setting('luxauto.superseding_policy_endorsement', true) = 'on'
     AND NOT isempty(OLD.effective_range)
     AND (isempty(NEW.effective_range)
          OR lower(NEW.effective_range) IS NOT DISTINCT FROM lower(OLD.effective_range))
     AND to_jsonb(NEW) - 'effective_range' = to_jsonb(OLD) - 'effective_range'
  THEN
    RETURN NEW;  -- correct_policy_endorsement() closing or emptying this row
  END IF;

  RAISE EXCEPTION 'policy_endorsements is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER policy_endorsements_no_update
  BEFORE UPDATE ON policy_endorsements
  FOR EACH ROW EXECUTE FUNCTION reject_policy_endorsements_mutation();

CREATE OR REPLACE TRIGGER policy_endorsements_no_delete
  BEFORE DELETE ON policy_endorsements
  FOR EACH ROW EXECUTE FUNCTION reject_policy_endorsements_mutation();

-- Endorsement waterfall (ADR 0014): resolves an endorsement into the same
-- three raw inputs calculate_premium_waterfall(program_id, amount, as_of)
-- already accepts, and delegates to it - no reimplemented arithmetic. The
-- as_of date is the endorsement's OWN effective_range lower bound, not the
-- original quote's quoted_at: program_participants can change between when a
-- policy was quoted and when a later endorsement takes effect, and an
-- endorsement's premium delta should split among whoever's on the program at
-- endorsement time. A negative premium_delta (return premium) needs no
-- special-casing - the formula is linear, so it flows through as
-- proportionally negative shares automatically. Only meaningful when
-- premium_delta IS NOT NULL; a pure term_change endorsement has nothing for
-- this to compute, so it returns zero rows rather than erroring.
CREATE OR REPLACE FUNCTION calculate_endorsement_waterfall(p_endorsement_id UUID)
RETURNS TABLE (
  participant_id      UUID,
  participant_name    TEXT,
  participant_type    participant_type_t,
  share_percentage    NUMERIC(5,2),
  commission_rate     NUMERIC(5,2),
  gross_share          NUMERIC(14,2),
  commission_amount    NUMERIC(14,2),
  net_due               NUMERIC(14,2)
) AS $$
  SELECT w.*
  FROM policy_endorsements pe
  JOIN policies p ON p.policy_id = pe.policy_id
  JOIN quotes q ON q.quote_id = p.quote_id
  CROSS JOIN LATERAL calculate_premium_waterfall(q.program_id, pe.premium_delta, lower(pe.effective_range)) w
  WHERE pe.endorsement_id = p_endorsement_id
    AND pe.premium_delta IS NOT NULL;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Writes a policy_endorsements row and a policy_events row ('endorsed')
-- atomically - same discipline as bind_policy/cancel_policy, same reason:
-- odoo has no direct grant on policy_endorsements or policy_events, only on
-- the read-side views, and this is the controlled gateway.
CREATE OR REPLACE FUNCTION endorse_policy(
  p_policy_id UUID,
  p_effective_range TSTZRANGE,
  p_endorsement_type endorsement_type_t,
  p_premium_delta NUMERIC,
  p_reason TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_endorsement_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM policies WHERE policy_id = p_policy_id) THEN
    RAISE EXCEPTION 'endorse_policy: policy % does not exist', p_policy_id;
  END IF;

  INSERT INTO policy_endorsements (endorsement_id, policy_id, effective_range, endorsement_type, premium_delta, reason)
  VALUES (uuid_generate_v4(), p_policy_id, p_effective_range, p_endorsement_type, p_premium_delta, p_reason)
  RETURNING endorsement_id INTO v_endorsement_id;

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (p_policy_id, 'endorsed', p_performed_by, p_reason);

  RETURN v_endorsement_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Corrects a mistaken endorsement (ADR 0014 section 3): a named, controlled
-- path rather than freeform SQL left for each caller to invent. Single
-- transaction: temporarily disables policy_endorsements' append-only UPDATE
-- trigger to shrink the original row's effective_range upper bound (the
-- same disable/act/re-enable pattern already used, ad hoc, when cleaning up
-- policy_events test data during this project's own testing sessions - now
-- promoted to a real, reusable function), re-enables the trigger immediately
-- after, inserts the corrected row, and logs a policy_events row
-- ('endorsement_corrected') referencing both endorsement_ids so the audit
-- trail shows a correction happened rather than an unexplained new
-- endorsement appearing.
CREATE OR REPLACE FUNCTION correct_policy_endorsement(
  p_endorsement_id UUID,
  p_new_effective_range TSTZRANGE,
  p_new_endorsement_type endorsement_type_t,
  p_new_premium_delta NUMERIC,
  p_new_reason TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_policy_id UUID;
  v_old_range TSTZRANGE;
  v_new_endorsement_id UUID;
BEGIN
  SELECT policy_id, effective_range INTO v_policy_id, v_old_range
  FROM policy_endorsements
  WHERE endorsement_id = p_endorsement_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'correct_policy_endorsement: endorsement % does not exist', p_endorsement_id;
  END IF;

  PERFORM set_config('luxauto.superseding_policy_endorsement', 'on', true);
  UPDATE policy_endorsements
  -- GREATEST, not the bare new lower bound: correcting a row to a start at or
  -- before its own leaves it no period during which it was ever right, so it
  -- is emptied rather than given an impossible range (ADR 0016 addendum 3).
  SET effective_range = tstzrange(lower(v_old_range),
                                  GREATEST(lower(v_old_range), lower(p_new_effective_range)))
  WHERE endorsement_id = p_endorsement_id;
  PERFORM set_config('luxauto.superseding_policy_endorsement', 'off', true);

  INSERT INTO policy_endorsements (endorsement_id, policy_id, effective_range, endorsement_type, premium_delta, reason)
  VALUES (uuid_generate_v4(), v_policy_id, p_new_effective_range, p_new_endorsement_type, p_new_premium_delta, p_new_reason)
  RETURNING endorsement_id INTO v_new_endorsement_id;

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (v_policy_id, 'endorsement_corrected', p_performed_by,
          format('Corrected endorsement %s with new endorsement %s', p_endorsement_id, v_new_endorsement_id));

  RETURN v_new_endorsement_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- STRUCTURAL POLICY OWNERSHIP: VEHICLES AND DRIVERS (ADR 0016)
-- A bound policy owns its own snapshot of vehicles/drivers, taken at bind
-- time by bind_policy() (below) - not a live pointer back to the
-- application's rows, which keep changing after bind with no effect on
-- what's actually insured. coverage_requested (limits/deductibles) is NOT
-- structural - it stays under ADR 0014's premium/term endorsement
-- machinery. Exclusion constraints are scoped per (policy_id, vin) /
-- (policy_id, name, date_of_birth), not per policy like
-- policy_endorsements' - multiple vehicles/drivers are legitimately
-- concurrent on one policy, and a per-policy scope would reject the second
-- car outright.
-- ============================================================================

CREATE TABLE IF NOT EXISTS policy_vehicles (
  policy_vehicle_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id                  UUID NOT NULL REFERENCES policies(policy_id),
  source_vehicle_id          UUID NOT NULL REFERENCES vehicles(vehicle_id),
  effective_range            TSTZRANGE NOT NULL,
  year                        SMALLINT NOT NULL,
  make                        TEXT NOT NULL,
  model                       TEXT NOT NULL,
  trim                        TEXT,
  -- NOT NULL as of the ADR 0016 addendum: nullable here (mirroring the
  -- source vehicles.vin) left a hole in the exclusion constraint below.
  vin                         TEXT NOT NULL,
  vehicle_category            vehicle_category_t NOT NULL,
  purchase_price               NUMERIC(12,2),
  current_appraised_value      NUMERIC(12,2),
  appraisal_date                DATE,
  appraisal_source              TEXT,
  agreed_value_requested        BOOLEAN NOT NULL DEFAULT false,
  annual_mileage                 INTEGER,
  primary_use                    primary_use_t,
  garaging_street                TEXT,
  garaging_city                  TEXT,
  garaging_state                 CHAR(2) NOT NULL,
  garaging_zip                   TEXT,
  garage_type                    garage_type_t,
  security_features              TEXT[] NOT NULL DEFAULT '{}',
  modifications                  TEXT,
  existing_liens                 BOOLEAN,
  lienholder_name                TEXT,
  created_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- NOT per-policy (unlike policy_endorsements) - per (policy_id, vin), so
  -- two different vehicles on the same policy don't conflict with each
  -- other. vin is NOT NULL here even though the source vehicles.vin is
  -- nullable: NULL <> NULL in an exclusion constraint, so a nullable vin
  -- would silently exempt exactly the rows least able to be identified
  -- (ADR 0016 addendum; DH-04 already routes a null-vin application to
  -- INFORMATION_REQUEST long before bind).
  CONSTRAINT no_overlapping_policy_vehicles
    EXCLUDE USING gist (policy_id WITH =, vin WITH =, effective_range WITH &&)
);

CREATE INDEX IF NOT EXISTS idx_policy_vehicles_policy ON policy_vehicles(policy_id);

-- Escape hatch per the ADR 0016 addendum on correction-function mechanics -
-- see reject_policy_endorsements_mutation() above for the full reasoning and
-- the trap it fixes. Same shape here: only the closing of a row's upper
-- bound, only while correct_policy_vehicle()'s transaction-local flag is set,
-- never a DELETE.
CREATE OR REPLACE FUNCTION reject_policy_vehicles_mutation()
RETURNS TRIGGER AS $$
BEGIN
  -- Two permitted supersession shapes, and only these (ADR 0016 addendum 3):
  -- closing the row's upper bound, or emptying it outright when the corrected
  -- row starts at or before this one did. An empty range normalises to
  -- 'empty', so lower(NEW) is NULL and the "lower bound unchanged" test
  -- cannot carry that case - which is why it needs naming separately rather
  -- than falling out of the same condition.
  IF TG_OP = 'UPDATE'
     AND current_setting('luxauto.superseding_policy_vehicle', true) = 'on'
     AND NOT isempty(OLD.effective_range)
     AND (isempty(NEW.effective_range)
          OR lower(NEW.effective_range) IS NOT DISTINCT FROM lower(OLD.effective_range))
     AND to_jsonb(NEW) - 'effective_range' = to_jsonb(OLD) - 'effective_range'
  THEN
    RETURN NEW;  -- correct_policy_vehicle() closing or emptying this row
  END IF;

  RAISE EXCEPTION 'policy_vehicles is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER policy_vehicles_no_update
  BEFORE UPDATE ON policy_vehicles
  FOR EACH ROW EXECUTE FUNCTION reject_policy_vehicles_mutation();

CREATE OR REPLACE TRIGGER policy_vehicles_no_delete
  BEFORE DELETE ON policy_vehicles
  FOR EACH ROW EXECUTE FUNCTION reject_policy_vehicles_mutation();

CREATE TABLE IF NOT EXISTS policy_drivers (
  policy_driver_id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id                    UUID NOT NULL REFERENCES policies(policy_id),
  source_driver_id             UUID NOT NULL REFERENCES additional_drivers(driver_id),
  effective_range               TSTZRANGE NOT NULL,
  name                           TEXT NOT NULL,
  relationship_to_applicant     TEXT,
  -- NOT NULL as of the ADR 0016 addendum, same reason as vehicles' vin:
  -- name+date_of_birth is this table's identity, and half an identity is
  -- not one. (name was already NOT NULL; date_of_birth was not.)
  date_of_birth                  DATE NOT NULL,
  years_licensed                 SMALLINT,
  license_status                 license_status_t,
  violations_last_5yr            SMALLINT,
  at_fault_accidents_last_5yr    SMALLINT,
  created_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- additional_drivers has no SSN/license-number column - name+date_of_birth
  -- is the best available natural key, not an arbitrary choice. Both halves
  -- are NOT NULL here (ADR 0016 addendum) even though date_of_birth is
  -- nullable on the source table, for the same reason vin is: a null half
  -- of the key would exempt the row from this constraint entirely.
  CONSTRAINT no_overlapping_policy_drivers
    EXCLUDE USING gist (policy_id WITH =, name WITH =, date_of_birth WITH =, effective_range WITH &&)
);

CREATE INDEX IF NOT EXISTS idx_policy_drivers_policy ON policy_drivers(policy_id);

-- Escape hatch per the ADR 0016 addendum on correction-function mechanics -
-- see reject_policy_endorsements_mutation() for the reasoning.
CREATE OR REPLACE FUNCTION reject_policy_drivers_mutation()
RETURNS TRIGGER AS $$
BEGIN
  -- Two permitted supersession shapes, and only these (ADR 0016 addendum 3):
  -- closing the row's upper bound, or emptying it outright when the corrected
  -- row starts at or before this one did. An empty range normalises to
  -- 'empty', so lower(NEW) is NULL and the "lower bound unchanged" test
  -- cannot carry that case - which is why it needs naming separately rather
  -- than falling out of the same condition.
  IF TG_OP = 'UPDATE'
     AND current_setting('luxauto.superseding_policy_driver', true) = 'on'
     AND NOT isempty(OLD.effective_range)
     AND (isempty(NEW.effective_range)
          OR lower(NEW.effective_range) IS NOT DISTINCT FROM lower(OLD.effective_range))
     AND to_jsonb(NEW) - 'effective_range' = to_jsonb(OLD) - 'effective_range'
  THEN
    RETURN NEW;  -- correct_policy_driver() closing or emptying this row
  END IF;

  RAISE EXCEPTION 'policy_drivers is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER policy_drivers_no_update
  BEFORE UPDATE ON policy_drivers
  FOR EACH ROW EXECUTE FUNCTION reject_policy_drivers_mutation();

CREATE OR REPLACE TRIGGER policy_drivers_no_delete
  BEFORE DELETE ON policy_drivers
  FOR EACH ROW EXECUTE FUNCTION reject_policy_drivers_mutation();

-- ADR 0016 addendum: the CREATE TABLEs above declare vin/name/date_of_birth
-- NOT NULL, but they're CREATE TABLE IF NOT EXISTS - a database created
-- before this addendum already has the tables and would skip those columns'
-- new constraint entirely. This block is what actually closes the gap on
-- those databases; on a fresh apply it's a no-op (SET NOT NULL on a column
-- that is already NOT NULL is idempotent, not an error).
--
-- Pre-existing rows are checked, not assumed: SET NOT NULL against a table
-- holding null identities fails with a bare "column contains null values",
-- which says nothing about what to do next. These are insurance records -
-- the schema file will not backfill a placeholder VIN or delete the rows to
-- make itself apply cleanly, so it stops and says exactly what it found.
DO $$
DECLARE
  v_null_vin_vehicles INTEGER;
  v_null_identity_drivers INTEGER;
BEGIN
  SELECT count(*) INTO v_null_vin_vehicles
  FROM policy_vehicles WHERE vin IS NULL;

  SELECT count(*) INTO v_null_identity_drivers
  FROM policy_drivers WHERE name IS NULL OR date_of_birth IS NULL;

  IF v_null_vin_vehicles > 0 OR v_null_identity_drivers > 0 THEN
    RAISE EXCEPTION 'ADR 0016 addendum: cannot enforce NOT NULL on policy vehicle/driver identity - % policy_vehicles row(s) have a null vin and % policy_drivers row(s) have a null name or date_of_birth',
      v_null_vin_vehicles, v_null_identity_drivers
      USING HINT = 'Correct each row via correct_policy_vehicle()/correct_policy_driver() with the real identity, then re-run this file. This schema will not invent a VIN or delete a policy''s vehicle/driver record to make itself apply.';
  END IF;

  ALTER TABLE policy_vehicles ALTER COLUMN vin SET NOT NULL;
  ALTER TABLE policy_drivers ALTER COLUMN name SET NOT NULL;
  ALTER TABLE policy_drivers ALTER COLUMN date_of_birth SET NOT NULL;
END $$;

-- Corrects a mistaken policy_vehicles snapshot row - same pattern as
-- correct_policy_endorsement() exactly: close old row, insert corrected row,
-- log the correction, never mutate in place.
CREATE OR REPLACE FUNCTION correct_policy_vehicle(
  p_policy_vehicle_id UUID,
  p_new_effective_range TSTZRANGE,
  p_new_year SMALLINT,
  p_new_make TEXT,
  p_new_model TEXT,
  p_new_trim TEXT,
  p_new_vin TEXT,
  p_new_vehicle_category vehicle_category_t,
  p_new_purchase_price NUMERIC,
  p_new_current_appraised_value NUMERIC,
  p_new_appraisal_date DATE,
  p_new_appraisal_source TEXT,
  p_new_agreed_value_requested BOOLEAN,
  p_new_annual_mileage INTEGER,
  p_new_primary_use primary_use_t,
  p_new_garaging_street TEXT,
  p_new_garaging_city TEXT,
  p_new_garaging_state CHAR(2),
  p_new_garaging_zip TEXT,
  p_new_garage_type garage_type_t,
  p_new_security_features TEXT[],
  p_new_modifications TEXT,
  p_new_existing_liens BOOLEAN,
  p_new_lienholder_name TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_policy_id UUID;
  v_source_vehicle_id UUID;
  v_old_range TSTZRANGE;
  v_new_id UUID;
BEGIN
  SELECT policy_id, source_vehicle_id, effective_range
    INTO v_policy_id, v_source_vehicle_id, v_old_range
  FROM policy_vehicles
  WHERE policy_vehicle_id = p_policy_vehicle_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'correct_policy_vehicle: policy vehicle % does not exist', p_policy_vehicle_id;
  END IF;

  -- Same named condition bind_policy() raises, for the same reason (ADR 0016
  -- addendum): this is the other writer to policy_vehicles, and a correction
  -- that blanks the VIN would hit the NOT NULL as an anonymous constraint
  -- violation - after the old row's range had already been closed.
  IF p_new_vin IS NULL THEN
    RAISE EXCEPTION 'BIND_BLOCKED_MISSING_VEHICLE_VIN: correcting policy vehicle % requires a vin', p_policy_vehicle_id
      USING HINT = 'A corrected snapshot row still has to be identifiable - the exclusion constraint keys on (policy_id, vin). Supply the real VIN.';
  END IF;

  PERFORM set_config('luxauto.superseding_policy_vehicle', 'on', true);
  UPDATE policy_vehicles
  -- GREATEST, not the bare new lower bound: correcting a row to a start at or
  -- before its own leaves it no period during which it was ever right, so it
  -- is emptied rather than given an impossible range (ADR 0016 addendum 3).
  SET effective_range = tstzrange(lower(v_old_range),
                                  GREATEST(lower(v_old_range), lower(p_new_effective_range)))
  WHERE policy_vehicle_id = p_policy_vehicle_id;
  PERFORM set_config('luxauto.superseding_policy_vehicle', 'off', true);

  INSERT INTO policy_vehicles (
    policy_vehicle_id, policy_id, source_vehicle_id, effective_range,
    year, make, model, trim, vin, vehicle_category, purchase_price,
    current_appraised_value, appraisal_date, appraisal_source,
    agreed_value_requested, annual_mileage, primary_use,
    garaging_street, garaging_city, garaging_state, garaging_zip,
    garage_type, security_features, modifications, existing_liens, lienholder_name
  )
  VALUES (
    uuid_generate_v4(), v_policy_id, v_source_vehicle_id, p_new_effective_range,
    p_new_year, p_new_make, p_new_model, p_new_trim, p_new_vin, p_new_vehicle_category, p_new_purchase_price,
    p_new_current_appraised_value, p_new_appraisal_date, p_new_appraisal_source,
    p_new_agreed_value_requested, p_new_annual_mileage, p_new_primary_use,
    p_new_garaging_street, p_new_garaging_city, p_new_garaging_state, p_new_garaging_zip,
    p_new_garage_type, p_new_security_features, p_new_modifications, p_new_existing_liens, p_new_lienholder_name
  )
  RETURNING policy_vehicle_id INTO v_new_id;

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (v_policy_id, 'policy_vehicle_corrected', p_performed_by,
          format('Corrected policy vehicle %s with new policy vehicle %s', p_policy_vehicle_id, v_new_id));

  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Corrects a mistaken policy_drivers snapshot row - same pattern.
CREATE OR REPLACE FUNCTION correct_policy_driver(
  p_policy_driver_id UUID,
  p_new_effective_range TSTZRANGE,
  p_new_name TEXT,
  p_new_relationship_to_applicant TEXT,
  p_new_date_of_birth DATE,
  p_new_years_licensed SMALLINT,
  p_new_license_status license_status_t,
  p_new_violations_last_5yr SMALLINT,
  p_new_at_fault_accidents_last_5yr SMALLINT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_policy_id UUID;
  v_source_driver_id UUID;
  v_old_range TSTZRANGE;
  v_new_id UUID;
BEGIN
  SELECT policy_id, source_driver_id, effective_range
    INTO v_policy_id, v_source_driver_id, v_old_range
  FROM policy_drivers
  WHERE policy_driver_id = p_policy_driver_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'correct_policy_driver: policy driver % does not exist', p_policy_driver_id;
  END IF;

  -- Same named condition bind_policy() raises (ADR 0016 addendum) - see
  -- correct_policy_vehicle() above for why the correction path gets the
  -- check too, not just the bind path.
  IF p_new_name IS NULL OR p_new_date_of_birth IS NULL THEN
    RAISE EXCEPTION 'BIND_BLOCKED_MISSING_DRIVER_IDENTITY: correcting policy driver % requires both a name and a date_of_birth', p_policy_driver_id
      USING HINT = 'A corrected snapshot row still has to be identifiable - the exclusion constraint keys on (policy_id, name, date_of_birth). Supply both.';
  END IF;

  PERFORM set_config('luxauto.superseding_policy_driver', 'on', true);
  UPDATE policy_drivers
  -- GREATEST, not the bare new lower bound: correcting a row to a start at or
  -- before its own leaves it no period during which it was ever right, so it
  -- is emptied rather than given an impossible range (ADR 0016 addendum 3).
  SET effective_range = tstzrange(lower(v_old_range),
                                  GREATEST(lower(v_old_range), lower(p_new_effective_range)))
  WHERE policy_driver_id = p_policy_driver_id;
  PERFORM set_config('luxauto.superseding_policy_driver', 'off', true);

  INSERT INTO policy_drivers (
    policy_driver_id, policy_id, source_driver_id, effective_range,
    name, relationship_to_applicant, date_of_birth, years_licensed,
    license_status, violations_last_5yr, at_fault_accidents_last_5yr
  )
  VALUES (
    uuid_generate_v4(), v_policy_id, v_source_driver_id, p_new_effective_range,
    p_new_name, p_new_relationship_to_applicant, p_new_date_of_birth, p_new_years_licensed,
    p_new_license_status, p_new_violations_last_5yr, p_new_at_fault_accidents_last_5yr
  )
  RETURNING policy_driver_id INTO v_new_id;

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (v_policy_id, 'policy_driver_corrected', p_performed_by,
          format('Corrected policy driver %s with new policy driver %s', p_policy_driver_id, v_new_id));

  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- RETURN PREMIUM AND CANCELLATION (ADR 0018)
-- Mid-term coverage reductions need nothing here: a reduction is an
-- endorsement with a negative premium_delta, which policy_endorsements and
-- calculate_premium_waterfall(program_id, amount, as_of) already handle
-- (ADR 0014 section 5 reasoned it; ADR 0018 verified it end to end rather
-- than continuing to assume it). What this section adds is the other half -
-- full cancellation, which is a policy-terminating event, not a premium
-- adjustment: it truncates coverage, closes out the policy's vehicle and
-- driver snapshots, computes a return premium, and records why.
--
-- policies.status (ADR 0010) already exists and cancel_policy() (ADR 0012)
-- already sets it, so cancellation status is not inferred from range
-- arithmetic and needs no new mechanism here - see ADR 0018 section 2.
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE cancellation_type_t AS ENUM ('insured_initiated', 'company_initiated');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE refund_method_t AS ENUM ('pro_rata', 'short_rate');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
-- How a filed short-rate table's number is meant to be applied. Stored per
-- row rather than assumed, because the two conventions in common use produce
-- different refunds from the same policy, and which one a given filing means
-- is a fact about that filing - not something this schema gets to pick.
DO $$ BEGIN
  CREATE TYPE short_rate_basis_t AS ENUM ('unearned_premium_multiplier', 'percent_of_annual_premium_returned');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- Deliberately empty. Short-rate percentages are filed, state-regulated
-- numbers: several states restrict short-rate to insured-initiated
-- cancellations, cap it, or prohibit it outright, and the applicable table
-- is part of a rate filing. This table is the shape those numbers load into;
-- it ships with no rows, and short_rate_factor() below fails loudly rather
-- than defaulting to a guess. Same discipline as
-- state_rating_table_schema.json's build_note: every field must trace back
-- to a real source document (a filed cancellation/short-rate table, a DOI
-- bulletin), or it's a data gap waiting to surface at the worst time.
CREATE TABLE IF NOT EXISTS short_rate_factors (
  short_rate_factor_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  state                   CHAR(2) NOT NULL,
  -- NULL means "applies to any program in this state"; a program-specific
  -- row wins over a statewide one (short_rate_factor() orders on this).
  program_id              UUID REFERENCES insurance_programs(program_id),
  elapsed_fraction_from   NUMERIC(5,4) NOT NULL DEFAULT 0,   -- [from, to) of the
  elapsed_fraction_to     NUMERIC(5,4) NOT NULL DEFAULT 1,   -- term already elapsed
  factor                  NUMERIC(6,4) NOT NULL,
  basis                   short_rate_basis_t NOT NULL,
  applies_to              cancellation_type_t,               -- NULL = both; a state that
                                                                -- permits short-rate only on
                                                                -- insured-initiated says so here
  effective_range         TSTZRANGE NOT NULL,
  -- Provenance, mirroring state_rating_table_versions: a factor with no
  -- filing behind it is exactly what this table exists to prevent.
  serff_filing_tracking_number TEXT NOT NULL,
  rate_manual_reference   TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT short_rate_factors_fraction_ck
    CHECK (elapsed_fraction_from >= 0 AND elapsed_fraction_to <= 1
           AND elapsed_fraction_from < elapsed_fraction_to),
  CONSTRAINT short_rate_factors_factor_ck CHECK (factor >= 0 AND factor <= 1)
);

CREATE INDEX IF NOT EXISTS idx_short_rate_factors_state ON short_rate_factors(state);

-- Returns the filed short-rate factor for a state/program/elapsed-fraction,
-- or raises. It never returns a default: "no filed table loaded" and "the
-- filed table says zero" are different answers, and only one of them is safe
-- to act on.
CREATE OR REPLACE FUNCTION short_rate_factor(
  p_state CHAR(2),
  p_program_id UUID,
  p_cancellation_type cancellation_type_t,
  p_elapsed_fraction NUMERIC,
  p_as_of TIMESTAMPTZ
) RETURNS TABLE (factor NUMERIC, basis short_rate_basis_t) AS $$
DECLARE
  v_factor NUMERIC;
  v_basis short_rate_basis_t;
BEGIN
  SELECT f.factor, f.basis INTO v_factor, v_basis
  FROM short_rate_factors f
  WHERE f.state = p_state
    AND (f.program_id IS NULL OR f.program_id = p_program_id)
    AND (f.applies_to IS NULL OR f.applies_to = p_cancellation_type)
    AND p_elapsed_fraction >= f.elapsed_fraction_from
    AND p_elapsed_fraction <  f.elapsed_fraction_to
    AND f.effective_range @> p_as_of
  ORDER BY (f.program_id IS NOT NULL) DESC, (f.applies_to IS NOT NULL) DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SHORT_RATE_TABLE_NOT_CONFIGURED: no filed short-rate factor loaded for state %, program %, % cancellation at % of the term elapsed',
      p_state, p_program_id, p_cancellation_type, ROUND(p_elapsed_fraction, 4)
      USING HINT = 'Short-rate percentages are filed, state-regulated numbers - load short_rate_factors from the actual filed cancellation/short-rate table and DOI bulletins for this state before using refund_method short_rate. Pro-rata is pure arithmetic and needs no filing, so it remains available in the meantime.';
  END IF;

  RETURN QUERY SELECT v_factor, v_basis;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ADR 0025: seed a short-rate factor when a state is onboarded.
--
-- Business decision (confirmed, internally set - not a filed rate): the
-- short-rate cancellation penalty is a FLAT 10% admin holdback off the pro-rata
-- unearned/return premium - the insured gets 90% of what pro-rata would return
-- (a $100 pro-rata return pays $90). No variance by state, by program, or by who
-- initiated the cancellation, and it does NOT change with how much of the term
-- has elapsed. In this table's terms that is one row per state: factor 0.90 on
-- the unearned_premium_multiplier basis, a single [0,1) band, program_id and
-- applies_to NULL (any program, both initiators).
--
-- Why a trigger rather than a standalone load script or an onboarding wrapper
-- (ADR 0025): the licensed-state source of truth is state_rating_table_versions
-- itself (referral rule PC-03 - a state with no rating-table record is "not
-- licensed"), and there is no onboarding function or runbook to fold this into
-- today; states are onboarded by a direct INSERT here. A trigger fires however
-- that INSERT happens - direct SQL now, a future wrapper later - so "a licensed
-- state has a short-rate factor" is enforced by the database rather than left to
-- a step someone must remember, the same discipline every exclusion constraint
-- and append-only trigger in this schema already follows.
--
-- The NOT EXISTS guard does double duty: it keeps a second rating-table VERSION
-- of an already-onboarded state from inserting a duplicate, AND it is the
-- override hatch - a deliberately pre-seeded state-specific short_rate_factors
-- row (a future state that must differ) is left untouched rather than overwritten
-- or duplicated. The flat 0.90 is the default for a state that has not been given
-- its own, not a value forced on every state forever. No parameterised factor is
-- built because none is needed today (there is no wrapper to carry one, and the
-- guard already provides the divergence path).
--
-- Consequence, recorded rather than hidden: this makes "licensed => has a
-- short-rate factor" an invariant, so the SHORT_RATE_TABLE_NOT_CONFIGURED refusal
-- is no longer reachable for a licensed state (it still guards a genuinely
-- unlicensed one). ADR 0018's tests/0018 T6 exercised the old "licensed but table
-- empty" combination and was revised for this.
CREATE OR REPLACE FUNCTION seed_short_rate_factor_for_state()
RETURNS TRIGGER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM short_rate_factors WHERE state = NEW.state) THEN
    INSERT INTO short_rate_factors
      (state, program_id, elapsed_fraction_from, elapsed_fraction_to,
       factor, basis, applies_to, effective_range,
       serff_filing_tracking_number, rate_manual_reference)
    VALUES
      (NEW.state, NULL, 0, 1, 0.90, 'unearned_premium_multiplier'::short_rate_basis_t,
       NULL, tstzrange(NULL, NULL), 'internally set - not filed', NULL);
  END IF;
  RETURN NULL;  -- AFTER trigger: return value is ignored
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE TRIGGER state_rating_versions_seed_short_rate
  AFTER INSERT ON state_rating_table_versions
  FOR EACH ROW EXECUTE FUNCTION seed_short_rate_factor_for_state();

-- ============================================================================
-- ONBOARD A STATE - THE SOLE SANCTIONED PATH (ADR 0035)
-- The ADR 0034 footgun: a raw INSERT INTO state_rating_table_versions placed
-- BEFORE the ADR 0025 seed trigger above silently skips the short-rate seed, with
-- zero error. onboard_state() closes it by being the only way to write that
-- table: a BEFORE INSERT guard rejects any insert not made through it (via the
-- luxauto.onboarding_state transaction-local flag - the same escape-hatch idiom
-- the luxauto.superseding_* correction guards use). Because onboard_state() is
-- defined AFTER the seed trigger, it can never be placed before it, and it
-- ASSERTS the seed fired before returning - so the silent failure becomes a loud,
-- transaction-aborting one.
--
-- GRANT/REVOKE is NOT the lock here (ADR 0035): no non-owner role has any
-- privilege on these tables, and the table owner's rights cannot be revoked while
-- onboard_state runs SECURITY DEFINER as that same owner. The REVOKE below is
-- explicit documentation of intent; the guard trigger is the real enforcement.
--
-- Scope is state_rating_table_versions ONLY (the footgun table). territory_factors
-- is deliberately NOT guarded - the T0 test-state seed loads a territory factor
-- with no paired rating version, which is legitimate. onboard_state() still always
-- loads both together for the front door.

CREATE OR REPLACE FUNCTION reject_unonboarded_state_rating_insert()
RETURNS TRIGGER AS $$
BEGIN
  IF current_setting('luxauto.onboarding_state', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'STATE_RATING_TABLE_DIRECT_INSERT_FORBIDDEN: state_rating_table_versions must be written through onboard_state() (ADR 0035), not a direct INSERT'
      USING HINT = 'A direct insert can be placed before the ADR 0025 short-rate seed trigger and silently skip the seed. onboard_state() sets luxauto.onboarding_state, loads the territory factor too, and asserts the seed fired. Test fixtures that need a raw rating-table row set that flag explicitly via the escape hatch.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER state_rating_versions_onboard_guard
  BEFORE INSERT ON state_rating_table_versions
  FOR EACH ROW EXECUTE FUNCTION reject_unonboarded_state_rating_insert();

-- Onboard a state's rating data in one atomic operation: the compliance record
-- (fires the ADR 0025 short-rate seed) AND its PD territory factor, together, so a
-- state is never left half-onboarded (the ADR 0034 uncoupled-loads gap - a state
-- with a rating version but no territory factor passes PC-03 then fails
-- create_quote at TERRITORY_FACTOR_NOT_CONFIGURED). Territory data is a single PD
-- factor per state (territory_factors is one scalar per state/period, no array, no
-- FK). p_ai_governance defaults to the NY DFS Circular Letter 2024-7 documentation
-- standard - the project baseline that every state is a subset of, not a special
-- case. Any failure at any step aborts the whole transaction; no partial state.
CREATE OR REPLACE FUNCTION onboard_state(
  p_state CHAR(2),
  p_regulator_name TEXT,
  p_filing_status filing_status_t,
  p_line_of_business_code TEXT,
  p_serff_filing_tracking_number TEXT,
  p_effective_range TSTZRANGE,
  p_pd_territory_factor NUMERIC,
  p_territory_source_reference TEXT,
  p_rate_manual_reference TEXT DEFAULT NULL,
  p_expiration_or_review_date DATE DEFAULT NULL,
  p_approved_rating_variables JSONB DEFAULT '[]'::jsonb,
  p_prohibited_variables JSONB DEFAULT '[]'::jsonb,
  p_state_specific_application_fields JSONB DEFAULT '[]'::jsonb,
  p_credit_based_insurance_score JSONB DEFAULT '{}'::jsonb,
  p_gender_rating_permitted BOOLEAN DEFAULT NULL,
  p_territory_rating_basis TEXT DEFAULT NULL,
  p_agreed_value_rules JSONB DEFAULT '{}'::jsonb,
  p_referral_thresholds_state_specific JSONB DEFAULT '{}'::jsonb,
  p_ai_governance JSONB DEFAULT $json${"naic_model_bulletin_adopted": true, "documentation_required": ["bias_testing_records", "vendor_audit_rights", "internal_governance_log", "explainability_for_adverse_outcomes"], "citation": "Built to the NY DFS Circular Letter 2024-7 documentation standard by default (project baseline: every state is a subset, not a special case)."}$json$::jsonb,
  p_documentation JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
  v_record_id UUID;
BEGIN
  -- Open the guard for this function's inserts only; closed again below.
  PERFORM set_config('luxauto.onboarding_state', 'on', true);

  INSERT INTO state_rating_table_versions (
    state, regulator_name, filing_status, line_of_business_code,
    serff_filing_tracking_number, rate_manual_reference, effective_range,
    expiration_or_review_date, approved_rating_variables, prohibited_variables,
    state_specific_application_fields, credit_based_insurance_score,
    gender_rating_permitted, territory_rating_basis, agreed_value_rules,
    referral_thresholds_state_specific, ai_governance, documentation)
  VALUES (
    p_state, p_regulator_name, p_filing_status, p_line_of_business_code,
    p_serff_filing_tracking_number, p_rate_manual_reference, p_effective_range,
    p_expiration_or_review_date, p_approved_rating_variables, p_prohibited_variables,
    p_state_specific_application_fields, p_credit_based_insurance_score,
    p_gender_rating_permitted, p_territory_rating_basis, p_agreed_value_rules,
    p_referral_thresholds_state_specific, p_ai_governance, p_documentation)
  RETURNING record_id INTO v_record_id;   -- fires state_rating_versions_seed_short_rate

  INSERT INTO territory_factors (state, pd_territory_factor, effective_range, source_reference)
  VALUES (p_state, p_pd_territory_factor, p_effective_range, p_territory_source_reference);

  -- Assert the ADR 0025 seed fired (its exact signature). If somehow absent, the
  -- whole onboarding rolls back - the footgun made loud.
  IF NOT EXISTS (
    SELECT 1 FROM short_rate_factors
    WHERE state = p_state AND factor = 0.90
      AND basis = 'unearned_premium_multiplier'::short_rate_basis_t
      AND serff_filing_tracking_number = 'internally set - not filed'
  ) THEN
    RAISE EXCEPTION 'ONBOARD_STATE_SHORTRATE_SEED_MISSING: onboarding % produced no ADR 0025 short-rate seed - the seed trigger did not fire', p_state
      USING HINT = 'state_rating_versions_seed_short_rate must exist and run AFTER INSERT on state_rating_table_versions.';
  END IF;

  PERFORM set_config('luxauto.onboarding_state', 'off', true);
  RETURN v_record_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Explicit documentation of intent (NOT the real lock - the guard trigger is).
REVOKE INSERT, UPDATE, DELETE ON state_rating_table_versions, territory_factors FROM PUBLIC;
GRANT EXECUTE ON FUNCTION onboard_state(
  CHAR(2), TEXT, filing_status_t, TEXT, TEXT, TSTZRANGE, NUMERIC, TEXT, TEXT, DATE,
  JSONB, JSONB, JSONB, JSONB, BOOLEAN, TEXT, JSONB, JSONB, JSONB, JSONB) TO odoo;

-- ============================================================================
-- CONNECTICUT - FIRST ILLUSTRATIVE STATE, now onboarded through onboard_state()
-- (ADR 0035 migrates ADR 0034's raw insert to the sanctioned path). DIRECTIONAL/
-- ILLUSTRATIVE ONLY - same status as sample-data/state_rating_tables_sample.json's
-- 8-state skeleton (no CT). No filed CT manual; everything unresearched is TBD.
-- Identical data to ADR 0034's seed - a clean swap of insertion path, not new
-- data (idempotent: skipped if CT already exists, e.g. on the live DB).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM state_rating_table_versions WHERE state = 'CT') THEN
    PERFORM onboard_state(
      'CT', 'Connecticut Insurance Department', 'prior_approval', 'Private Passenger Auto',
      'TBD-ILLUSTRATIVE',
      tstzrange('2026-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'),
      1.1200,
      'Illustrative PD territory factor from the Exotic/Collector rating workbook Territory Factors sheet (ADR 0034); demo onboarding, not a filed factor',
      p_rate_manual_reference := 'TBD - illustrative onboarding (ADR 0034), not a filed manual',
      p_credit_based_insurance_score := $json${"permitted": true, "usage_context": ["new_business", "renewal", "tiering"], "notes": "No CT credit-based-score ban is documented in this project research; permitted pending verification. Any model using it falls under AI/algorithmic governance (see ai_governance)."}$json$::jsonb,
      p_territory_rating_basis := 'TBD - PD territory factor loaded separately in territory_factors (1.12, illustrative)',
      p_agreed_value_rules := $json${"max_annual_mileage_for_agreed_value": null, "pleasure_use_required": true, "reappraisal_interval_years": 2, "notes": "Illustrative defaults matching the skeleton-state pattern; verify against CT filed rules."}$json$::jsonb,
      p_referral_thresholds_state_specific := $json${"dui_lookback_years": null, "sr22_fr44_required": false, "salvage_title_disclosure_rule": "TBD", "notes": "TBD - illustrative."}$json$::jsonb,
      p_ai_governance := $json${"naic_model_bulletin_adopted": true, "naic_model_bulletin_adoption_date": "TBD - verify current NAIC tracker for CT", "state_specific_ai_law": null, "documentation_required": ["bias_testing_records", "vendor_audit_rights", "internal_governance_log", "explainability_for_adverse_outcomes"], "citation": "Built to the NY DFS Circular Letter 2024-7 documentation standard by default (this project baseline: every state is a subset, not a special case). CT-specific AI guidance not yet researched."}$json$::jsonb,
      p_documentation := $json${"source_urls": [], "last_verified_date": "2026-08-19", "verified_by": "Illustrative onboarding (ADR 0034/0035) - demo/design, NOT a compliance verification", "note": "DIRECTIONAL/ILLUSTRATIVE ONLY, same status as sample-data/state_rating_tables_sample.json's skeleton states."}$json$::jsonb
    );
  END IF;
END $$;

-- Pro-rata unearned premium for a policy as of an instant: every premium
-- amount in force is earned evenly across its OWN effective period, and what
-- has not been earned by p_as_of is unearned. That means the quote's written
-- premium over the policy term, plus each endorsement's premium_delta over
-- that endorsement's own range - a mid-term increase that ran for two months
-- of a twelve-month policy is not unearned the same way the original premium
-- is. Superseded endorsement rows carry their closed ranges, so they
-- contribute exactly the period they were actually in force and nothing
-- more.
--
-- The term is passed in rather than read from policies.effective_range: by
-- the time a correction re-computes this, the policy row has already been
-- truncated to the earlier cancellation date, and the original term is what
-- the arithmetic needs. policy_cancellations.effective_range preserves it.
CREATE OR REPLACE FUNCTION policy_unearned_premium(
  p_policy_id UUID,
  p_term TSTZRANGE,
  p_as_of TIMESTAMPTZ
) RETURNS NUMERIC AS $$
DECLARE
  v_written NUMERIC;
  v_unearned NUMERIC;
BEGIN
  IF lower(p_term) IS NULL OR upper(p_term) IS NULL THEN
    RAISE EXCEPTION 'CANCELLATION_UNBOUNDED_TERM: policy % has an unbounded term (%), which has no pro-rata fraction', p_policy_id, p_term
      USING HINT = 'A policy term needs both bounds before a return premium can be computed. Fix the policy term first.';
  END IF;

  SELECT q.premium_amount INTO v_written
  FROM policies p
  JOIN quotes q ON q.quote_id = p.quote_id
  WHERE p.policy_id = p_policy_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'policy_unearned_premium: policy % does not exist', p_policy_id;
  END IF;

  SELECT ROUND(
    COALESCE(v_written, 0)
      * GREATEST(0, EXTRACT(EPOCH FROM (upper(p_term) - GREATEST(lower(p_term), p_as_of))))
      / EXTRACT(EPOCH FROM (upper(p_term) - lower(p_term)))
    + COALESCE((
        SELECT SUM(
          e.premium_delta
            * GREATEST(0, EXTRACT(EPOCH FROM (upper(e.effective_range) - GREATEST(lower(e.effective_range), p_as_of))))
            / EXTRACT(EPOCH FROM (upper(e.effective_range) - lower(e.effective_range)))
        )
        FROM policy_endorsements e
        WHERE e.policy_id = p_policy_id
          AND e.premium_delta IS NOT NULL
          AND lower(e.effective_range) IS NOT NULL
          AND upper(e.effective_range) IS NOT NULL
          AND upper(e.effective_range) > p_as_of
          AND NOT isempty(e.effective_range)
      ), 0)
  , 2) INTO v_unearned;

  RETURN v_unearned;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- One cancellation per policy per period. effective_range is the UNEARNED
-- period the refund covers - [cancelled_at, the policy's original term end) -
-- which is also what lets a correction recompute against the original term
-- after policies.effective_range has been truncated. Append-only and
-- versioned, same discipline as policy_endorsements/policy_vehicles.
CREATE TABLE IF NOT EXISTS policy_cancellations (
  cancellation_id     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id           UUID NOT NULL REFERENCES policies(policy_id),
  effective_range     TSTZRANGE NOT NULL,
  cancellation_type   cancellation_type_t NOT NULL,
  -- Coded, not free text, matching the reason-code discipline the referral
  -- matrix and decision_log already use; notes carries the prose.
  reason_code         TEXT NOT NULL,
  refund_method       refund_method_t NOT NULL,
  short_rate_factor   NUMERIC(6,4),          -- NULL for pro_rata
  short_rate_basis    short_rate_basis_t,    -- NULL for pro_rata
  unearned_premium    NUMERIC(12,2) NOT NULL,  -- pro-rata unearned, before any short-rate factor
  return_premium      NUMERIC(12,2) NOT NULL,  -- signed: negative = owed back to the insured
  notes               TEXT,
  performed_by        TEXT NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Per policy, like policy_endorsements' and unlike policy_vehicles': a
  -- policy has one cancellation in force at a time, not several concurrent
  -- ones. A superseded cancellation carries a closed (possibly empty) range.
  CONSTRAINT no_overlapping_policy_cancellations
    EXCLUDE USING gist (policy_id WITH =, effective_range WITH &&),
  CONSTRAINT policy_cancellations_short_rate_ck
    CHECK ((refund_method = 'pro_rata'   AND short_rate_factor IS NULL     AND short_rate_basis IS NULL)
        OR (refund_method = 'short_rate' AND short_rate_factor IS NOT NULL AND short_rate_basis IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_policy_cancellations_policy ON policy_cancellations(policy_id);

-- Append-only with the narrow escape hatch from the ADR 0016 addendum 2
-- rather than ALTER TABLE ... DISABLE TRIGGER - built this way from the
-- start rather than discovering both traps a third time.
-- One difference from the vehicle/driver/endorsement version of this
-- trigger, forced by what a corrected cancellation actually means: the
-- permitted mutation is emptying the range, not closing its upper bound.
-- Postgres normalises an empty range to 'empty', so lower(NEW) is NULL and
-- the "lower bound unchanged" test those triggers use cannot hold here. See
-- correct_policy_cancellation() for why emptying is the right supersession
-- for this table.
CREATE OR REPLACE FUNCTION reject_policy_cancellations_mutation()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND current_setting('luxauto.superseding_policy_cancellation', true) = 'on'
     AND isempty(NEW.effective_range)
     AND NOT isempty(OLD.effective_range)
     AND to_jsonb(NEW) - 'effective_range' = to_jsonb(OLD) - 'effective_range'
  THEN
    RETURN NEW;  -- correct_policy_cancellation() superseding this row
  END IF;

  RAISE EXCEPTION 'policy_cancellations is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER policy_cancellations_no_update
  BEFORE UPDATE ON policy_cancellations
  FOR EACH ROW EXECUTE FUNCTION reject_policy_cancellations_mutation();

CREATE OR REPLACE TRIGGER policy_cancellations_no_delete
  BEFORE DELETE ON policy_cancellations
  FOR EACH ROW EXECUTE FUNCTION reject_policy_cancellations_mutation();

-- Closes the policy's vehicle/driver snapshot rows at an instant. NOT
-- correct_policy_vehicle()/correct_policy_driver(): those exist to fix a
-- mistaken snapshot and therefore insert a replacement row and log a
-- '..._corrected' event. A cancellation creates no successor row - coverage
-- ends - and logging it as a correction would say the snapshot was wrong
-- when it was right until the policy stopped. What the two paths do share is
-- the mutation itself, and the append-only trigger already permits exactly
-- it: close the upper bound, lower bound and every other column unchanged.
--
-- GREATEST(lower, p_at) rather than p_at flat: a row that starts after the
-- cancellation (a future-dated correction) closes to its own start, an empty
-- range, rather than an invalid one with upper < lower.
CREATE OR REPLACE FUNCTION close_policy_coverage(p_policy_id UUID, p_at TIMESTAMPTZ)
RETURNS VOID AS $$
BEGIN
  PERFORM set_config('luxauto.superseding_policy_vehicle', 'on', true);
  UPDATE policy_vehicles
  SET effective_range = tstzrange(lower(effective_range), GREATEST(lower(effective_range), p_at))
  WHERE policy_id = p_policy_id
    AND (upper(effective_range) IS NULL OR upper(effective_range) > p_at)
    AND NOT isempty(effective_range);
  PERFORM set_config('luxauto.superseding_policy_vehicle', 'off', true);

  PERFORM set_config('luxauto.superseding_policy_driver', 'on', true);
  UPDATE policy_drivers
  SET effective_range = tstzrange(lower(effective_range), GREATEST(lower(effective_range), p_at))
  WHERE policy_id = p_policy_id
    AND (upper(effective_range) IS NULL OR upper(effective_range) > p_at)
    AND NOT isempty(effective_range);
  PERFORM set_config('luxauto.superseding_policy_driver', 'off', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- The cancellation itself: one transaction covering the refund calculation,
-- the coverage truncation, the vehicle/driver closeout, the cancellation
-- record and the audit event. A cancellation that adjusted premium but left
-- vehicles in force (or the reverse) is exactly the partial state ADR 0010's
-- write discipline exists to prevent, so it is one function, not a sequence
-- a caller is trusted to complete.
--
-- Overloads ADR 0012's cancel_policy(UUID, TEXT, TEXT) rather than replacing
-- it, the same composition ADR 0014 used for calculate_premium_waterfall.
-- The old signature now raises: it has nowhere to put the initiator, and the
-- initiator is what decides pro-rata vs short-rate.
CREATE OR REPLACE FUNCTION cancel_policy(
  p_policy_id UUID,
  p_cancellation_type cancellation_type_t,
  p_reason_code TEXT,
  p_refund_method refund_method_t,
  p_cancelled_at TIMESTAMPTZ,
  p_notes TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_status policy_status_t;
  v_term TSTZRANGE;
  v_at TIMESTAMPTZ;
  v_state CHAR(2);
  v_program_id UUID;
  v_written NUMERIC;
  v_elapsed NUMERIC;
  v_unearned NUMERIC;
  v_factor NUMERIC;
  v_basis short_rate_basis_t;
  v_return NUMERIC;
  v_cancellation_id UUID;
BEGIN
  SELECT status, effective_range INTO v_status, v_term
  FROM policies
  WHERE policy_id = p_policy_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel_policy: policy % does not exist', p_policy_id;
  END IF;

  -- Same precondition ADR 0012 set, unchanged: cancelling a non-active
  -- policy either duplicates an event that already happened or silently
  -- reinterprets an expired/nonrenewed policy as newly cancelled.
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'cancel_policy: policy % is not active (current status: %)', p_policy_id, v_status;
  END IF;

  IF p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
    RAISE EXCEPTION 'CANCELLATION_REASON_CODE_REQUIRED: cancelling policy % requires a reason_code', p_policy_id
      USING HINT = 'Use a coded reason the way the referral matrix and decision_log do (e.g. CX_INSURED_REQUEST, CX_NONPAYMENT, CX_UNDERWRITING_INELIGIBLE). Prose belongs in notes.';
  END IF;

  v_at := COALESCE(p_cancelled_at, now());

  IF NOT (v_term @> v_at) THEN
    RAISE EXCEPTION 'CANCELLATION_DATE_OUTSIDE_TERM: cancellation date % is not inside policy %''s term %', v_at, p_policy_id, v_term
      USING HINT = 'A cancellation ends coverage partway through a term; a date outside it is either a typo or a different event (expiry, nonrenewal), which this function deliberately does not handle.';
  END IF;

  SELECT a.garaging_state, q.program_id, q.premium_amount
    INTO v_state, v_program_id, v_written
  FROM policies p
  JOIN quotes q ON q.quote_id = p.quote_id
  JOIN applications a ON a.application_id = q.application_id
  WHERE p.policy_id = p_policy_id;

  v_unearned := policy_unearned_premium(p_policy_id, v_term, v_at);

  IF p_refund_method = 'short_rate' THEN
    v_elapsed := EXTRACT(EPOCH FROM (v_at - lower(v_term)))
                 / EXTRACT(EPOCH FROM (upper(v_term) - lower(v_term)));
    SELECT f.factor, f.basis INTO v_factor, v_basis
    FROM short_rate_factor(v_state, v_program_id, p_cancellation_type, v_elapsed, v_at) f;

    v_return := CASE v_basis
      WHEN 'unearned_premium_multiplier'        THEN -ROUND(v_unearned * v_factor, 2)
      WHEN 'percent_of_annual_premium_returned' THEN -ROUND(v_written  * v_factor, 2)
    END;
  ELSE
    -- Pro-rata: pure arithmetic, no filed table, nothing to configure.
    v_return := -v_unearned;
  END IF;

  PERFORM close_policy_coverage(p_policy_id, v_at);

  UPDATE policies
  SET status = 'cancelled',
      effective_range = tstzrange(lower(v_term), v_at)
  WHERE policy_id = p_policy_id;

  INSERT INTO policy_cancellations (
    policy_id, effective_range, cancellation_type, reason_code, refund_method,
    short_rate_factor, short_rate_basis, unearned_premium, return_premium, notes, performed_by
  )
  VALUES (
    p_policy_id, tstzrange(v_at, upper(v_term)), p_cancellation_type, p_reason_code, p_refund_method,
    v_factor, v_basis, v_unearned, v_return, p_notes, p_performed_by
  )
  RETURNING cancellation_id INTO v_cancellation_id;

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (p_policy_id, 'cancelled', p_performed_by,
          format('%s cancellation (%s), %s return premium %s: %s',
                 p_cancellation_type, p_reason_code, p_refund_method, v_return, COALESCE(p_notes, '')));

  RETURN v_cancellation_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Resolves a cancellation into the three raw inputs the shared waterfall
-- arithmetic takes, exactly as calculate_endorsement_waterfall() does for an
-- endorsement (ADR 0014 section 5). The return premium is negative, so every
-- participant's gross_share/commission_amount/net_due comes back negative in
-- proportion to their share - money owed back, split the way the premium was
-- split. as_of is the cancellation date: the panel in force when coverage
-- ended is the panel that owes the refund.
CREATE OR REPLACE FUNCTION calculate_cancellation_waterfall(p_cancellation_id UUID)
RETURNS TABLE (
  participant_id      UUID,
  participant_name    TEXT,
  participant_type    participant_type_t,
  share_percentage    NUMERIC(5,2),
  commission_rate     NUMERIC(5,2),
  gross_share          NUMERIC(14,2),
  commission_amount    NUMERIC(14,2),
  net_due               NUMERIC(14,2)
) AS $$
  SELECT w.*
  FROM policy_cancellations c
  JOIN policies p ON p.policy_id = c.policy_id
  JOIN quotes q ON q.quote_id = p.quote_id
  CROSS JOIN LATERAL calculate_premium_waterfall(q.program_id, c.return_premium, lower(c.effective_range)) w
  WHERE c.cancellation_id = p_cancellation_id
    AND NOT isempty(c.effective_range);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Corrects a cancellation entered with the wrong date, initiator, reason or
-- refund method - same close-the-old-row-then-insert shape as
-- correct_policy_endorsement()/correct_policy_vehicle(), with the refund
-- recomputed against the ORIGINAL term (preserved as the old row's upper
-- bound) rather than the already-truncated policies row.
--
-- Not a reinstatement. "This cancellation should never have happened" puts a
-- policy back in force, which is a different business event with its own
-- questions (does coverage apply to the gap? is a new policy issued?) - ADR
-- 0018 names it as deferred rather than approximating it here.
--
-- Supersession here EMPTIES the old row rather than closing it at the new
-- row's start, which is where this function deliberately departs from
-- correct_policy_endorsement()/correct_policy_vehicle(). Those correct a
-- period fact: an endorsement really was in force from its start until the
-- correction took over, so splitting the range at that point is true. A
-- cancellation is a point event whose range describes the unearned period
-- ONE refund was computed over. Closing a cancellation dated 9 February at
-- 30 April would assert that a refund covering February-to-term-end actually
-- covered February-to-April - a number nobody computed. "This cancellation
-- applied for zero time; here is the one that replaced it" is the only
-- accurate statement, and it keeps the exclusion constraint meaning exactly
-- "at most one cancellation in force", since empty ranges overlap nothing.
-- Correcting to an earlier date also has no valid closed range available at
-- all (upper < lower errors), so this is the only shape that works in both
-- directions.
CREATE OR REPLACE FUNCTION correct_policy_cancellation(
  p_cancellation_id UUID,
  p_new_cancelled_at TIMESTAMPTZ,
  p_new_cancellation_type cancellation_type_t,
  p_new_reason_code TEXT,
  p_new_refund_method refund_method_t,
  p_new_notes TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_policy_id UUID;
  v_old_range TSTZRANGE;
  v_old_at TIMESTAMPTZ;
  v_term TSTZRANGE;
  v_state CHAR(2);
  v_program_id UUID;
  v_written NUMERIC;
  v_elapsed NUMERIC;
  v_unearned NUMERIC;
  v_factor NUMERIC;
  v_basis short_rate_basis_t;
  v_return NUMERIC;
  v_new_id UUID;
BEGIN
  SELECT policy_id, effective_range INTO v_policy_id, v_old_range
  FROM policy_cancellations
  WHERE cancellation_id = p_cancellation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'correct_policy_cancellation: cancellation % does not exist', p_cancellation_id;
  END IF;

  IF p_new_reason_code IS NULL OR btrim(p_new_reason_code) = '' THEN
    RAISE EXCEPTION 'CANCELLATION_REASON_CODE_REQUIRED: correcting cancellation % requires a reason_code', p_cancellation_id
      USING HINT = 'A corrected cancellation still has to say why, in the same coded form as the original.';
  END IF;

  v_old_at := lower(v_old_range);

  -- The original term: the cancellation row's own range ends where the term
  -- did, which is why it is stored that way (see the table comment).
  SELECT tstzrange(lower(p.effective_range), upper(v_old_range))
    INTO v_term
  FROM policies p
  WHERE p.policy_id = v_policy_id;

  IF NOT (v_term @> p_new_cancelled_at) THEN
    RAISE EXCEPTION 'CANCELLATION_DATE_OUTSIDE_TERM: corrected cancellation date % is not inside policy %''s original term %', p_new_cancelled_at, v_policy_id, v_term
      USING HINT = 'Corrections move a cancellation within the policy term; a date outside it is a different event.';
  END IF;

  SELECT a.garaging_state, q.program_id, q.premium_amount
    INTO v_state, v_program_id, v_written
  FROM policies p
  JOIN quotes q ON q.quote_id = p.quote_id
  JOIN applications a ON a.application_id = q.application_id
  WHERE p.policy_id = v_policy_id;

  v_unearned := policy_unearned_premium(v_policy_id, v_term, p_new_cancelled_at);

  IF p_new_refund_method = 'short_rate' THEN
    v_elapsed := EXTRACT(EPOCH FROM (p_new_cancelled_at - lower(v_term)))
                 / EXTRACT(EPOCH FROM (upper(v_term) - lower(v_term)));
    SELECT f.factor, f.basis INTO v_factor, v_basis
    FROM short_rate_factor(v_state, v_program_id, p_new_cancellation_type, v_elapsed, p_new_cancelled_at) f;

    v_return := CASE v_basis
      WHEN 'unearned_premium_multiplier'        THEN -ROUND(v_unearned * v_factor, 2)
      WHEN 'percent_of_annual_premium_returned' THEN -ROUND(v_written  * v_factor, 2)
    END;
  ELSE
    v_return := -v_unearned;
  END IF;

  PERFORM set_config('luxauto.superseding_policy_cancellation', 'on', true);
  UPDATE policy_cancellations
  SET effective_range = tstzrange(v_old_at, v_old_at)  -- empty: superseded entirely
  WHERE cancellation_id = p_cancellation_id;
  PERFORM set_config('luxauto.superseding_policy_cancellation', 'off', true);

  INSERT INTO policy_cancellations (
    policy_id, effective_range, cancellation_type, reason_code, refund_method,
    short_rate_factor, short_rate_basis, unearned_premium, return_premium, notes, performed_by
  )
  VALUES (
    v_policy_id, tstzrange(p_new_cancelled_at, upper(v_term)), p_new_cancellation_type, p_new_reason_code,
    p_new_refund_method, v_factor, v_basis, v_unearned, v_return, p_new_notes, p_performed_by
  )
  RETURNING cancellation_id INTO v_new_id;

  -- Coverage follows the corrected date: the policy term, and any snapshot
  -- row the original cancellation closed at the old date, both move. Rows
  -- closed at the old date are matched exactly, so a vehicle that had
  -- already ended earlier for its own reasons is left alone.
  UPDATE policies
  SET effective_range = tstzrange(lower(v_term), p_new_cancelled_at)
  WHERE policy_id = v_policy_id;

  PERFORM set_config('luxauto.superseding_policy_vehicle', 'on', true);
  UPDATE policy_vehicles
  SET effective_range = tstzrange(lower(effective_range), GREATEST(lower(effective_range), p_new_cancelled_at))
  WHERE policy_id = v_policy_id AND upper(effective_range) = v_old_at;
  PERFORM set_config('luxauto.superseding_policy_vehicle', 'off', true);

  PERFORM set_config('luxauto.superseding_policy_driver', 'on', true);
  UPDATE policy_drivers
  SET effective_range = tstzrange(lower(effective_range), GREATEST(lower(effective_range), p_new_cancelled_at))
  WHERE policy_id = v_policy_id AND upper(effective_range) = v_old_at;
  PERFORM set_config('luxauto.superseding_policy_driver', 'off', true);

  -- And anything still open past the corrected date (a later correction date
  -- reopens nothing, but an earlier one can leave rows running long).
  PERFORM close_policy_coverage(v_policy_id, p_new_cancelled_at);

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (v_policy_id, 'cancellation_corrected', p_performed_by,
          format('Corrected cancellation %s with new cancellation %s (%s, %s, return premium %s)',
                 p_cancellation_id, v_new_id, p_new_cancellation_type, p_new_refund_method, v_return));

  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- REINSTATEMENT, BACKDATED-AS-NEW-BUSINESS (ADR 0024)
-- Business-confirmed mechanism: a reinstatement is ALWAYS new business - a new
-- policy bound through the ordinary ADR 0023 path (bind_policy +
-- link_reinstated_policy) - with its inception BACKDATED to the gap start (the
-- prior policy's cancellation effective date) so coverage is continuous, at
-- FULL annual premium with no proration. The original cancelled policy and its
-- term never survive; there is no gap-only charge.
--
-- This SUPERSEDES the gap-only design first built under ADR 0024 (reverse the
-- same cancellation, charge only the gap days on the surviving policy). That
-- design was proposed, built and tested, then REJECTED on business review: a
-- policy on risk for only 10-14 days against a $1M+ limit is a risk/premium
-- mismatch the carrier will not take. See ADR 0024 for the full rejected-design
-- record and why it isn't what shipped.
--
-- Backdating is offered only within 14 days of the cancellation effective date.
-- Past 14 days there is no backdating: it is ordinary new business at today's
-- inception, which plain bind_policy + link_reinstated_policy already handle
-- with no new code. So reinstate_policy() is the <=14-day backdated case ONLY,
-- and rejects a stale request rather than silently binding at a different
-- inception than it was asked for.
-- ============================================================================

-- Append-only audit of every backdated reinstatement. It records the LINK-AND-
-- ATTESTATION event - which new policy reinstated which prior one, off which
-- cancellation, on whose signed no-known-loss attestation - NOT a charge: the
-- premium is the new policy's own full annual premium, carried on its
-- policies/quote rows like any other new business. The signed attestation
-- DOCUMENT itself lives in the underwriting document store (a DMS/file-taxonomy
-- concern, not a schema one); this row holds the reference/pointer to it plus
-- the audit facts the database is responsible for. Same append-only discipline
-- as policy_events/program_coverage_gaps, and no supersession hatch: a
-- reinstatement is a point event, never "corrected" into another one. cancellation_id
-- is UNIQUE - a cancellation is reinstated at most once.
CREATE TABLE IF NOT EXISTS policy_reinstatements (
  reinstatement_id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  new_policy_id         UUID NOT NULL REFERENCES policies(policy_id),
  prior_policy_id       UUID NOT NULL REFERENCES policies(policy_id),
  cancellation_id       UUID NOT NULL UNIQUE REFERENCES policy_cancellations(cancellation_id),
  -- The prior policy's cancellation effective date: the date coverage lapsed,
  -- and the new policy's backdated inception (they are the same instant, which
  -- is the whole point - zero gap).
  gap_start             TIMESTAMPTZ NOT NULL,
  -- Pointer to the signed no-known-loss attestation in the underwriting doc
  -- store; required for every backdated reinstatement.
  attestation_reference TEXT NOT NULL,
  performed_by          TEXT NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- A reinstatement links two DIFFERENT policies (new succeeds prior), mirroring
  -- policies_no_self_reinstatement.
  CONSTRAINT policy_reinstatements_distinct_ck CHECK (new_policy_id <> prior_policy_id)
);

CREATE INDEX IF NOT EXISTS idx_policy_reinstatements_new ON policy_reinstatements(new_policy_id);
CREATE INDEX IF NOT EXISTS idx_policy_reinstatements_prior ON policy_reinstatements(prior_policy_id);

-- Pure append-only, no escape hatch: there is no supersession shape to permit.
CREATE OR REPLACE FUNCTION reject_policy_reinstatements_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'policy_reinstatements is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER policy_reinstatements_no_update
  BEFORE UPDATE ON policy_reinstatements
  FOR EACH ROW EXECUTE FUNCTION reject_policy_reinstatements_mutation();

CREATE OR REPLACE TRIGGER policy_reinstatements_no_delete
  BEFORE DELETE ON policy_reinstatements
  FOR EACH ROW EXECUTE FUNCTION reject_policy_reinstatements_mutation();

-- The reinstatement wrapper: one atomic transaction that binds the returning
-- customer's already-issued quote as NEW business backdated to the gap start,
-- links the new policy to the prior cancelled one, and records the audit row.
--
-- A thin wrapper over the existing primitives (bind_policy, link_reinstated_policy)
-- rather than a widened bind_policy(): the reinstatement-specific preconditions
-- - the 14-day window, the required attestation, one-reinstatement-per-cancellation
-- - live here, and the common bind path stays a general primitive. Same
-- separation ADR 0023 chose, avoiding the overload trap ADR 0021's addendum
-- documented.
--
-- Takes the SOURCE cancellation, not a policy_id: that row carries the gap start
-- (its effective-range lower bound, the date coverage lapsed) and the prior
-- policy (its policy_id). p_quote_id is the returning customer's fresh, issued
-- quote - reinstatement is new business, re-keyed through a fresh application
-- exactly like ADR 0023's path. Returns the NEW policy's id.
CREATE OR REPLACE FUNCTION reinstate_policy(
  p_quote_id UUID,
  p_cancellation_id UUID,
  p_policy_number TEXT,
  p_attestation_reference TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_cx_range TSTZRANGE;
  v_prior_policy_id UUID;
  v_gap_start TIMESTAMPTZ;
  v_new_policy_id UUID;
BEGIN
  -- Lock the source cancellation. Its gap start and prior policy drive the rest,
  -- and the lock makes a concurrent second reinstatement of the same cancellation
  -- block here rather than race the one-per-cancellation check below.
  SELECT policy_id, effective_range INTO v_prior_policy_id, v_cx_range
  FROM policy_cancellations
  WHERE cancellation_id = p_cancellation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'REINSTATEMENT_CANCELLATION_NOT_FOUND: cancellation % does not exist', p_cancellation_id
      USING HINT = 'Pass the cancellation_id of the policy being reinstated - the row whose effective range starts at the date coverage lapsed.';
  END IF;

  -- A superseded/voided cancellation (emptied by a correction) has a NULL gap
  -- start and is not the one in force; reinstating off it would backdate to a
  -- date nobody actually cancelled at.
  IF isempty(v_cx_range) THEN
    RAISE EXCEPTION 'REINSTATEMENT_CANCELLATION_NOT_IN_FORCE: cancellation % has an empty effective_range - it was superseded by a correction, so it is not the cancellation in force', p_cancellation_id
      USING HINT = 'Reinstate off the cancellation actually in force for the policy (the one with a non-empty effective_range).';
  END IF;

  -- One reinstatement per cancellation. Checked explicitly for a clear message;
  -- the UNIQUE(cancellation_id) on policy_reinstatements is the backstop against
  -- a raw insert.
  IF EXISTS (SELECT 1 FROM policy_reinstatements WHERE cancellation_id = p_cancellation_id) THEN
    RAISE EXCEPTION 'REINSTATEMENT_ALREADY_EXISTS: cancellation % has already been reinstated', p_cancellation_id
      USING HINT = 'A cancellation is reinstated at most once. If the reinstating policy is itself wrong, that is a fresh cancellation on the new policy, not a second reinstatement of this one.';
  END IF;

  -- Attestation required unconditionally - the signed no-known/unreported-loss
  -- confirmation that makes backdated coverage safe, with no elapsed-time
  -- carve-outs. Same required-reason-code discipline cancel_policy() applies.
  IF p_attestation_reference IS NULL OR btrim(p_attestation_reference) = '' THEN
    RAISE EXCEPTION 'REINSTATEMENT_ATTESTATION_REQUIRED: reinstating cancellation % requires a no-known-loss attestation reference', p_cancellation_id
      USING HINT = 'Record the reference/pointer of the signed no-known-loss attestation held in the underwriting document store. It is required for every backdated reinstatement.';
  END IF;

  v_gap_start := lower(v_cx_range);

  -- The 14-day backdating window, measured from the date coverage lapsed to now.
  -- Past it there is no backdating: that is ordinary new business at today's
  -- inception (plain bind_policy + link_reinstated_policy), which this wrapper
  -- deliberately does NOT silently do - it rejects, rather than binding at an
  -- inception other than the gap start it was asked for.
  IF now() - v_gap_start > interval '14 days' THEN
    RAISE EXCEPTION 'REINSTATEMENT_WINDOW_EXPIRED: coverage lapsed at % (over 14 days ago), past the backdating window', v_gap_start
      USING HINT = 'Backdated reinstatement is available only within 14 days of the cancellation effective date. Past that, bind ordinary new business at today''s inception (bind_policy + link_reinstated_policy) - that is not a backdated reinstatement and does not go through this function.';
  END IF;

  -- Bind the issued quote as new business, inception pinned to the gap start so
  -- coverage is continuous. Full annual premium, no proration - bind_policy
  -- carries the quote's premium unchanged for a backdated term.
  v_new_policy_id := bind_policy(p_quote_id, p_policy_number, p_performed_by, v_gap_start);

  -- Link the new policy to the prior cancelled one. Unchanged from ADR 0023: it
  -- enforces that the prior policy is cancelled and that the link is set once.
  -- If the prior policy is not cancelled this RAISEs and the whole wrapper rolls
  -- back - nothing partial survives.
  PERFORM link_reinstated_policy(v_new_policy_id, v_prior_policy_id, p_performed_by);

  INSERT INTO policy_reinstatements (
    new_policy_id, prior_policy_id, cancellation_id, gap_start, attestation_reference, performed_by
  )
  VALUES (
    v_new_policy_id, v_prior_policy_id, p_cancellation_id, v_gap_start, p_attestation_reference, p_performed_by
  );

  -- link_reinstated_policy() already logs the linkage on both policies; this adds
  -- the reinstatement-specific facts (backdated inception, attestation) on the
  -- new policy.
  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (v_new_policy_id, 'reinstated', p_performed_by,
          format('backdated reinstatement of cancelled policy %s: inception %s (gap start), full annual premium, attestation %s',
                 v_prior_policy_id, v_gap_start, p_attestation_reference));

  RETURN v_new_policy_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- NONRENEWAL AND EXPIRATION (ADR 0019)
-- The two remaining ways a policy stops, after ADR 0018's cancellation.
-- policy_status_t has carried 'expired' and 'nonrenewed' since ADR 0010 and
-- nothing ever set either one; cancel_policy() was the only status
-- transition in the schema.
--
-- The split: nonrenewal is a carrier DECISION, recorded when it is made and
-- taking effect when the term ends. Expiration is what happens when a term
-- ends and nobody decided anything. So one scheduled function owns both
-- term-end transitions, and it picks which status to write based on whether
-- a nonrenewal decision was recorded - see ADR 0019 sections 2 and 3.
-- ============================================================================

-- Deliberately empty, exactly like short_rate_factors (ADR 0018). Nonrenewal
-- notice periods are state-regulated - commonly 30-60+ days of advance
-- written notice, varying by state and sometimes by how long the insured has
-- been with the carrier - and the governing number comes from a filed rule or
-- a DOI bulletin, not from general knowledge. This table is the shape those
-- requirements load into; it ships with no rows, and
-- nonrenewal_notice_days() below refuses rather than assuming one.
CREATE TABLE IF NOT EXISTS nonrenewal_notice_requirements (
  notice_requirement_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  state                   CHAR(2) NOT NULL,
  -- NULL means "any program in this state"; a program-specific row wins.
  program_id              UUID REFERENCES insurance_programs(program_id),
  notice_days             SMALLINT NOT NULL,
  -- The mechanism for tenure-banded requirements (a state requiring longer
  -- notice once an insured has been with the carrier N years). NULL means the
  -- requirement applies regardless of tenure. Note that until renewal exists
  -- (explicitly out of scope, ADR 0019), a policy's tenure is just its own
  -- age, so this is always well under one year in practice - the column is
  -- here so a real filed banded requirement can be represented at all, not
  -- because anything can currently exceed the lowest band.
  min_policy_years        SMALLINT,
  effective_range         TSTZRANGE NOT NULL,
  -- Provenance, same discipline as short_rate_factors and
  -- state_rating_table_versions: a notice period with no filing behind it is
  -- what this table exists to prevent.
  serff_filing_tracking_number TEXT,
  regulatory_reference    TEXT NOT NULL,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT nonrenewal_notice_requirements_days_ck CHECK (notice_days >= 0),
  CONSTRAINT nonrenewal_notice_requirements_years_ck CHECK (min_policy_years IS NULL OR min_policy_years >= 0)
);

CREATE INDEX IF NOT EXISTS idx_nonrenewal_notice_requirements_state
  ON nonrenewal_notice_requirements(state);

-- Returns the filed notice requirement, or raises. Never returns a default:
-- "no filed requirement loaded" and "the filed requirement is zero days" are
-- different answers and only one of them is safe to act on.
CREATE OR REPLACE FUNCTION nonrenewal_notice_days(
  p_state CHAR(2),
  p_program_id UUID,
  p_policy_years NUMERIC,
  p_as_of TIMESTAMPTZ
) RETURNS SMALLINT AS $$
DECLARE
  v_days SMALLINT;
BEGIN
  SELECT r.notice_days INTO v_days
  FROM nonrenewal_notice_requirements r
  WHERE r.state = p_state
    AND (r.program_id IS NULL OR r.program_id = p_program_id)
    AND (r.min_policy_years IS NULL OR r.min_policy_years <= p_policy_years)
    AND r.effective_range @> p_as_of
  -- Most specific wins: program-specific over statewide, then the highest
  -- tenure band the policy actually qualifies for.
  ORDER BY (r.program_id IS NOT NULL) DESC, r.min_policy_years DESC NULLS LAST
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NONRENEWAL_NOTICE_REQUIREMENT_NOT_CONFIGURED: no filed nonrenewal notice requirement loaded for state %, program %, policy tenure % years, as of %',
      p_state, p_program_id, ROUND(p_policy_years, 2), p_as_of
      USING HINT = 'Nonrenewal notice periods are state-regulated. Load nonrenewal_notice_requirements from the actual filed rule or DOI bulletin for this state before issuing a nonrenewal - this schema will not assume a notice period on a decision that has to be defensible to a regulator.';
  END IF;

  RETURN v_days;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- The nonrenewal decision itself. effective_range is [notice given, term end)
-- - the notice window the decision covers - which mirrors how
-- policy_cancellations stores its unearned window and gives the correction
-- path the original term end after the fact.
CREATE TABLE IF NOT EXISTS policy_nonrenewals (
  nonrenewal_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id           UUID NOT NULL REFERENCES policies(policy_id),
  effective_range     TSTZRANGE NOT NULL,
  reason_code         TEXT NOT NULL,
  -- What the filed requirement was, and what was actually given, both
  -- recorded at decision time: the validation below is only as good as the
  -- table it read, and a later audit needs to see which number it used.
  notice_days_required SMALLINT NOT NULL,
  notice_days_given   INTEGER NOT NULL,
  notes               TEXT,
  performed_by        TEXT NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Per policy, like policy_cancellations': a policy has one nonrenewal
  -- decision in force at a time. A superseded decision carries an empty
  -- range, which overlaps nothing.
  CONSTRAINT no_overlapping_policy_nonrenewals
    EXCLUDE USING gist (policy_id WITH =, effective_range WITH &&)
);

CREATE INDEX IF NOT EXISTS idx_policy_nonrenewals_policy ON policy_nonrenewals(policy_id);

-- Append-only, with the narrow transaction-local-flag escape hatch from ADR
-- 0016 addendum 2 and the empty-range shape from addendum 3 - both applied
-- from the start rather than rediscovered. Permitted shapes: closing the
-- upper bound, or emptying a non-empty row. Never a DELETE.
CREATE OR REPLACE FUNCTION reject_policy_nonrenewals_mutation()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND current_setting('luxauto.superseding_policy_nonrenewal', true) = 'on'
     AND NOT isempty(OLD.effective_range)
     AND (isempty(NEW.effective_range)
          OR lower(NEW.effective_range) IS NOT DISTINCT FROM lower(OLD.effective_range))
     AND to_jsonb(NEW) - 'effective_range' = to_jsonb(OLD) - 'effective_range'
  THEN
    RETURN NEW;  -- correct_policy_nonrenewal() superseding this row
  END IF;

  RAISE EXCEPTION 'policy_nonrenewals is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER policy_nonrenewals_no_update
  BEFORE UPDATE ON policy_nonrenewals
  FOR EACH ROW EXECUTE FUNCTION reject_policy_nonrenewals_mutation();

CREATE OR REPLACE TRIGGER policy_nonrenewals_no_delete
  BEFORE DELETE ON policy_nonrenewals
  FOR EACH ROW EXECUTE FUNCTION reject_policy_nonrenewals_mutation();

-- Records a decision not to renew. Does NOT change policies.status: the
-- policy is still in force until its term ends, and 'active' in this schema
-- means in force (cancel_policy() refuses anything else, and an insured who
-- has just received a nonrenewal notice can still cancel mid-term). The
-- status flip to 'nonrenewed' happens at term end, in expire_policies()
-- below, which is also what keeps nonrenewal and expiration from being two
-- mechanisms that could disagree about the same instant. See ADR 0019
-- section 2.
CREATE OR REPLACE FUNCTION nonrenew_policy(
  p_policy_id UUID,
  p_reason_code TEXT,
  p_notice_at TIMESTAMPTZ,
  p_notes TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_status policy_status_t;
  v_term TSTZRANGE;
  v_at TIMESTAMPTZ;
  v_state CHAR(2);
  v_program_id UUID;
  v_policy_years NUMERIC;
  v_required SMALLINT;
  v_given INTEGER;
  v_nonrenewal_id UUID;
BEGIN
  SELECT status, effective_range INTO v_status, v_term
  FROM policies
  WHERE policy_id = p_policy_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'nonrenew_policy: policy % does not exist', p_policy_id;
  END IF;

  -- Same precondition discipline as bind/cancel: a cancelled, expired or
  -- already-nonrenewed policy has reached a terminal state, and deciding not
  -- to renew it is either a duplicate or a misreading of what happened.
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'nonrenew_policy: policy % is not active (current status: %)', p_policy_id, v_status;
  END IF;

  IF p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
    RAISE EXCEPTION 'NONRENEWAL_REASON_CODE_REQUIRED: nonrenewing policy % requires a reason_code', p_policy_id
      USING HINT = 'Use a coded reason the way the referral matrix, decision_log and cancellations do (e.g. NR_LOSS_HISTORY, NR_APPETITE_EXIT, NR_UNDERWRITING_INELIGIBLE). Prose belongs in notes.';
  END IF;

  IF upper(v_term) IS NULL THEN
    RAISE EXCEPTION 'NONRENEWAL_UNBOUNDED_TERM: policy % has no term end (%), so there is nothing to decline to renew', p_policy_id, v_term
      USING HINT = 'A nonrenewal is a decision about what happens when a term ends. Fix the policy term first.';
  END IF;

  v_at := COALESCE(p_notice_at, now());

  IF NOT (v_term @> v_at) THEN
    RAISE EXCEPTION 'NONRENEWAL_DATE_OUTSIDE_TERM: notice date % is not inside policy %''s term %', v_at, p_policy_id, v_term
      USING HINT = 'Notice is given while the policy is in force. A date after the term end is a decision about a policy that has already ended; a date before it is a typo.';
  END IF;

  IF EXISTS (SELECT 1 FROM policy_nonrenewals n
             WHERE n.policy_id = p_policy_id AND NOT isempty(n.effective_range)) THEN
    RAISE EXCEPTION 'NONRENEWAL_ALREADY_RECORDED: policy % already has a nonrenewal decision in force', p_policy_id
      USING HINT = 'Use correct_policy_nonrenewal() to change the notice date, reason or notes of the existing decision.';
  END IF;

  SELECT a.garaging_state, q.program_id INTO v_state, v_program_id
  FROM policies p
  JOIN quotes q ON q.quote_id = p.quote_id
  JOIN applications a ON a.application_id = q.application_id
  WHERE p.policy_id = p_policy_id;

  -- ADR 0033 (Flag B, a scoped one-line relaxation of ADR 0019's "do not touch"):
  -- tenure is CUMULATIVE across chained renewals, not this term's own age, so
  -- nonrenewal_notice_requirements.min_policy_years is finally reachable. This is
  -- byte-identical for any policy with no renewal history (original_policy_id is
  -- NULL -> policy_tenure_years measures from this policy's own inception, the
  -- same v_at - lower(v_term) it computed before). correct_policy_nonrenewal
  -- still uses the inline own-age formula (its ADR 0019 protection was NOT
  -- relaxed) - a documented inconsistency flagged for a follow-up decision.
  v_policy_years := policy_tenure_years(p_policy_id, v_at);
  v_required := nonrenewal_notice_days(v_state, v_program_id, v_policy_years, v_at);
  v_given := FLOOR(EXTRACT(EPOCH FROM (upper(v_term) - v_at)) / 86400);

  IF v_given < v_required THEN
    RAISE EXCEPTION 'NONRENEWAL_NOTICE_TOO_SHORT: policy % requires % days notice in %, but notice at % leaves only % days before the term ends at %',
      p_policy_id, v_required, v_state, v_at, v_given, upper(v_term)
      USING HINT = 'Issue the notice earlier, or let the policy run to term and expire. A nonrenewal recorded with insufficient notice is not enforceable and this schema will not record one.';
  END IF;

  INSERT INTO policy_nonrenewals (
    policy_id, effective_range, reason_code, notice_days_required, notice_days_given, notes, performed_by
  )
  VALUES (
    p_policy_id, tstzrange(v_at, upper(v_term)), p_reason_code, v_required, v_given, p_notes, p_performed_by
  )
  RETURNING nonrenewal_id INTO v_nonrenewal_id;

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (p_policy_id, 'nonrenewal_noticed', p_performed_by,
          format('Nonrenewal notice (%s), %s days given against %s required, effective at term end %s: %s',
                 p_reason_code, v_given, v_required, upper(v_term), COALESCE(p_notes, '')));

  RETURN v_nonrenewal_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Corrects a nonrenewal recorded with the wrong notice date, reason or
-- notes. Supersedes by EMPTYING the old row, the same choice
-- correct_policy_cancellation() made and for the same reason: a nonrenewal
-- is a point decision whose range describes the notice window ONE decision
-- covered, not a period fact that was true until the correction took over.
-- It is also the shape that works in both directions - the earlier-date case
-- that ADR 0016 addendum 3 had to fix in four other correction functions
-- cannot arise here, because no shortened range is ever constructed.
--
-- Re-validates the corrected notice date against the filed requirement: a
-- correction that moved the notice later could otherwise slip under the
-- notice period the original satisfied.
--
-- Not a withdrawal. "This nonrenewal should never have been issued" means
-- the policy renews after all, which is renewal - explicitly out of scope
-- for ADR 0019 and undesigned.
CREATE OR REPLACE FUNCTION correct_policy_nonrenewal(
  p_nonrenewal_id UUID,
  p_new_notice_at TIMESTAMPTZ,
  p_new_reason_code TEXT,
  p_new_notes TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_policy_id UUID;
  v_old_range TSTZRANGE;
  v_old_at TIMESTAMPTZ;
  v_term TSTZRANGE;
  v_state CHAR(2);
  v_program_id UUID;
  v_policy_years NUMERIC;
  v_required SMALLINT;
  v_given INTEGER;
  v_new_id UUID;
BEGIN
  SELECT policy_id, effective_range INTO v_policy_id, v_old_range
  FROM policy_nonrenewals
  WHERE nonrenewal_id = p_nonrenewal_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'correct_policy_nonrenewal: nonrenewal % does not exist', p_nonrenewal_id;
  END IF;

  IF isempty(v_old_range) THEN
    RAISE EXCEPTION 'correct_policy_nonrenewal: nonrenewal % has already been superseded', p_nonrenewal_id
      USING HINT = 'Correct the nonrenewal that is currently in force for this policy, not one a previous correction already replaced.';
  END IF;

  IF p_new_reason_code IS NULL OR btrim(p_new_reason_code) = '' THEN
    RAISE EXCEPTION 'NONRENEWAL_REASON_CODE_REQUIRED: correcting nonrenewal % requires a reason_code', p_nonrenewal_id
      USING HINT = 'A corrected nonrenewal still has to say why, in the same coded form as the original.';
  END IF;

  v_old_at := lower(v_old_range);

  -- The term: the policy's own start, and the term end preserved as this
  -- row's upper bound (the policy row is not truncated by a nonrenewal, but
  -- reading it from the record keeps this symmetric with
  -- correct_policy_cancellation()).
  SELECT tstzrange(lower(p.effective_range), upper(v_old_range)) INTO v_term
  FROM policies p WHERE p.policy_id = v_policy_id;

  IF NOT (v_term @> p_new_notice_at) THEN
    RAISE EXCEPTION 'NONRENEWAL_DATE_OUTSIDE_TERM: corrected notice date % is not inside policy %''s term %', p_new_notice_at, v_policy_id, v_term
      USING HINT = 'A correction moves the notice date within the term the policy actually ran.';
  END IF;

  SELECT a.garaging_state, q.program_id INTO v_state, v_program_id
  FROM policies p
  JOIN quotes q ON q.quote_id = p.quote_id
  JOIN applications a ON a.application_id = q.application_id
  WHERE p.policy_id = v_policy_id;

  -- ADR 0033 (Flag B, extended): cumulative tenure, matching nonrenew_policy, so
  -- correcting a nonrenewal validates against the same tenure basis issuing one
  -- does - no divergence. Byte-identical for any no-renewal-history policy
  -- (original_policy_id NULL -> own inception, the same p_new_notice_at -
  -- lower(v_term) as before).
  v_policy_years := policy_tenure_years(v_policy_id, p_new_notice_at);
  v_required := nonrenewal_notice_days(v_state, v_program_id, v_policy_years, p_new_notice_at);
  v_given := FLOOR(EXTRACT(EPOCH FROM (upper(v_term) - p_new_notice_at)) / 86400);

  IF v_given < v_required THEN
    RAISE EXCEPTION 'NONRENEWAL_NOTICE_TOO_SHORT: corrected notice at % leaves only % days before policy %''s term ends at %, against % days required in %',
      p_new_notice_at, v_given, v_policy_id, upper(v_term), v_required, v_state
      USING HINT = 'Correcting a notice date later can push it inside the required notice period. Correct to a date that still satisfies the filed requirement.';
  END IF;

  PERFORM set_config('luxauto.superseding_policy_nonrenewal', 'on', true);
  UPDATE policy_nonrenewals
  SET effective_range = tstzrange(v_old_at, v_old_at)  -- empty: superseded entirely
  WHERE nonrenewal_id = p_nonrenewal_id;
  PERFORM set_config('luxauto.superseding_policy_nonrenewal', 'off', true);

  INSERT INTO policy_nonrenewals (
    policy_id, effective_range, reason_code, notice_days_required, notice_days_given, notes, performed_by
  )
  VALUES (
    v_policy_id, tstzrange(p_new_notice_at, upper(v_term)), p_new_reason_code, v_required, v_given, p_new_notes, p_performed_by
  )
  RETURNING nonrenewal_id INTO v_new_id;

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (v_policy_id, 'nonrenewal_corrected', p_performed_by,
          format('Corrected nonrenewal %s with new nonrenewal %s (%s, %s days given against %s required)',
                 p_nonrenewal_id, v_new_id, p_new_reason_code, v_given, v_required));

  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- The scheduled term-end transition, run by scripts/expire-policies.sh on a
-- systemd timer (ADR 0019 section 3 - pg_cron is preloaded on luxauto-pg but
-- not allow-listed by azure.extensions, so it cannot be created).
--
-- Only touches policies that are still 'active' with a term end at or before
-- p_as_of. That single filter is what makes it idempotent (a policy it has
-- already transitioned is no longer 'active', so a second run skips it) and
-- what keeps it away from cancelled policies - ADR 0018's cancel_policy()
-- truncates effective_range to the cancellation date, so a cancelled policy
-- DOES have a term end in the past and a date-only query would sweep it up
-- and overwrite a terminal status. The status filter is load-bearing, not
-- defensive decoration.
--
-- A policy with a nonrenewal decision in force becomes 'nonrenewed'; every
-- other expiring policy becomes 'expired'. One function owns both so the two
-- can never disagree about the same policy at the same instant.
CREATE OR REPLACE FUNCTION expire_policies(p_as_of TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (expired_count INTEGER, nonrenewed_count INTEGER) AS $$
DECLARE
  v_expired INTEGER := 0;
  v_nonrenewed INTEGER := 0;
BEGIN
  WITH due AS (
    SELECT p.policy_id,
           EXISTS (SELECT 1 FROM policy_nonrenewals n
                   WHERE n.policy_id = p.policy_id AND NOT isempty(n.effective_range)) AS nonrenewed
    FROM policies p
    WHERE p.status = 'active'
      AND upper(p.effective_range) IS NOT NULL
      AND upper(p.effective_range) <= p_as_of
    FOR UPDATE OF p
  ),
  updated AS (
    UPDATE policies p
    SET status = CASE WHEN d.nonrenewed THEN 'nonrenewed'::policy_status_t ELSE 'expired'::policy_status_t END
    FROM due d
    WHERE p.policy_id = d.policy_id
    RETURNING p.policy_id, d.nonrenewed
  ),
  logged AS (
    INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
    SELECT u.policy_id,
           CASE WHEN u.nonrenewed THEN 'nonrenewed' ELSE 'expired' END,
           'system',
           format('Term ended; status set by expire_policies() as of %s', p_as_of)
    FROM updated u
    RETURNING policy_id
  )
  SELECT count(*) FILTER (WHERE NOT nonrenewed)::INTEGER,
         count(*) FILTER (WHERE nonrenewed)::INTEGER
  INTO v_expired, v_nonrenewed
  FROM updated;

  RETURN QUERY SELECT v_expired, v_nonrenewed;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- RENEWAL (ADR 0033)
-- The largest single addition: automatic renewal 30 days before term end. ADR
-- 0019 deliberately did not foreclose it, and this reuses the whole pipeline
-- rather than duplicating it - a renewal is a fresh application (copied from the
-- predecessor), submit_application (re-referral), create_quote (re-rating), and
-- bind_policy at a contiguous inception. The rules, orchestrator,
-- submit_application, current_referral_action, create_quote and bind_policy are
-- all UNTOUCHED - renewal composes them.
--
-- A1 CONSEQUENCE, STATED LOUDLY (a deliberate, informed limitation - see ADR
-- 0033): the renewal copies the predecessor application's risk data verbatim, and
-- NOTHING in this pass refreshes it (there is no MVR pull, no fresh loss run).
-- So the re-referral that runs on a renewal is MECHANICALLY REAL BUT PRACTICALLY
-- INERT: it re-evaluates the same frozen data already evaluated at the prior
-- bind, so it returns essentially the same disposition and will NOT catch risk
-- that materially worsened since (a new DUI, a new at-fault claim). "The referral
-- engine ran" must not be mistaken for "the risk was re-checked" on a renewal.
-- Time-based lookbacks can only make a disposition LESS severe (an old violation
-- ages out); nothing here makes it more severe. A real risk-data refresh before
-- renewal evaluation is genuine near-term follow-up work, not a nice-to-have.
-- ============================================================================

-- Deep-copies an application's RISK DATA into a fresh draft application, for a
-- renewal. Scope is exactly what the referral engine and rating read (and what
-- bind_policy snapshots): the application row, vehicles, additional_drivers,
-- claims_history, and person_violations. person_violations.subject_driver_id is
-- REMAPPED to the newly-created drivers (NULL, the applicant, stays NULL) so the
-- copy is internally consistent rather than pointing back at the source app's
-- drivers. Coverage/prior-insurance/enrichment detail is deliberately NOT copied:
-- no current rule or rating input reads it, so carrying it would be dead weight
-- and a maintenance trap (every future risk table would have to be added here);
-- that is future work if a rule ever reads it. Returns the new application id.
CREATE OR REPLACE FUNCTION copy_application_for_renewal(p_src_application_id UUID)
RETURNS UUID AS $$
DECLARE
  v_new_app UUID;
  v_driver_map JSONB := '{}'::jsonb;
  r RECORD;
  v_new_driver UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM applications WHERE application_id = p_src_application_id) THEN
    RAISE EXCEPTION 'RENEWAL_SOURCE_APPLICATION_NOT_FOUND: application % does not exist', p_src_application_id;
  END IF;

  INSERT INTO applications (applicant_id, status, garaging_state, state_specific_extensions)
  SELECT applicant_id, 'draft', garaging_state, state_specific_extensions
  FROM applications WHERE application_id = p_src_application_id
  RETURNING application_id INTO v_new_app;

  INSERT INTO vehicles (application_id, year, make, model, trim, vin, vehicle_category,
    purchase_price, current_appraised_value, appraisal_date, appraisal_source,
    agreed_value_requested, annual_mileage, primary_use, garaging_street, garaging_city,
    garaging_state, garaging_zip, garage_type, security_features, modifications,
    existing_liens, lienholder_name)
  SELECT v_new_app, year, make, model, trim, vin, vehicle_category,
    purchase_price, current_appraised_value, appraisal_date, appraisal_source,
    agreed_value_requested, annual_mileage, primary_use, garaging_street, garaging_city,
    garaging_state, garaging_zip, garage_type, security_features, modifications,
    existing_liens, lienholder_name
  FROM vehicles WHERE application_id = p_src_application_id;

  -- Drivers, capturing an old->new id map so violations can be remapped.
  FOR r IN SELECT * FROM additional_drivers WHERE application_id = p_src_application_id LOOP
    INSERT INTO additional_drivers (application_id, name, relationship_to_applicant,
      date_of_birth, years_licensed, license_status, violations_last_5yr, at_fault_accidents_last_5yr)
    VALUES (v_new_app, r.name, r.relationship_to_applicant, r.date_of_birth, r.years_licensed,
      r.license_status, r.violations_last_5yr, r.at_fault_accidents_last_5yr)
    RETURNING driver_id INTO v_new_driver;
    v_driver_map := v_driver_map || jsonb_build_object(r.driver_id::text, v_new_driver::text);
  END LOOP;

  INSERT INTO claims_history (application_id, claim_date, claim_type, at_fault, paid_amount, description)
  SELECT v_new_app, claim_date, claim_type, at_fault, paid_amount, description
  FROM claims_history WHERE application_id = p_src_application_id;

  INSERT INTO person_violations (application_id, subject_driver_id, violation_date,
    violation_type, conviction, bac_level, source)
  SELECT v_new_app,
    CASE WHEN pv.subject_driver_id IS NULL THEN NULL
         ELSE (v_driver_map ->> pv.subject_driver_id::text)::uuid END,
    pv.violation_date, pv.violation_type, pv.conviction, pv.bac_level, pv.source
  FROM person_violations pv WHERE pv.application_id = p_src_application_id;

  RETURN v_new_app;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Binds a renewal quote as the successor policy, contiguous with its predecessor.
-- A thin wrapper over bind_policy (the reinstate_policy idiom - wrap, don't widen
-- bind_policy again): it computes the contiguous inception (exactly the
-- predecessor's term end, via bind_policy's existing p_inception_date), binds,
-- and sets the renewal linkage/generation on the new row. STRUCTURAL nonrenewal
-- guard: a policy with an active nonrenewal decision can never be renewed, by any
-- caller (belt to the detector's suspenders). Returns the new policy id.
CREATE OR REPLACE FUNCTION renew_policy(
  p_quote_id UUID,
  p_predecessor_policy_id UUID,
  p_policy_number TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_pred_range TSTZRANGE;
  v_pred_original UUID;
  v_pred_generation INTEGER;
  v_inception TIMESTAMPTZ;
  v_new_policy UUID;
BEGIN
  SELECT effective_range, original_policy_id, renewal_generation
    INTO v_pred_range, v_pred_original, v_pred_generation
  FROM policies WHERE policy_id = p_predecessor_policy_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RENEWAL_PREDECESSOR_NOT_FOUND: policy % does not exist', p_predecessor_policy_id;
  END IF;

  -- Structural nonrenewal guard (ADR 0033 point 6): an in-force nonrenewal
  -- decision means "do not renew", full stop - refused regardless of caller.
  IF EXISTS (SELECT 1 FROM policy_nonrenewals n
             WHERE n.policy_id = p_predecessor_policy_id AND NOT isempty(n.effective_range)) THEN
    RAISE EXCEPTION 'RENEWAL_POLICY_NONRENEWED: policy % has an active nonrenewal decision and cannot be renewed', p_predecessor_policy_id
      USING HINT = 'A nonrenewal decision must be withdrawn (a separate follow-up) before the policy can renew.';
  END IF;

  v_inception := upper(v_pred_range);
  IF v_inception IS NULL THEN
    RAISE EXCEPTION 'RENEWAL_PREDECESSOR_UNBOUNDED_TERM: policy % has no term end, so a contiguous renewal has no inception', p_predecessor_policy_id;
  END IF;

  -- Contiguous inception exactly at the predecessor's term end.
  v_new_policy := bind_policy(p_quote_id, p_policy_number, p_performed_by, v_inception);

  UPDATE policies
  SET renewed_from_policy_id = p_predecessor_policy_id,
      original_policy_id = COALESCE(v_pred_original, p_predecessor_policy_id),
      renewal_generation = v_pred_generation + 1
  WHERE policy_id = v_new_policy;

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (v_new_policy, 'renewed', p_performed_by,
          format('Renewal of policy %s (generation %s), inception %s', p_predecessor_policy_id, v_pred_generation + 1, v_inception));

  RETURN v_new_policy;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- The pre-expiry detector: the scheduled sweep (a daily VM systemd timer, the
-- same pattern as expire_policies - pg_cron is blocked on luxauto-pg). Finds
-- active policies whose term ends within 30 days, and for each generates a full
-- renewal by reusing the pipeline: copy the application, submit_application
-- (re-referral), create_quote (re-rating, gated), renew_policy (bind contiguous).
--
-- Skips (does not offer): a policy with an active nonrenewal decision (the
-- detector-level half of the two-place guard), and one that already has a
-- successor (idempotency - unlike expire_policies, whose status filter is
-- self-idempotent, this detector's targets stay 'active', so a re-run without
-- this check would double-renew). A policy whose renewal cannot currently produce
-- a clean quote (a lapsed state filing making PC-03 fire, an expired territory
-- factor, or a risk that would now be flagged/was previously overridden) is
-- caught per-policy and counted as skipped rather than aborting the whole run -
-- it simply is not auto-renewed, which is the correct outcome (a non-clean risk
-- must not silently auto-renew). Returns (renewed_count, skipped_count).
CREATE OR REPLACE FUNCTION generate_renewal_offers(p_as_of TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (renewed_count INTEGER, skipped_count INTEGER) AS $$
DECLARE
  v_renewed INTEGER := 0;
  v_skipped INTEGER := 0;
  v_pol RECORD;
  v_src_app UUID;
  v_new_app UUID;
  v_channel broker_channel_t;
  v_broker_rate NUMERIC;
  v_program UUID;
  v_garaging_state CHAR(2);
  v_rating_record UUID;
  v_quote UUID;
  v_number TEXT;
BEGIN
  FOR v_pol IN
    SELECT p.policy_id, p.policy_number, p.renewal_generation, q.application_id AS src_app,
           q.broker_channel, q.broker_commission_rate, q.program_id, ap.garaging_state
    FROM policies p
    JOIN quotes q ON q.quote_id = p.quote_id
    JOIN applications ap ON ap.application_id = q.application_id
    WHERE p.status = 'active'
      AND upper(p.effective_range) IS NOT NULL
      AND upper(p.effective_range) > p_as_of
      AND upper(p.effective_range) <= p_as_of + interval '30 days'
      AND NOT EXISTS (SELECT 1 FROM policy_nonrenewals n
                      WHERE n.policy_id = p.policy_id AND NOT isempty(n.effective_range))
      AND NOT EXISTS (SELECT 1 FROM policies s WHERE s.renewed_from_policy_id = p.policy_id)
    FOR UPDATE OF p
  LOOP
    BEGIN
      -- The current filed rating-table version for the state (also what PC-03
      -- checks): its absence means the renewal cannot be cleanly quoted.
      SELECT record_id INTO v_rating_record
      FROM state_rating_table_versions
      WHERE state = v_pol.garaging_state AND effective_range @> p_as_of
      ORDER BY lower(effective_range) DESC
      LIMIT 1;
      IF v_rating_record IS NULL THEN
        RAISE EXCEPTION 'RENEWAL_NO_CURRENT_RATING_TABLE: no active state rating table for state %', v_pol.garaging_state;
      END IF;

      v_new_app := copy_application_for_renewal(v_pol.src_app);
      PERFORM submit_application(v_new_app, 'system');   -- re-referral (see A1 note)
      v_quote := create_quote(v_new_app, v_pol.broker_channel, v_pol.broker_commission_rate,
                              v_rating_record, v_pol.program_id, 'system');  -- re-rating + gate
      v_number := format('%s-R%s', COALESCE(v_pol.policy_number, v_pol.policy_id::text), v_pol.renewal_generation + 1);
      PERFORM renew_policy(v_quote, v_pol.policy_id, v_number, 'system');
      v_renewed := v_renewed + 1;
    EXCEPTION WHEN OTHERS THEN
      -- Any per-policy failure (flagged referral, lapsed filing, etc.) is a skip,
      -- not a fatal error for the whole sweep. Its partial work is rolled back to
      -- this savepoint.
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN QUERY SELECT v_renewed, v_skipped;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ============================================================================
-- ODOO READ-SIDE VIEWS (ADR 0006 pattern, ADR 0010 scope)
-- These three views exist purely for Odoo to read: each derives a hashed,
-- display-only pseudo-integer `id` from its underlying UUID key(s), the
-- documented workaround ADR 0006 established for Odoo's _auto=False model
-- pattern (Odoo's ORM requires an integer `id`; the pipeline's real identity
-- stays the UUID column(s)). The pipeline itself never queries these views -
-- it reads/writes the UUID-keyed tables directly. Not writable through Odoo's
-- default form save; see ADR 0010's server-actions section for the paths
-- that write.
-- ============================================================================

-- Insured view: applicants + applications. One row per (applicant,
-- application) pair, so the id is hashed from a composite of applicant_id
-- and application_id - matches the view's actual grain and keeps the
-- applicant visibly encoded in the hash, same reasoning as the composite id
-- on luxauto_premium_waterfall_view below.
CREATE OR REPLACE VIEW luxauto_insured_view AS
SELECT
  ('x' || substr(md5(a.applicant_id::text || ap.application_id::text), 1, 8))::bit(32)::int AS id,
  a.applicant_id,
  a.first_name,
  a.last_name,
  a.date_of_birth,
  a.email,
  a.phone,
  a.mailing_city,
  a.mailing_state,
  ap.application_id,
  ap.status AS application_status,
  ap.garaging_state,
  ap.submitted_at
FROM applicants a
JOIN applications ap ON ap.applicant_id = a.applicant_id;

-- Policy view: policies + quotes + applications - deliberately not also
-- joining applicants (ADR 0010's reasoning: a user reaches the insured's
-- name via the application, not a duplicated join path here).
CREATE OR REPLACE VIEW luxauto_policy_view AS
SELECT
  ('x' || substr(md5(p.policy_id::text), 1, 8))::bit(32)::int AS id,
  p.policy_id,
  p.policy_number,
  p.effective_range,
  p.status AS policy_status,
  q.quote_id,
  q.premium_amount,
  q.status AS quote_status,
  ap.application_id,
  ap.garaging_state,
  ap.status AS application_status,
  -- ADR 0023: if this policy reinstated a prior cancelled one (>14-day path),
  -- expose the predecessor so Odoo shows the link without a SQL round-trip.
  -- Null for the ordinary policy with no predecessor. Same read-side exposure
  -- pattern as every other column here - a plain passthrough, no new mechanism.
  -- Appended at the END of the select list on purpose: CREATE OR REPLACE VIEW
  -- can only add columns after the existing ones, never insert mid-list, so
  -- putting it here is what lets this re-apply cleanly over the live view.
  p.reinstated_from_policy_id
FROM policies p
JOIN quotes q ON q.quote_id = p.quote_id
JOIN applications ap ON ap.application_id = q.application_id;

-- Policy Vehicle / Policy Driver views (ADR 0016): each row is already
-- uniquely keyed by its own policy_vehicle_id/policy_driver_id - no fan-out
-- like the waterfall/settlement views below, so a simple single-column hash
-- is enough (not the composite hash those views need).
CREATE OR REPLACE VIEW luxauto_policy_vehicle_view AS
SELECT
  ('x' || substr(md5(pv.policy_vehicle_id::text), 1, 8))::bit(32)::int AS id,
  pv.policy_vehicle_id,
  pv.policy_id,
  pv.effective_range,
  pv.year,
  pv.make,
  pv.model,
  pv.trim,
  pv.vin,
  pv.vehicle_category,
  pv.garaging_state,
  pv.agreed_value_requested,
  pv.current_appraised_value
FROM policy_vehicles pv;

CREATE OR REPLACE VIEW luxauto_policy_driver_view AS
SELECT
  ('x' || substr(md5(pd.policy_driver_id::text), 1, 8))::bit(32)::int AS id,
  pd.policy_driver_id,
  pd.policy_id,
  pd.effective_range,
  pd.name,
  pd.relationship_to_applicant,
  pd.date_of_birth,
  pd.years_licensed,
  pd.license_status,
  pd.violations_last_5yr,
  pd.at_fault_accidents_last_5yr
FROM policy_drivers pd;

-- Policy Cancellation view (ADR 0018 addendum): the read side ADR 0018 left
-- out. Same single-column hash as the vehicle/driver views above and for the
-- same reason - a cancellation is uniquely keyed by cancellation_id with no
-- fan-out, so no composite hash is needed.
--
-- No filtering, deliberately: like every other read-side view here this
-- returns ALL rows, superseded ones included. A corrected cancellation leaves
-- the original row emptied and inserts a replacement (ADR 0018 section 6), so
-- both appear. "Which one is in force" is not decided here - the row itself
-- says so, which is what the two derived columns below are for.
--
-- cancelled_at and superseded are derived rather than stored: Odoo has no
-- native range field type, so effective_range is unmappable on the model
-- (same as on luxauto_policy_view), and without these two a superseded
-- cancellation would be indistinguishable in the UI from the live one - two
-- rows carrying different return premiums for the same policy with nothing to
-- tell them apart. lower() of an empty range is NULL, so a superseded row
-- shows no cancellation date at all, which is exactly the claim ADR 0018
-- section 6 makes about it: it applied for zero time.
CREATE OR REPLACE VIEW luxauto_policy_cancellation_view AS
SELECT
  ('x' || substr(md5(c.cancellation_id::text), 1, 8))::bit(32)::int AS id,
  c.cancellation_id,
  c.policy_id,
  c.effective_range,
  lower(c.effective_range) AS cancelled_at,
  isempty(c.effective_range) AS superseded,
  c.cancellation_type,
  c.reason_code,
  c.refund_method,
  c.short_rate_factor,
  c.short_rate_basis,
  c.unearned_premium,
  c.return_premium,
  c.notes,
  c.performed_by,
  c.created_at
FROM policy_cancellations c;

-- Premium/Waterfall view: quotes + program_participants, one row per
-- participant per quote - the id is hashed from a composite of quote_id and
-- participant_id, since a single quote fans out to multiple rows here. The
-- per-participant net-due figures come from calculate_premium_waterfall()
-- (defined above, in the quota-share section) rather than being
-- reimplemented in the view - see ADR 0010's "where the waterfall math
-- lives" decision. A future bordereau-style report reads the same function.
CREATE OR REPLACE VIEW luxauto_premium_waterfall_view AS
SELECT
  ('x' || substr(md5(q.quote_id::text || w.participant_id::text), 1, 8))::bit(32)::int AS id,
  q.quote_id,
  q.application_id,
  q.program_id,
  q.premium_amount,
  q.status AS quote_status,
  w.participant_id,
  w.participant_name,
  w.participant_type,
  w.share_percentage,
  w.commission_rate,
  w.gross_share,
  w.commission_amount,
  w.net_due
FROM quotes q
CROSS JOIN LATERAL calculate_premium_waterfall(q.quote_id) w;

-- Settlement report (ADR 0013): every bound policy's per-participant
-- waterfall, joined through its bind event in policy_events rather than
-- filtered by effective_range - a settlement report reflects when premium
-- was written, not when coverage is active (ADR 0013 section 1). No period
-- filter here: this view returns every bound policy across all time: the
-- period filter is an Odoo-side search view concern (ADR 0013 section 3),
-- not baked into the SQL. policy_status is included and never filtered out,
-- so a since-cancelled policy stays visible here rather than silently
-- disappearing (ADR 0013 section 2) - return-premium/cancellation
-- adjustment is a deferred follow-on decision, not handled by this view.
-- Same CROSS JOIN LATERAL / calculate_premium_waterfall() reuse as
-- luxauto_premium_waterfall_view above, and the same reason: one waterfall
-- calculation, never reimplemented. id is composite-hashed from
-- policy_id + participant_id, since this view also fans out to one row per
-- participant per policy.
-- ADR 0013 addendum: three transaction types, not one. As originally built
-- this view showed only written premium at bind, which ADR 0013 named as a
-- gross-written ledger and explicitly deferred netting for. ADR 0014's
-- endorsement waterfalls and ADR 0018's return premium then both landed
-- without being wired in, so a capacity provider reading this report saw
-- neither a mid-term premium increase nor a refund. All three now appear, one
-- row per participant per transaction.
--
-- Each leg is dated by its OWN recording timestamp, not by the bind date:
-- bind by the 'bound' event, an endorsement by policy_endorsements.created_at,
-- a return premium by policy_cancellations.created_at. That is the same
-- reasoning ADR 0013 section 1 used to pick the bind event over
-- effective_range - settle a transaction in the period it happened, on a
-- timestamp that is set once and never moves - applied to two transaction
-- types that did not exist when that decision was made. A refund belongs to
-- the period the carrier actually owed it, which is when it was recorded, not
-- the period the policy was originally written in.
--
-- bind_date is kept on every row (it still says which policy the transaction
-- belongs to and when that policy was written); transaction_date is what a
-- settlement period filters on.
--
-- Superseded rows are excluded on both new legs: an emptied endorsement or
-- cancellation applied for zero time (ADR 0016 addendum 3, ADR 0018), so it
-- was never owed. A correction therefore restates the period its corrected
-- record falls in, which is what a correction is for.
CREATE OR REPLACE VIEW luxauto_settlement_view AS
SELECT
  ('x' || substr(md5(p.policy_id::text || w.participant_id::text || 'premium'), 1, 8))::bit(32)::int AS id,
  p.policy_id,
  p.policy_number,
  p.status AS policy_status,
  be.created_at AS bind_date,
  p.quote_id,
  w.participant_id,
  w.participant_name,
  w.participant_type,
  w.share_percentage,
  w.commission_rate,
  w.gross_share,
  w.commission_amount,
  w.net_due,
  -- Appended after the original columns on purpose: CREATE OR REPLACE VIEW
  -- cannot reorder or rename existing ones, and dropping the view to make it
  -- prettier would drop its grants with it on every apply.
  'premium'::TEXT AS transaction_type,
  be.created_at AS transaction_date
FROM policies p
JOIN policy_events be ON be.policy_id = p.policy_id AND be.event_type = 'bound'
CROSS JOIN LATERAL calculate_premium_waterfall(p.quote_id) w

UNION ALL

SELECT
  ('x' || substr(md5(e.endorsement_id::text || w.participant_id::text || 'endorsement'), 1, 8))::bit(32)::int,
  p.policy_id,
  p.policy_number,
  p.status,
  be.created_at,
  p.quote_id,
  w.participant_id,
  w.participant_name,
  w.participant_type,
  w.share_percentage,
  w.commission_rate,
  w.gross_share,
  w.commission_amount,
  w.net_due,
  'endorsement'::TEXT,
  e.created_at
FROM policy_endorsements e
JOIN policies p ON p.policy_id = e.policy_id
JOIN policy_events be ON be.policy_id = p.policy_id AND be.event_type = 'bound'
CROSS JOIN LATERAL calculate_endorsement_waterfall(e.endorsement_id) w
-- A pure term_change carries no premium_delta and has nothing to settle
-- (ADR 0014 section 5's own note about when that function is meaningful).
WHERE e.premium_delta IS NOT NULL
  AND NOT isempty(e.effective_range)

UNION ALL

SELECT
  ('x' || substr(md5(c.cancellation_id::text || w.participant_id::text || 'return_premium'), 1, 8))::bit(32)::int,
  p.policy_id,
  p.policy_number,
  p.status,
  be.created_at,
  p.quote_id,
  w.participant_id,
  w.participant_name,
  w.participant_type,
  w.share_percentage,
  w.commission_rate,
  w.gross_share,
  w.commission_amount,
  w.net_due,
  'return_premium'::TEXT,
  c.created_at
FROM policy_cancellations c
JOIN policies p ON p.policy_id = c.policy_id
JOIN policy_events be ON be.policy_id = p.policy_id AND be.event_type = 'bound'
CROSS JOIN LATERAL calculate_cancellation_waterfall(c.cancellation_id) w
WHERE NOT isempty(c.effective_range);

-- ============================================================================
-- READ-SIDE VISIBILITY VIEWS (ADR 0029)
-- Five domains that shipped their write/compute side (ADRs 0024-0028) with the
-- Odoo read side deliberately deferred and batched into this one pass. Every
-- view here follows the pattern the earlier read views established (ADR 0006's
-- _auto=False, ADR 0010's scope): a synthetic integer id hashed from the row's
-- key for Odoo, real UUID keys carried as-is, tstzrange columns left unmapped
-- with immutable scalars derived where a reader needs them, and no filtering -
-- every row is returned, the row itself carrying whatever "is this current"
-- signal it has. None of these compute anything: the pipeline functions
-- (reinstate_policy, short_rate_factor, the referral rules,
-- compute_indicative_premium) remain the system of record and are untouched.
-- ============================================================================

-- Reinstatement (ADR 0024): the link-and-attestation audit record. reinstated_
-- from_policy_id already surfaces the bare predecessor link on luxauto_policy_
-- view (ADR 0023); this is the audit row behind it - the gap instant, the
-- signed no-known-loss attestation reference, and who performed it - which had
-- no read side. policies is joined twice (new and prior) so a reader gets both
-- policy numbers without a second round-trip; single-column hash on
-- reinstatement_id, one row per reinstatement with no fan-out. gap_start is a
-- single instant, not a range: the cancellation effective date is the new
-- policy's backdated inception (zero gap is the whole point of ADR 0024).
CREATE OR REPLACE VIEW luxauto_policy_reinstatement_view AS
SELECT
  ('x' || substr(md5(r.reinstatement_id::text), 1, 8))::bit(32)::int AS id,
  r.reinstatement_id,
  r.new_policy_id,
  np.policy_number AS new_policy_number,
  r.prior_policy_id,
  pp.policy_number AS prior_policy_number,
  r.cancellation_id,
  r.gap_start,
  r.attestation_reference,
  r.performed_by,
  r.created_at
FROM policy_reinstatements r
JOIN policies np ON np.policy_id = r.new_policy_id
JOIN policies pp ON pp.policy_id = r.prior_policy_id;

-- Short-rate factors (ADR 0025), the CONFIGURED table - what factor is filed
-- for a state/program right now, for internal/admin reference. This is the
-- lookup table, NOT the applied factor: the factor actually charged on a given
-- cancellation is already visible on luxauto_policy_cancellation_view
-- (short_rate_factor / short_rate_basis, ADR 0018 addendum), a separate
-- historical fact and deliberately not conflated with this reference row.
-- Single-column hash on short_rate_factor_id; effective_range (tstzrange) is
-- unmappable in Odoo like everywhere else here, so its immutable bounds are
-- derived as scalars rather than a now()-based "active" flag (which would make
-- the view non-deterministic) - the reader judges currency from the bounds.
CREATE OR REPLACE VIEW luxauto_short_rate_factor_view AS
SELECT
  ('x' || substr(md5(f.short_rate_factor_id::text), 1, 8))::bit(32)::int AS id,
  f.short_rate_factor_id,
  f.state,
  f.program_id,
  f.elapsed_fraction_from,
  f.elapsed_fraction_to,
  f.factor,
  f.basis,
  f.applies_to,
  lower(f.effective_range) AS effective_from,
  upper(f.effective_range) AS effective_to,
  f.serff_filing_tracking_number,
  f.rate_manual_reference,
  f.created_at
FROM short_rate_factors f;

-- Referral / decision log (ADR 0026/0028), the DETAIL view: one row per
-- decision_log row, every rule evaluation whether it fired or not, across every
-- evaluation run. No filtering and no collapsing - this is the raw append-only
-- audit, the same "return all rows, the row is the fact" philosophy as the
-- cancellation view. Single-column hash on log_id. The summary view below is
-- what collapses this to a current per-application disposition.
CREATE OR REPLACE VIEW luxauto_decision_log_view AS
SELECT
  ('x' || substr(md5(d.log_id::text), 1, 8))::bit(32)::int AS id,
  d.log_id,
  d.application_id,
  d.rule_id,
  d.reason_code,
  d.action_taken,
  d.fired,
  d.decided_by,
  d.notes,
  d.created_at
FROM decision_log d;

-- Referral SUMMARY view (ADR 0026/0028): one row per application, the current
-- disposition an underwriter actually wants - which rules are in effect and the
-- most-severe action across them. Derived from decision_log rows, NEVER by
-- calling evaluate_application_referrals(): that orchestrator is SECURITY
-- DEFINER and INSERTs a decision_log row per rule on every call, so calling it
-- from a read view would write audit rows as a side effect of reading. Instead:
-- decision_log is append-only and re-evaluation appends a fresh set of rows, so
-- take the LATEST row per (application, rule) via DISTINCT ON, then aggregate.
-- max(action_taken) reproduces the orchestrator's GREATEST(...) exactly: the
-- referral_action_t enum is declared least-severe -> most-severe, and a
-- non-firing rule logs AUTO_PROCEED (the enum minimum), so the max over the
-- current per-rule actions is the same value the orchestrator returns, with no
-- side effect. Single-column hash on application_id.
CREATE OR REPLACE VIEW luxauto_application_referral_view AS
WITH latest_per_rule AS (
  SELECT DISTINCT ON (d.application_id, d.rule_id)
    d.application_id, d.rule_id, d.action_taken, d.fired, d.created_at
  FROM decision_log d
  ORDER BY d.application_id, d.rule_id, d.created_at DESC
)
SELECT
  ('x' || substr(md5(lpr.application_id::text), 1, 8))::bit(32)::int AS id,
  lpr.application_id,
  max(lpr.action_taken) AS most_severe_action,
  count(*) FILTER (WHERE lpr.fired) AS fired_rule_count,
  count(*) AS rule_count,
  max(lpr.created_at) AS evaluated_at
FROM latest_per_rule lpr
GROUP BY lpr.application_id;

-- Commission (ADR 0007 addendum): broker channel and both commission rates,
-- decided at quote time and inherited by the bound policy via quote_id. Quote
-- grain (single-column hash on quote_id) so an unbound quote is covered too;
-- the bound policy reaches this through application_id. mga_commission_rate is
-- the generated 30 - broker column, so broker + MGA = 30 shows as the schema
-- fact it is. Open to base.group_user like luxauto_premium_waterfall_view (ADR
-- 0029 decision), not gated like the settlement report.
CREATE OR REPLACE VIEW luxauto_quote_commission_view AS
SELECT
  ('x' || substr(md5(q.quote_id::text), 1, 8))::bit(32)::int AS id,
  q.quote_id,
  q.application_id,
  q.program_id,
  q.premium_amount,
  q.broker_channel,
  q.broker_commission_rate,
  q.mga_commission_rate,
  q.status AS quote_status,
  q.quoted_at
FROM quotes q;

-- Rating (ADR 0028): the persisted per-quote rating_basis JSONB unpacked into
-- typed columns so the breakdown - which base rate, territory factor and
-- gross-up divisor produced the number - is legible, not opaque. Quote grain,
-- single-column hash on quote_id. The ->> extractions of the v1
-- (indicative_premium_v1) key shape cast cleanly to numeric/smallint; a quote
-- whose rating_basis is not v1-shaped yields NULLs rather than an error, which
-- is the intended behaviour today: compute_indicative_premium() is NOT yet
-- wired into quote creation (ADR 0028 built the calculation but never made it
-- fire on quote insert), so no real quote writes a v1 rating_basis yet. Wiring
-- that is scoped-out follow-up work (ADR 0029 flags it); this view is built
-- correct now so it renders the moment a v1-shaped basis is written.
CREATE OR REPLACE VIEW luxauto_quote_rating_view AS
SELECT
  ('x' || substr(md5(q.quote_id::text), 1, 8))::bit(32)::int AS id,
  q.quote_id,
  q.application_id,
  q.premium_amount,
  q.rating_basis ->> 'model'                            AS rating_model,
  (q.rating_basis ->> 'agreed_value')::numeric          AS agreed_value,
  (q.rating_basis ->> 'rating_vehicle_class')::smallint AS rating_vehicle_class,
  q.rating_basis ->> 'rating_class_label'               AS rating_class_label,
  (q.rating_basis #>> '{value_band,lower}')::numeric    AS value_band_lower,
  (q.rating_basis #>> '{value_band,upper}')::numeric    AS value_band_upper,
  (q.rating_basis ->> 'base_rate_per_100')::numeric     AS base_rate_per_100,
  (q.rating_basis ->> 'base_loss_cost')::numeric        AS base_loss_cost,
  q.rating_basis ->> 'territory_state'                  AS territory_state,
  (q.rating_basis ->> 'territory_factor')::numeric      AS territory_factor,
  (q.rating_basis ->> 'gross_up_divisor')::numeric      AS gross_up_divisor,
  (q.rating_basis ->> 'indicative_premium')::numeric    AS indicative_premium,
  q.status AS quote_status,
  q.quoted_at
FROM quotes q;

-- These views are owned by whichever role runs this script (the
-- Postgres admin, in practice - see ADR 0011), not by the `odoo` role Odoo
-- itself connects as (ADR 0009). A plain view runs with its owner's table
-- privileges for any caller with SELECT on the view, so `odoo` needs that
-- SELECT grant explicitly - it doesn't get it just by the view existing.
-- Assumes the `odoo` role already exists (ADR 0009 creates it) when this
-- file is applied to luxauto-pg's luxauto database, same assumption the
-- rest of this file already makes about running against that database.
GRANT SELECT ON luxauto_insured_view TO odoo;
GRANT SELECT ON luxauto_policy_view TO odoo;
GRANT SELECT ON luxauto_policy_vehicle_view TO odoo;
GRANT SELECT ON luxauto_policy_driver_view TO odoo;
-- ADR 0018 addendum. Read-only, like the rest: the cancel wizard still writes
-- through cancel_policy(), and nothing reaches policy_cancellations this way.
GRANT SELECT ON luxauto_policy_cancellation_view TO odoo;
GRANT SELECT ON luxauto_premium_waterfall_view TO odoo;
GRANT SELECT ON luxauto_settlement_view TO odoo;
-- ADR 0029 read-side visibility views. SELECT only, same as every read view
-- above: the write/compute paths (reinstate_policy, cancel_policy's short-rate
-- lookup, the referral rules, compute_indicative_premium) are untouched and
-- reach nothing through these grants.
GRANT SELECT ON luxauto_policy_reinstatement_view TO odoo;
GRANT SELECT ON luxauto_short_rate_factor_view TO odoo;
GRANT SELECT ON luxauto_decision_log_view TO odoo;
GRANT SELECT ON luxauto_application_referral_view TO odoo;
GRANT SELECT ON luxauto_quote_commission_view TO odoo;
GRANT SELECT ON luxauto_quote_rating_view TO odoo;
GRANT EXECUTE ON FUNCTION calculate_premium_waterfall(UUID) TO odoo;
GRANT EXECUTE ON FUNCTION calculate_premium_waterfall(UUID, NUMERIC, TIMESTAMPTZ) TO odoo;
GRANT EXECUTE ON FUNCTION calculate_endorsement_waterfall(UUID) TO odoo;
-- ADR 0024 widened this to a four-argument form (optional inception date); the
-- three-argument grant is gone with the three-argument function.
-- ADR 0030: the first quote-creation write path, rating the quote via
-- compute_indicative_premium() as it creates it. Granted so an Odoo quote-
-- creation wizard (a later step, not built here) can call it, same as bind.
GRANT EXECUTE ON FUNCTION create_quote(UUID, broker_channel_t, NUMERIC, UUID, UUID, TEXT) TO odoo;
GRANT EXECUTE ON FUNCTION bind_policy(UUID, TEXT, TEXT, TIMESTAMPTZ) TO odoo;
-- ADR 0023: the reinstatement-linking step the Odoo wizard calls after bind.
GRANT EXECUTE ON FUNCTION link_reinstated_policy(UUID, UUID, TEXT) TO odoo;
-- ADR 0024: the backdated reinstatement wrapper the Odoo reinstatement wizard
-- calls (binds new business at the gap start, links, records the attestation).
GRANT EXECUTE ON FUNCTION reinstate_policy(UUID, UUID, TEXT, TEXT, TEXT) TO odoo;
-- ADR 0026: the referral-engine entry point. The per-rule functions are
-- SECURITY DEFINER and reached through this orchestrator (which runs as the
-- owner), so only the orchestrator needs a grant.
GRANT EXECUTE ON FUNCTION evaluate_application_referrals(UUID, TEXT) TO odoo;
-- ADR 0031: submit an application (evaluates the referral engine, first
-- lifecycle transition) and read its current disposition. An Odoo submission
-- wizard would call submit_application; current_referral_action is the guard's
-- read helper, granted for completeness (it is also reachable through the
-- ADR 0029 read view).
GRANT EXECUTE ON FUNCTION submit_application(UUID, TEXT) TO odoo;
GRANT EXECUTE ON FUNCTION current_referral_action(UUID) TO odoo;
-- ADR 0032: the underwriter supervised-release path. add_underwriter manages the
-- roster; authorize_referral_override records a supervised override (an Odoo
-- underwriter wizard would call it); current_referral_evaluated_at is the
-- staleness-pin read helper, granted for completeness.
GRANT EXECUTE ON FUNCTION add_underwriter(TEXT, underwriter_authority_t) TO odoo;
GRANT EXECUTE ON FUNCTION update_underwriter(UUID, TEXT, underwriter_authority_t, BOOLEAN) TO odoo;
GRANT EXECUTE ON FUNCTION authorize_referral_override(UUID, referral_action_t, TEXT, UUID) TO odoo;
GRANT EXECUTE ON FUNCTION current_referral_evaluated_at(UUID) TO odoo;
-- ADR 0028: the rating-engine entry point (v1 indicative premium). The per-rule
-- referral function evaluate_el01 is reached through the orchestrator above and
-- needs no separate grant.
GRANT EXECUTE ON FUNCTION compute_indicative_premium(vehicle_category_t, NUMERIC, CHAR(2), TIMESTAMPTZ) TO odoo;
GRANT EXECUTE ON FUNCTION cancel_policy(UUID, TEXT, TEXT) TO odoo;
-- ADR 0018. The three-argument cancel_policy above still needs its grant: it
-- is reachable and raises CANCELLATION_TYPE_REQUIRED, which is the diagnosis
-- an old caller should get rather than "permission denied".
GRANT EXECUTE ON FUNCTION cancel_policy(
  UUID, cancellation_type_t, TEXT, refund_method_t, TIMESTAMPTZ, TEXT, TEXT
) TO odoo;
GRANT EXECUTE ON FUNCTION correct_policy_cancellation(
  UUID, TIMESTAMPTZ, cancellation_type_t, TEXT, refund_method_t, TEXT, TEXT
) TO odoo;
GRANT EXECUTE ON FUNCTION calculate_cancellation_waterfall(UUID) TO odoo;
-- ADR 0019. expire_policies() is granted so the scheduled job can run as the
-- least-privilege `odoo` role rather than as the table owner.
GRANT EXECUTE ON FUNCTION nonrenew_policy(UUID, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO odoo;
GRANT EXECUTE ON FUNCTION correct_policy_nonrenewal(UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT) TO odoo;
GRANT EXECUTE ON FUNCTION nonrenewal_notice_days(CHAR(2), UUID, NUMERIC, TIMESTAMPTZ) TO odoo;
GRANT EXECUTE ON FUNCTION expire_policies(TIMESTAMPTZ) TO odoo;
-- ADR 0033 renewal. generate_renewal_offers is what the daily VM systemd job
-- runs (as the least-privilege odoo role, like expire_policies); renew_policy
-- and copy_application_for_renewal are granted for a future manual-renewal
-- wizard; policy_tenure_years is a read helper.
GRANT EXECUTE ON FUNCTION generate_renewal_offers(TIMESTAMPTZ) TO odoo;
GRANT EXECUTE ON FUNCTION renew_policy(UUID, UUID, TEXT, TEXT) TO odoo;
GRANT EXECUTE ON FUNCTION copy_application_for_renewal(UUID) TO odoo;
GRANT EXECUTE ON FUNCTION policy_tenure_years(UUID, TIMESTAMPTZ) TO odoo;
-- Read-only and useful before the fact: a cancellation UI should be able to
-- show the return premium it is about to create.
GRANT EXECUTE ON FUNCTION policy_unearned_premium(UUID, TSTZRANGE, TIMESTAMPTZ) TO odoo;
GRANT EXECUTE ON FUNCTION endorse_policy(UUID, TSTZRANGE, endorsement_type_t, NUMERIC, TEXT, TEXT) TO odoo;
GRANT EXECUTE ON FUNCTION correct_policy_endorsement(UUID, TSTZRANGE, endorsement_type_t, NUMERIC, TEXT, TEXT) TO odoo;
GRANT EXECUTE ON FUNCTION correct_policy_vehicle(
  UUID, TSTZRANGE, SMALLINT, TEXT, TEXT, TEXT, TEXT, vehicle_category_t,
  NUMERIC, NUMERIC, DATE, TEXT, BOOLEAN, INTEGER, primary_use_t,
  TEXT, TEXT, CHAR(2), TEXT, garage_type_t, TEXT[], TEXT, BOOLEAN, TEXT, TEXT
) TO odoo;
GRANT EXECUTE ON FUNCTION correct_policy_driver(
  UUID, TSTZRANGE, TEXT, TEXT, DATE, SMALLINT, license_status_t, SMALLINT, SMALLINT, TEXT
) TO odoo;

-- ============================================================================
-- DOCUMENTS (metadata only - files live in Azure Blob Storage per ADR 0002/0003)
-- ============================================================================

CREATE TABLE IF NOT EXISTS documents (
  document_id                       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                    UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  document_type                     document_type_t NOT NULL,
  azure_blob_container              TEXT NOT NULL,
  azure_blob_path                   TEXT NOT NULL,
  original_filename                 TEXT,
  content_type                      TEXT,
  uploaded_at                       TIMESTAMPTZ NOT NULL DEFAULT now(),
  uploaded_by                       TEXT
);

CREATE INDEX IF NOT EXISTS idx_documents_application ON documents(application_id);

-- ============================================================================
-- updated_at maintenance
-- ============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER applicants_updated_at BEFORE UPDATE ON applicants
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE OR REPLACE TRIGGER applications_updated_at BEFORE UPDATE ON applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE OR REPLACE TRIGGER policies_updated_at BEFORE UPDATE ON policies
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
