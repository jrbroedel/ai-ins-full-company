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
CREATE TYPE policy_status_t AS ENUM ('active', 'cancelled', 'expired', 'nonrenewed');

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

-- Commission waterfall (ADR 0010): given a bound/issued quote, compute each
-- program participant's share of gross premium and their net-due amount
-- after their own commission_rate. Single source of truth for both the Odoo
-- Premium/Waterfall view and any future bordereau-style settlement report -
-- both read this function rather than each re-deriving the math (ADR 0010).
-- Computes only what the schema currently models (a flat share_percentage
-- and a single commission_rate per participant) - does not resolve the
-- layered retail/wholesale broker commission tiers from the Energy manual's
-- Ch.10 waterfall, or the still-free-text profit_commission_formula. See
-- ADR 0007's open items and ADR 0010's note on this function's scope.
--
-- SECURITY DEFINER, not the default SECURITY INVOKER: unlike a plain view
-- (which transparently runs with its owner's table privileges), a function
-- called from within a view does NOT inherit the view owner's rights - it
-- runs as whichever role actually queries it. luxauto_premium_waterfall_view
-- calls this function, and the least-privilege `odoo` Postgres role (ADR
-- 0009) has no direct grant on quotes/program_participants - only on the
-- views. SECURITY DEFINER makes this function a controlled read gateway,
-- the same role a view already plays, without widening `odoo`'s privileges
-- to the base tables themselves. search_path is pinned to close the
-- standard SECURITY DEFINER search-path-injection gotcha. Caught live
-- while installing the Odoo module that reads this view (ADR 0010) - the
-- function worked fine when called directly as the Postgres admin role
-- during earlier testing, which never exercised the `odoo` role's actual,
-- narrower privileges.
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
  SELECT
    pp.participant_id,
    pp.participant_name,
    pp.participant_type,
    pp.share_percentage,
    pp.commission_rate,
    ROUND(q.premium_amount * pp.share_percentage / 100, 2) AS gross_share,
    ROUND(q.premium_amount * pp.share_percentage / 100
          * COALESCE(pp.commission_rate, 0) / 100, 2) AS commission_amount,
    ROUND(q.premium_amount * pp.share_percentage / 100
          * (1 - COALESCE(pp.commission_rate, 0) / 100), 2) AS net_due
  FROM quotes q
  JOIN program_participants pp
    ON pp.program_id = q.program_id
   AND pp.effective_range @> q.quoted_at
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
CREATE OR REPLACE FUNCTION bind_policy(
  p_quote_id UUID,
  p_policy_number TEXT,
  p_performed_by TEXT
) RETURNS UUID AS $$
DECLARE
  v_quote_status TEXT;
  v_policy_id UUID;
BEGIN
  SELECT status INTO v_quote_status
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
  INSERT INTO policies (policy_id, quote_id, policy_number, effective_range, status)
  VALUES (
    uuid_generate_v4(), p_quote_id, p_policy_number,
    tstzrange(now(), now() + interval '1 year'), 'active'
  )
  RETURNING policy_id INTO v_policy_id;

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
-- POLICIES (ADR 0010)
-- The result of binding a quote - one policy per bound quote, enforced by the
-- UNIQUE constraint on quote_id below. quotes.status transitions to 'bound'
-- in the same transaction that inserts this row (the bind server action -
-- ADR 0010 section 4), so a policy's existence and its quote's 'bound' status
-- are set together, not independently. Endorsements (mid-term changes to an
-- already-bound policy) are explicitly out of scope for this table - see
-- ADR 0010's own note and the follow-on ADR it calls for.
-- ============================================================================

CREATE TABLE policies (
  policy_id                         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  quote_id                          UUID NOT NULL UNIQUE REFERENCES quotes(quote_id),
  policy_number                     TEXT,
  effective_range                   TSTZRANGE NOT NULL,
  status                            policy_status_t NOT NULL DEFAULT 'active',
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_policies_quote ON policies(quote_id);
CREATE INDEX idx_policies_status ON policies(status);

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

CREATE TABLE policy_events (
  event_id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id                         UUID NOT NULL REFERENCES policies(policy_id) ON DELETE CASCADE,
  event_type                        TEXT NOT NULL,             -- e.g. 'bound', 'cancelled'
  performed_by                      TEXT NOT NULL,             -- 'system' or a specific user identifier
  notes                             TEXT,
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_policy_events_policy ON policy_events(policy_id);

CREATE OR REPLACE FUNCTION reject_policy_events_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'policy_events is append-only: % is not permitted', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER policy_events_no_update
  BEFORE UPDATE ON policy_events
  FOR EACH ROW EXECUTE FUNCTION reject_policy_events_mutation();

CREATE TRIGGER policy_events_no_delete
  BEFORE DELETE ON policy_events
  FOR EACH ROW EXECUTE FUNCTION reject_policy_events_mutation();

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

-- These three views are owned by whichever role runs this script (the
-- Postgres admin, in practice - see ADR 0011), not by the `odoo` role Odoo
-- itself connects as (ADR 0009). A plain view runs with its owner's table
-- privileges for any caller with SELECT on the view, so `odoo` needs that
-- SELECT grant explicitly - it doesn't get it just by the view existing.
-- Assumes the `odoo` role already exists (ADR 0009 creates it) when this
-- file is applied to luxauto-pg's luxauto database, same assumption the
-- rest of this file already makes about running against that database.
GRANT SELECT ON luxauto_insured_view TO odoo;
GRANT SELECT ON luxauto_policy_view TO odoo;
GRANT SELECT ON luxauto_premium_waterfall_view TO odoo;
GRANT EXECUTE ON FUNCTION calculate_premium_waterfall(UUID) TO odoo;
GRANT EXECUTE ON FUNCTION bind_policy(UUID, TEXT, TEXT) TO odoo;
GRANT EXECUTE ON FUNCTION cancel_policy(UUID, TEXT, TEXT) TO odoo;

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
CREATE TRIGGER policies_updated_at BEFORE UPDATE ON policies
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
