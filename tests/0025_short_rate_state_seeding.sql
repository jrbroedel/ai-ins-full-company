-- Behavioural tests for ADR 0025: auto-seed a short-rate factor on state onboarding.
--
-- The confirmed business rule is a flat 10% admin holdback off the pro-rata
-- return (refund = 90% of pro-rata unearned), same everywhere licensed, not a
-- filed rate. ADR 0025 wires that in as a trigger on state_rating_table_versions
-- so every onboarded state (its first rating-table version) automatically gets a
-- factor 0.90 / unearned_premium_multiplier / [0,1) row - "licensed => has a
-- short-rate factor" enforced by the database, not a step someone must remember.
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, RAISE on any failed assertion,
-- IS DISTINCT FROM wherever a SELECT INTO could read NULL off a missing row.
--
-- (The counterpart revision lives in tests/0018 T6, which no longer relies on
-- the now-unreachable "licensed state but empty table" combination.)

\set ON_ERROR_STOP on
BEGIN;

-- Onboards a state exactly the way the system does today - a direct INSERT of a
-- rating-table version. Returns nothing; the trigger does the seeding.
CREATE FUNCTION pg_temp.onboard_state(p_state CHAR(2), p_tag TEXT, p_range TSTZRANGE)
RETURNS VOID AS $fx$
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code,
     serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX',
          'SERFF-0025-' || p_tag, p_range);
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  Onboarding a state auto-seeds exactly one short-rate row, with exactly the
--     confirmed values, and the lookup function actually returns it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_state CHAR(2) := 'ZA'; v_n INT;
        v_factor NUMERIC; v_basis short_rate_basis_t; v_from NUMERIC; v_to NUMERIC;
        v_prog UUID; v_applies cancellation_type_t; v_serff TEXT; v_manual TEXT; v_range TSTZRANGE;
        v_lk_factor NUMERIC; v_lk_basis short_rate_basis_t;
BEGIN
  BEGIN
    -- Precondition: no factor for this state yet.
    IF EXISTS (SELECT 1 FROM short_rate_factors WHERE state = v_state) THEN
      RAISE EXCEPTION '0025-T1 SETUP: % already has a short-rate factor before onboarding', v_state;
    END IF;

    PERFORM pg_temp.onboard_state(v_state, 'T1',
      tstzrange('2020-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'));

    -- Exactly one row.
    SELECT count(*) INTO v_n FROM short_rate_factors WHERE state = v_state;
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0025-T1 FAILED: onboarding % seeded % short-rate rows, expected exactly 1', v_state, v_n;
    END IF;

    -- Exactly the confirmed values.
    SELECT factor, basis, elapsed_fraction_from, elapsed_fraction_to,
           program_id, applies_to, serff_filing_tracking_number, rate_manual_reference, effective_range
      INTO v_factor, v_basis, v_from, v_to, v_prog, v_applies, v_serff, v_manual, v_range
    FROM short_rate_factors WHERE state = v_state;

    IF v_factor IS DISTINCT FROM 0.90 THEN
      RAISE EXCEPTION '0025-T1 FAILED: seeded factor is %, expected 0.90 (10%% holdback: refund = 90%% of pro-rata unearned)', v_factor;
    END IF;
    IF v_basis IS DISTINCT FROM 'unearned_premium_multiplier' THEN
      RAISE EXCEPTION '0025-T1 FAILED: seeded basis is %, expected unearned_premium_multiplier', v_basis;
    END IF;
    IF v_from IS DISTINCT FROM 0 OR v_to IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION '0025-T1 FAILED: seeded band is [%,%), expected the single full band [0,1)', v_from, v_to;
    END IF;
    IF v_prog IS NOT NULL OR v_applies IS NOT NULL THEN
      RAISE EXCEPTION '0025-T1 FAILED: seeded row is not universal (program_id=%, applies_to=%), both should be NULL', v_prog, v_applies;
    END IF;
    IF v_serff IS DISTINCT FROM 'internally set - not filed' THEN
      RAISE EXCEPTION '0025-T1 FAILED: provenance is %, expected the internally-set sentinel (must not look like a real filing)', v_serff;
    END IF;
    IF v_manual IS NOT NULL THEN
      RAISE EXCEPTION '0025-T1 FAILED: rate_manual_reference is %, expected NULL', v_manual;
    END IF;
    -- Unbounded effective range: in force at any cancellation date.
    IF NOT (v_range @> now()) OR NOT (v_range @> '2019-01-01 00:00:00+00'::timestamptz) THEN
      RAISE EXCEPTION '0025-T1 FAILED: seeded effective_range % does not cover arbitrary cancellation dates', v_range;
    END IF;

    -- The lookup actually returns it (any elapsed fraction, both initiators).
    SELECT factor, basis INTO v_lk_factor, v_lk_basis
    FROM short_rate_factor(v_state, NULL, 'company_initiated'::cancellation_type_t, 0.73, now());
    IF (v_lk_factor, v_lk_basis) IS DISTINCT FROM (0.90, 'unearned_premium_multiplier'::short_rate_basis_t) THEN
      RAISE EXCEPTION '0025-T1 FAILED: short_rate_factor() returned %/%, expected 0.90/unearned_premium_multiplier', v_lk_factor, v_lk_basis;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0025-T1 pass: onboarding a state seeds exactly one 0.90 / unearned_premium_multiplier / [0,1) factor, and the lookup returns it';
END $$;

-- ---------------------------------------------------------------------------
-- T2  A second rating-table VERSION of an already-onboarded state does NOT
--     seed a duplicate - the NOT EXISTS guard makes the seed once-per-state.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_state CHAR(2) := 'ZB'; v_n INT;
BEGIN
  BEGIN
    -- First version onboards the state and seeds the factor.
    PERFORM pg_temp.onboard_state(v_state, 'T2v1',
      tstzrange('2000-01-01 00:00:00+00', '2020-01-01 00:00:00+00', '[)'));
    SELECT count(*) INTO v_n FROM short_rate_factors WHERE state = v_state;
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0025-T2 SETUP: first version seeded % rows, expected 1', v_n;
    END IF;

    -- Second, non-overlapping version of the SAME state (a rating refresh).
    PERFORM pg_temp.onboard_state(v_state, 'T2v2',
      tstzrange('2020-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'));

    SELECT count(*) INTO v_n FROM short_rate_factors WHERE state = v_state;
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0025-T2 FAILED: a second rating-table version duplicated the short-rate factor (% rows for %, expected 1)', v_n, v_state;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0025-T2 pass: re-versioning a state''s rating table does not duplicate its short-rate factor';
END $$;

-- ---------------------------------------------------------------------------
-- T3  The override hatch: a deliberately pre-seeded state-specific factor is
--     left untouched when the state is onboarded - not overwritten to 0.90, not
--     duplicated. This is what leaves room for a future state to differ without
--     a schema change.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_state CHAR(2) := 'ZC'; v_n INT; v_factor NUMERIC;
BEGIN
  BEGIN
    -- Pre-seed a state-specific override (a different factor) BEFORE onboarding.
    INSERT INTO short_rate_factors
      (state, factor, basis, effective_range, serff_filing_tracking_number)
    VALUES (v_state, 0.80, 'unearned_premium_multiplier'::short_rate_basis_t,
            tstzrange(NULL, NULL), 'internally set - ZC-specific override');

    -- Now onboard the state.
    PERFORM pg_temp.onboard_state(v_state, 'T3',
      tstzrange('2020-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'));

    -- Still exactly one row, and still the override 0.80 - not replaced, not duplicated.
    SELECT count(*) INTO v_n FROM short_rate_factors WHERE state = v_state;
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0025-T3 FAILED: onboarding over a pre-seeded factor left % rows for %, expected 1', v_n, v_state;
    END IF;
    SELECT factor INTO v_factor FROM short_rate_factors WHERE state = v_state;
    IF v_factor IS DISTINCT FROM 0.80 THEN
      RAISE EXCEPTION '0025-T3 FAILED: the pre-seeded override factor was changed to % (expected 0.80 left untouched)', v_factor;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0025-T3 pass: a pre-seeded state-specific factor is respected - the seed is a default, not an override';
END $$;

ROLLBACK;

\echo '0025: 3/3 cases passed (nothing committed)'
