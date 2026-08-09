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

CREATE TYPE license_status_t AS ENUM ('valid', 'suspended', 'revoked', 'expired');
CREATE TYPE credit_score_band_t AS ENUM ('excellent', 'good', 'fair', 'poor', 'not_available');
CREATE TYPE vehicle_category_t AS ENUM ('production_luxury', 'exotic', 'classic_collector', 'modified_performance');
CREATE TYPE primary_use_t AS ENUM ('pleasure', 'commute', 'business', 'show_display');
CREATE TYPE garage_type_t AS ENUM ('attached_locked', 'detached_locked', 'gated_community', 'unsecured_street', 'climate_controlled_storage');
CREATE TYPE claim_type_t AS ENUM ('collision', 'comprehensive', 'liability', 'glass', 'theft');
CREATE TYPE violation_type_t AS ENUM ('DUI', 'reckless_driving', 'speeding', 'other_moving_violation');
CREATE TYPE sanctions_result_t AS ENUM ('clear', 'positive_hit', 'pending');
CREATE TYPE title_status_t AS ENUM ('clean', 'salvage', 'rebuilt', 'flood', 'lemon_law_buyback');
CREATE TYPE filing_status_t AS ENUM ('prior_approval', 'file_and_use', 'use_and_file', 'flex_rating_band', 'competitive_no_file');
CREATE TYPE referral_action_t AS ENUM (
  'AUTO_PROCEED', 'AUTO_PROCEED_WITH_FLAG', 'INFORMATION_REQUEST',
  'MANUAL_REVIEW_REQUIRED', 'MANUAL_REVIEW_SENIOR',
  'DECLINE_RECOMMENDED', 'HARD_DECLINE_COMPLIANCE'
);
CREATE TYPE application_status_t AS ENUM (
  'draft', 'submitted', 'information_requested', 'in_review',
  'quoted', 'bound', 'declined', 'withdrawn'
);
CREATE TYPE document_type_t AS ENUM (
  'appraisal', 'loss_run', 'engineering_report', 'rendered_quote_pdf',
  'application_form', 'title_report', 'mvr_report', 'other'
);

-- ============================================================================
-- STATE RATING TABLE REGISTRY
-- Implements state_rating_table_schema.json. This is compliance boundary
-- infrastructure, not configuration - see that schema's own header comment.
-- ============================================================================

CREATE TABLE state_rating_table_versions (
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

CREATE INDEX idx_state_rating_state ON state_rating_table_versions(state);

COMMENT ON TABLE state_rating_table_versions IS
  'One row per state per effective-date version. rate quotes must pin to a specific record_id (see quotes.state_rating_table_record_id) so a later rate change never silently re-rates an in-flight quote.';
COMMENT ON COLUMN state_rating_table_versions.approved_rating_variables IS
  'Array of {variable_name, permitted, usage_context, notes}. Rating engine must reject any variable not in this list for the applicable state - see referral rule CP-03.';

-- ============================================================================
-- APPLICANTS
-- Normalized separately from applications: one applicant may have multiple
-- applications over time (renewals, additional vehicles).
-- ============================================================================

CREATE TABLE applicants (
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

CREATE TABLE applications (
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

CREATE INDEX idx_applications_applicant ON applications(applicant_id);
CREATE INDEX idx_applications_garaging_state ON applications(garaging_state);
CREATE INDEX idx_applications_status ON applications(status);

COMMENT ON COLUMN applications.state_specific_extensions IS
  'Namespace for per-state supplemental fields (e.g. MI PIP tiers). What belongs here is driven by state_rating_table_versions.state_specific_application_fields for this application''s garaging_state, not hardcoded - see application schema v1.1 changelog.';

-- ============================================================================
-- ADDITIONAL DRIVERS
-- ============================================================================

CREATE TABLE additional_drivers (
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

CREATE INDEX idx_additional_drivers_application ON additional_drivers(application_id);

-- ============================================================================
-- VEHICLES
-- ============================================================================

CREATE TABLE vehicles (
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

CREATE INDEX idx_vehicles_application ON vehicles(application_id);
CREATE INDEX idx_vehicles_vin ON vehicles(vin);

-- ============================================================================
-- COVERAGE REQUESTED / PRIOR INSURANCE
-- 1:1 with applications - split out for clarity, not normalization purity.
-- ============================================================================

CREATE TABLE coverage_requested (
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

CREATE TABLE prior_insurance (
  application_id                   UUID PRIMARY KEY REFERENCES applications(application_id) ON DELETE CASCADE,
  current_carrier                  TEXT,
  years_with_current_carrier      SMALLINT,
  current_policy_expiration       DATE,
  reason_for_shopping              TEXT,
  any_nonrenewal_or_cancellation_history BOOLEAN,
  cancellation_reason              TEXT
);

CREATE TABLE claims_history (
  claim_id                         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                   UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  claim_date                       DATE NOT NULL,
  claim_type                       claim_type_t NOT NULL,
  at_fault                         BOOLEAN NOT NULL,
  paid_amount                      NUMERIC(12,2),
  description                      TEXT
);

CREATE INDEX idx_claims_application ON claims_history(application_id);

-- ============================================================================
-- ENRICHMENT (populated by the pipeline post-intake, pre-referral - implements
-- application schema v1.1's enrichment_computed section)
-- ============================================================================

CREATE TABLE applicant_enrichment (
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
CREATE TABLE person_violations (
  violation_id                     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                   UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  subject_driver_id                UUID REFERENCES additional_drivers(driver_id),  -- NULL = applicant
  violation_date                   DATE NOT NULL,
  violation_type                   violation_type_t NOT NULL,
  conviction                       BOOLEAN NOT NULL,
  bac_level                        NUMERIC(4,3),  -- DUI only
  source                           TEXT NOT NULL
);

CREATE INDEX idx_person_violations_application ON person_violations(application_id);

CREATE TABLE additional_driver_sanctions (
  driver_id                        UUID PRIMARY KEY REFERENCES additional_drivers(driver_id) ON DELETE CASCADE,
  sanctions_screen_result          sanctions_result_t NOT NULL DEFAULT 'pending'
);

CREATE TABLE vehicle_enrichment (
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

CREATE TABLE producer_verification (
  application_id                   UUID PRIMARY KEY REFERENCES applications(application_id) ON DELETE CASCADE,
  verified                         BOOLEAN NOT NULL DEFAULT false,
  license_status                   TEXT,
  toba_executed                    BOOLEAN NOT NULL DEFAULT false,
  notes                            TEXT
);

-- ============================================================================
-- UNDERWRITING FLAGS (pipeline output)
-- ============================================================================

CREATE TABLE underwriting_flags (
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

CREATE TABLE decision_log (
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

CREATE INDEX idx_decision_log_application ON decision_log(application_id);
CREATE INDEX idx_decision_log_rule ON decision_log(rule_id);

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

CREATE TRIGGER decision_log_no_update
  BEFORE UPDATE ON decision_log
  FOR EACH ROW EXECUTE FUNCTION reject_decision_log_mutation();

CREATE TRIGGER decision_log_no_delete
  BEFORE DELETE ON decision_log
  FOR EACH ROW EXECUTE FUNCTION reject_decision_log_mutation();

-- ============================================================================
-- QUOTA SHARE / COMMISSION WATERFALL (ADR 0007)
-- Direct analogue to the Energy manual's Ch.10 commission waterfall and
-- Ch.11 market panel structure. In the admitted market this more often
-- represents a reinsurance/participation arrangement behind a single
-- fronting carrier than a Lloyd's-style multi-syndicate policy panel, but
-- the accounting shape is identical either way - see ADR 0007 for the
-- full scoping discussion.
-- ============================================================================

CREATE TYPE participant_type_t AS ENUM ('capacity_provider', 'reinsurer', 'mga_retention');

CREATE TABLE insurance_programs (
  program_id                        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  program_name                      TEXT NOT NULL,
  capacity_provider_name            TEXT NOT NULL,  -- the admitted fronting carrier
  effective_range                   TSTZRANGE NOT NULL,
  estimated_premium_income          NUMERIC(14,2),
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE program_participants (
  participant_id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  program_id                        UUID NOT NULL REFERENCES insurance_programs(program_id) ON DELETE CASCADE,
  participant_type                  participant_type_t NOT NULL,
  participant_name                  TEXT NOT NULL,
  share_percentage                  NUMERIC(5,2) NOT NULL CHECK (share_percentage > 0 AND share_percentage <= 100),
  commission_rate                   NUMERIC(5,2),  -- % of premium retained as commission, where applicable
                                                       -- (e.g. the MGA's own fee under the program)
  profit_commission_formula         TEXT,  -- free text pending underwriting/finance sign-off - see
                                              -- ADR 0007's open items, not yet a computed formula
  effective_range                   TSTZRANGE NOT NULL
);

CREATE INDEX idx_program_participants_program ON program_participants(program_id);

-- Risk-bearing participant shares (capacity_provider + reinsurer) must sum to
-- 100% per program. This is a simplified, non-temporal version of the check -
-- it validates the CURRENT total for the affected program on every write,
-- not a full time-range-overlap-aware version like the state rating table's
-- exclusion constraint. Flagged explicitly as a simplification: a program
-- whose participant panel changes over time needs a more rigorous version
-- before this is production-safe. Documented here rather than silently
-- claiming more rigor than what's actually implemented.
CREATE OR REPLACE FUNCTION check_program_shares_sum_to_100()
RETURNS TRIGGER AS $$
DECLARE
  affected_program UUID;
  total_share NUMERIC(6,2);
BEGIN
  affected_program := COALESCE(NEW.program_id, OLD.program_id);
  SELECT COALESCE(SUM(share_percentage), 0) INTO total_share
  FROM program_participants
  WHERE program_id = affected_program
    AND participant_type IN ('capacity_provider', 'reinsurer');
  IF total_share NOT BETWEEN 99.99 AND 100.01 AND total_share != 0 THEN
    RAISE EXCEPTION 'program % risk-bearing participant shares sum to %%%, must equal 100%%',
      affected_program, total_share;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER program_participants_sum_check
  AFTER INSERT OR UPDATE OR DELETE ON program_participants
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION check_program_shares_sum_to_100();

-- ============================================================================
-- QUOTES
-- Pins the exact state_rating_table_versions record used, so a later rate
-- change never silently re-rates an already-issued quote (see that table's
-- own comment, and the registry schema's "how_this_is_used" item 6).
-- ============================================================================

CREATE TABLE quotes (
  quote_id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  application_id                    UUID NOT NULL REFERENCES applications(application_id) ON DELETE CASCADE,
  state_rating_table_record_id      UUID NOT NULL REFERENCES state_rating_table_versions(record_id),
  program_id                        UUID REFERENCES insurance_programs(program_id),  -- which capacity/
                                                                                        -- participant panel
                                                                                        -- this was written
                                                                                        -- under - see
                                                                                        -- ADR 0007
  premium_amount                    NUMERIC(12,2) NOT NULL,
  rating_basis                      JSONB NOT NULL,  -- which permitted variables/values drove the
                                                         -- price - the per-quote decision-log
                                                         -- attachment referenced in the registry schema
  status                            TEXT NOT NULL DEFAULT 'draft'
                                       CHECK (status IN ('draft', 'issued', 'bound', 'expired', 'declined')),
  quoted_at                         TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at                        TIMESTAMPTZ
);

CREATE INDEX idx_quotes_application ON quotes(application_id);
CREATE INDEX idx_quotes_program ON quotes(program_id);

-- ============================================================================
-- DOCUMENTS (metadata only - files live in Azure Blob Storage per ADR 0002/0003)
-- ============================================================================

CREATE TABLE documents (
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

CREATE INDEX idx_documents_application ON documents(application_id);

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

CREATE TRIGGER applicants_updated_at BEFORE UPDATE ON applicants
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER applications_updated_at BEFORE UPDATE ON applications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
