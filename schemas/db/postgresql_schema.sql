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
  CREATE TYPE vehicle_category_t AS ENUM ('production_luxury', 'exotic', 'classic_collector', 'modified_performance');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
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
  effective_range                   TSTZRANGE NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_program_participants_program ON program_participants(program_id);

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

DO $$ BEGIN
  CREATE CONSTRAINT TRIGGER program_participants_sum_check
    AFTER INSERT OR UPDATE OR DELETE ON program_participants
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_program_shares_sum_to_100();
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

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
  rating_basis                      JSONB NOT NULL,  -- which permitted variables/values drove the
                                                         -- price - the per-quote decision-log
                                                         -- attachment referenced in the registry schema
  status                            TEXT NOT NULL DEFAULT 'draft'
                                       CHECK (status IN ('draft', 'issued', 'bound', 'expired', 'declined')),
  quoted_at                         TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at                        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_quotes_application ON quotes(application_id);
CREATE INDEX IF NOT EXISTS idx_quotes_program ON quotes(program_id);

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
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_policies_quote ON policies(quote_id);
CREATE INDEX IF NOT EXISTS idx_policies_status ON policies(status);

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
CREATE OR REPLACE FUNCTION bind_policy(
  p_quote_id UUID,
  p_policy_number TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_quote_status TEXT;
  v_application_id UUID;
  v_policy_id UUID;
  v_effective_range TSTZRANGE;
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

  -- effective_range: neither ADR 0010 nor this task specified where a
  -- proposed policy term comes from (quotes don't carry one). Defaults to a
  -- standard one-year term starting at bind time - a reasonable placeholder,
  -- not a considered decision; a real term-selection mechanism is an open
  -- item for whoever builds the actual bind UI/flow.
  v_effective_range := tstzrange(now(), now() + interval '1 year');

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

CREATE OR REPLACE FUNCTION cancel_policy(
  p_policy_id UUID,
  p_performed_by TEXT,
  p_notes TEXT
) RETURNS VOID AS $$
DECLARE
  v_status policy_status_t;
  v_range TSTZRANGE;
BEGIN
  SELECT status, effective_range INTO v_status, v_range
  FROM policies
  WHERE policy_id = p_policy_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel_policy: policy % does not exist', p_policy_id;
  END IF;

  -- Not explicitly asked for, but the same discipline as bind_policy's
  -- precondition checks: cancelling a non-active policy either duplicates an
  -- audit event that already happened or silently reinterprets an expired/
  -- nonrenewed policy as newly cancelled - both worth rejecting explicitly
  -- rather than allowing a confusing, misleading write.
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'cancel_policy: policy % is not active (current status: %)',
      p_policy_id, v_status;
  END IF;

  UPDATE policies
  SET status = 'cancelled',
      effective_range = tstzrange(lower(v_range), now())
  WHERE policy_id = p_policy_id;

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (p_policy_id, 'cancelled', p_performed_by, p_notes);
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
CREATE OR REPLACE FUNCTION reject_policy_endorsements_mutation()
RETURNS TRIGGER AS $$
BEGIN
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

  ALTER TABLE policy_endorsements DISABLE TRIGGER policy_endorsements_no_update;
  UPDATE policy_endorsements
  SET effective_range = tstzrange(lower(v_old_range), lower(p_new_effective_range))
  WHERE endorsement_id = p_endorsement_id;
  ALTER TABLE policy_endorsements ENABLE TRIGGER policy_endorsements_no_update;

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
  vin                         TEXT,
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
  -- other. vin is nullable on the source vehicles table; two vehicles with
  -- both-null vin on the same policy won't be caught here (NULL <> NULL) -
  -- a named limitation, see ADR 0016 section 3.
  CONSTRAINT no_overlapping_policy_vehicles
    EXCLUDE USING gist (policy_id WITH =, vin WITH =, effective_range WITH &&)
);

CREATE INDEX IF NOT EXISTS idx_policy_vehicles_policy ON policy_vehicles(policy_id);

CREATE OR REPLACE FUNCTION reject_policy_vehicles_mutation()
RETURNS TRIGGER AS $$
BEGIN
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
  date_of_birth                  DATE,
  years_licensed                 SMALLINT,
  license_status                 license_status_t,
  violations_last_5yr            SMALLINT,
  at_fault_accidents_last_5yr    SMALLINT,
  created_at                     TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- additional_drivers has no SSN/license-number column - name+date_of_birth
  -- is the best available natural key, not an arbitrary choice. Same
  -- null-identity caveat as vehicles' vin: date_of_birth is nullable on the
  -- source table, so two drivers with both-null date_of_birth on the same
  -- policy won't conflict here.
  CONSTRAINT no_overlapping_policy_drivers
    EXCLUDE USING gist (policy_id WITH =, name WITH =, date_of_birth WITH =, effective_range WITH &&)
);

CREATE INDEX IF NOT EXISTS idx_policy_drivers_policy ON policy_drivers(policy_id);

CREATE OR REPLACE FUNCTION reject_policy_drivers_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'policy_drivers is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER policy_drivers_no_update
  BEFORE UPDATE ON policy_drivers
  FOR EACH ROW EXECUTE FUNCTION reject_policy_drivers_mutation();

CREATE OR REPLACE TRIGGER policy_drivers_no_delete
  BEFORE DELETE ON policy_drivers
  FOR EACH ROW EXECUTE FUNCTION reject_policy_drivers_mutation();

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

  ALTER TABLE policy_vehicles DISABLE TRIGGER policy_vehicles_no_update;
  UPDATE policy_vehicles
  SET effective_range = tstzrange(lower(v_old_range), lower(p_new_effective_range))
  WHERE policy_vehicle_id = p_policy_vehicle_id;
  ALTER TABLE policy_vehicles ENABLE TRIGGER policy_vehicles_no_update;

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

  ALTER TABLE policy_drivers DISABLE TRIGGER policy_drivers_no_update;
  UPDATE policy_drivers
  SET effective_range = tstzrange(lower(v_old_range), lower(p_new_effective_range))
  WHERE policy_driver_id = p_policy_driver_id;
  ALTER TABLE policy_drivers ENABLE TRIGGER policy_drivers_no_update;

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
  ap.status AS application_status
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
CREATE OR REPLACE VIEW luxauto_settlement_view AS
SELECT
  ('x' || substr(md5(p.policy_id::text || w.participant_id::text), 1, 8))::bit(32)::int AS id,
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
  w.net_due
FROM policies p
JOIN policy_events be ON be.policy_id = p.policy_id AND be.event_type = 'bound'
CROSS JOIN LATERAL calculate_premium_waterfall(p.quote_id) w;

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
GRANT SELECT ON luxauto_premium_waterfall_view TO odoo;
GRANT SELECT ON luxauto_settlement_view TO odoo;
GRANT EXECUTE ON FUNCTION calculate_premium_waterfall(UUID) TO odoo;
GRANT EXECUTE ON FUNCTION calculate_premium_waterfall(UUID, NUMERIC, TIMESTAMPTZ) TO odoo;
GRANT EXECUTE ON FUNCTION calculate_endorsement_waterfall(UUID) TO odoo;
GRANT EXECUTE ON FUNCTION bind_policy(UUID, TEXT, TEXT) TO odoo;
GRANT EXECUTE ON FUNCTION cancel_policy(UUID, TEXT, TEXT) TO odoo;
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
