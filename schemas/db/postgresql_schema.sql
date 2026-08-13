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
CREATE OR REPLACE FUNCTION first_program_share_gap(p_program_id UUID)
RETURNS TABLE (bad_instant TIMESTAMPTZ, total_share NUMERIC) AS $$
  WITH prog AS (
    SELECT effective_range AS term FROM insurance_programs WHERE program_id = p_program_id
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
  )
  SELECT p.t,
         COALESCE((SELECT SUM(r.share_percentage) FROM risk r WHERE r.effective_range @> p.t), 0)
  FROM probes p, prog
  WHERE p.t IS NOT NULL                 -- an unbounded row bound; the program's own probe covers it
    AND prog.term @> p.t                -- '[)' semantics: the term's own upper bound isn't inside it
    AND EXISTS (SELECT 1 FROM risk)
    AND COALESCE((SELECT SUM(r.share_percentage) FROM risk r WHERE r.effective_range @> p.t), 0)
        NOT BETWEEN 99.99 AND 100.01
  ORDER BY p.t
  LIMIT 1;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION check_program_shares_sum_to_100()
RETURNS TRIGGER AS $$
DECLARE
  v_program_id UUID;
  v_term TSTZRANGE;
  v_outside RECORD;
  v_gap RECORD;
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

  SELECT * INTO v_gap FROM first_program_share_gap(v_program_id);

  IF FOUND THEN
    RAISE EXCEPTION 'PROGRAM_SHARES_NOT_100_AT_INSTANT: program % risk-bearing participant shares sum to %%% as of %, must equal 100%%',
      v_program_id, v_gap.total_share, v_gap.bad_instant
      USING HINT = 'Under 100% means a gap (an instant where part of the risk is unplaced); over 100% usually means an old row was not closed when its replacement was added. This trigger is DEFERRABLE INITIALLY DEFERRED, so close the outgoing row and add the incoming one in the same transaction.';
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
-- Extended again by the ADR 0016 addendum: refuses to bind an application
-- whose vehicles/drivers are missing the identity fields the snapshot
-- tables' exclusion constraints key on (BIND_BLOCKED_MISSING_VEHICLE_VIN /
-- BIND_BLOCKED_MISSING_DRIVER_IDENTITY). Signature still unchanged.
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

  v_policy_years := EXTRACT(EPOCH FROM (v_at - lower(v_term))) / (365.25 * 86400);
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

  v_policy_years := EXTRACT(EPOCH FROM (p_new_notice_at - lower(v_term))) / (365.25 * 86400);
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
