-- Behavioural tests for ADR 0018: return premium and cancellation.
-- See docs/decisions/0018-return-premium-and-cancellation.md, including its
-- two addenda.
--
-- Backfilled by ADR 0018's second addendum. ADR 0018 predates the tests/
-- harness (ADR 0022) and was named there as one of the suites still missing;
-- every case here corresponds to something ADR 0018 argued, measured by hand,
-- or explicitly confirmed-rather-than-built.
--
-- Same structure as the 0017 and 0021 suites: one transaction rolled back at
-- the end, one self-unwinding DO block per case, SET CONSTRAINTS ALL IMMEDIATE
-- instead of committing, RAISE on any assertion that does not hold, and cases
-- asserting a rejection assert on the error MESSAGE rather than merely on the
-- fact that something failed.
--
-- Every timestamp is written with an explicit +00 offset. These cases assert
-- refunds to the cent, and a bare '2026-04-01' would be read in the session's
-- timezone - where a DST boundary between two dates makes an epoch difference
-- an hour short of a whole number of days and turns exact arithmetic into
-- almost-exact arithmetic. The pro-rata numbers below are all whole
-- currency-per-day figures on purpose, so a wrong answer is obvious rather
-- than a rounding argument.

\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- Fixture. A cancellation needs a whole bound policy behind it - applicant,
-- application, vehicle, driver, rating version, program, panel, quote, policy
-- and the policy's own vehicle/driver snapshots - which is nine inserts the
-- 0017/0021 suites never needed. Built once here rather than nine times per
-- case, in pg_temp so it is invisible to any other session and gone with this
-- one regardless of how the suite exits.
--
-- The snapshots are inserted directly rather than through bind_policy(),
-- which dates a policy term from now() (see its own note about that being a
-- placeholder). These cases need a fixed term to assert exact refunds
-- against.
--
-- Each caller passes its own state: state_rating_table_versions carries an
-- exclusion constraint on (state, effective_range), so one state per case
-- keeps the fixtures from colliding with each other.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.mk_policy(
  p_tag TEXT,
  p_state CHAR(2),
  p_premium NUMERIC,
  p_term TSTZRANGE
) RETURNS UUID AS $fx$
DECLARE
  v_rating UUID; v_applicant UUID; v_app UUID; v_vehicle UUID; v_driver UUID;
  v_program UUID; v_quote UUID; v_policy UUID; v_program_term TSTZRANGE;
BEGIN
  -- Wider than the policy term at both ends: the panel has to be in force at
  -- the cancellation date for calculate_cancellation_waterfall() to find it,
  -- and program_participants must sit inside the program's own term.
  v_program_term := tstzrange(lower(p_term) - interval '1 year',
                              upper(p_term) + interval '1 year', '[)');

  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code,
     serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX',
          'SERFF-0018-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO v_rating;

  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0018-' || p_tag)
  RETURNING applicant_id INTO v_applicant;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'bound', p_state)
  RETURNING application_id INTO v_app;

  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state)
  VALUES (v_app, 2024, 'Aston Martin', 'DB12', 'VIN0018' || p_tag, 'exotic', p_state)
  RETURNING vehicle_id INTO v_vehicle;

  INSERT INTO additional_drivers (application_id, name, date_of_birth)
  VALUES (v_app, 'Driver ' || p_tag, DATE '1980-01-01')
  RETURNING driver_id INTO v_driver;

  INSERT INTO insurance_programs (program_name, capacity_provider_name, effective_range)
  VALUES ('0018-' || p_tag, 'Fronting Co', v_program_term)
  RETURNING program_id INTO v_program;

  -- 60/40 with a 10% commission on the capacity provider's share: enough for
  -- the waterfall assertions to distinguish gross, commission and net.
  INSERT INTO program_participants
    (program_id, participant_type, participant_name, share_percentage, commission_rate, effective_range)
  VALUES (v_program, 'capacity_provider', 'Fronting Co', 60, 10, v_program_term),
         (v_program, 'reinsurer',         'Re Two',      40,  0, v_program_term);

  INSERT INTO quotes
    (application_id, state_rating_table_record_id, program_id, premium_amount, rating_basis, status,
     broker_channel, broker_commission_rate)
  VALUES (v_app, v_rating, v_program, p_premium, '{}'::jsonb, 'bound',
          'retail', 10)
  RETURNING quote_id INTO v_quote;

  INSERT INTO policies (quote_id, policy_number, effective_range, status)
  VALUES (v_quote, 'POL-0018-' || p_tag, p_term, 'active')
  RETURNING policy_id INTO v_policy;

  INSERT INTO policy_vehicles
    (policy_id, source_vehicle_id, effective_range, year, make, model, vin,
     vehicle_category, garaging_state)
  VALUES (v_policy, v_vehicle, p_term, 2024, 'Aston Martin', 'DB12',
          'VIN0018' || p_tag, 'exotic', p_state);

  INSERT INTO policy_drivers
    (policy_id, source_driver_id, effective_range, name, date_of_birth)
  VALUES (v_policy, v_driver, p_term, 'Driver ' || p_tag, DATE '1980-01-01');

  INSERT INTO policy_events (policy_id, event_type, performed_by, notes)
  VALUES (v_policy, 'bound', '0018-suite', 'fixture');

  -- The share-sum trigger is DEFERRABLE INITIALLY DEFERRED and this suite
  -- never commits, so a broken fixture panel would otherwise go unnoticed.
  SET CONSTRAINTS ALL IMMEDIATE;

  RETURN v_policy;
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  cancel_policy() happy path, end to end, on a known example.
--
--     36,500 written over a 365-day term is exactly 100/day. Cancelled at day
--     90 (2026-04-01), 275 days remain, so the unearned premium is 27,500.00
--     and the return premium is -27,500.00 - negative because the sign IS the
--     direction (ADR 0018 section 3).
--
--     ADR 0018 section 4's whole argument is that this is one transaction
--     touching four tables, so every one of them is asserted here.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_cx UUID;
        v_status policy_status_t; v_range TSTZRANGE;
        v_unearned NUMERIC; v_return NUMERIC; v_method refund_method_t;
        v_factor NUMERIC; v_basis short_rate_basis_t;
        v_veh TIMESTAMPTZ; v_drv TIMESTAMPTZ; v_n INT; v_sum NUMERIC;
BEGIN
  BEGIN
    v_policy := pg_temp.mk_policy('T1', 'CA', 36500,
      tstzrange('2026-01-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'));

    SELECT cancel_policy(v_policy, 'insured_initiated', 'CX_INSURED_REQUEST',
                         'pro_rata', '2026-04-01 00:00:00+00', 'sold the car',
                         '0018-suite')
      INTO v_cx;

    -- (1) policies: status and a truncated term.
    SELECT status, effective_range INTO v_status, v_range
    FROM policies WHERE policy_id = v_policy;
    IF v_status IS DISTINCT FROM 'cancelled' THEN
      RAISE EXCEPTION '0018-T1 FAILED: expected status cancelled, got %', v_status;
    END IF;
    IF v_range IS DISTINCT FROM tstzrange('2026-01-01 00:00:00+00', '2026-04-01 00:00:00+00', '[)') THEN
      RAISE EXCEPTION '0018-T1 FAILED: policy term was not truncated to the cancellation date, got %', v_range;
    END IF;

    -- (2) the vehicle and driver snapshots are closed at the same instant.
    SELECT upper(effective_range) INTO v_veh FROM policy_vehicles WHERE policy_id = v_policy;
    SELECT upper(effective_range) INTO v_drv FROM policy_drivers  WHERE policy_id = v_policy;
    IF v_veh IS DISTINCT FROM '2026-04-01 00:00:00+00'::timestamptz THEN
      RAISE EXCEPTION '0018-T1 FAILED: the vehicle snapshot was not closed at the cancellation date, got %', v_veh;
    END IF;
    IF v_drv IS DISTINCT FROM '2026-04-01 00:00:00+00'::timestamptz THEN
      RAISE EXCEPTION '0018-T1 FAILED: the driver snapshot was not closed at the cancellation date, got %', v_drv;
    END IF;

    -- (3) the cancellation row, its range, and the refund itself.
    SELECT effective_range, unearned_premium, return_premium, refund_method,
           short_rate_factor, short_rate_basis
      INTO v_range, v_unearned, v_return, v_method, v_factor, v_basis
    FROM policy_cancellations WHERE cancellation_id = v_cx;

    IF v_range IS DISTINCT FROM tstzrange('2026-04-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)') THEN
      RAISE EXCEPTION '0018-T1 FAILED: the cancellation range is not [cancelled_at, original term end), got %', v_range;
    END IF;
    IF v_unearned IS DISTINCT FROM 27500.00 THEN
      RAISE EXCEPTION '0018-T1 FAILED: expected 27500.00 unearned at day 90 of a 100/day policy, got %', v_unearned;
    END IF;
    IF v_return IS DISTINCT FROM -27500.00 THEN
      RAISE EXCEPTION '0018-T1 FAILED: expected a return premium of -27500.00 (negative = owed back), got %', v_return;
    END IF;
    IF v_method IS DISTINCT FROM 'pro_rata' OR v_factor IS NOT NULL OR v_basis IS NOT NULL THEN
      RAISE EXCEPTION '0018-T1 FAILED: a pro-rata cancellation carried short-rate provenance (% / % / %)',
        v_method, v_factor, v_basis;
    END IF;

    -- (4) the audit event.
    SELECT count(*) INTO v_n FROM policy_events
    WHERE policy_id = v_policy AND event_type = 'cancelled';
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0018-T1 FAILED: expected exactly one cancelled event, got %', v_n;
    END IF;

    -- The refund reaches the panel through the shared waterfall core, in
    -- proportion and with the sign intact (ADR 0018 section 3).
    SELECT count(*), SUM(gross_share) INTO v_n, v_sum
    FROM calculate_cancellation_waterfall(v_cx);
    IF v_n <> 2 THEN
      RAISE EXCEPTION '0018-T1 FAILED: expected the 2-participant panel in the refund waterfall, got %', v_n;
    END IF;
    IF v_sum IS DISTINCT FROM -27500.00 THEN
      RAISE EXCEPTION '0018-T1 FAILED: the participant shares sum to % rather than the return premium -27500.00', v_sum;
    END IF;
    IF (SELECT gross_share FROM calculate_cancellation_waterfall(v_cx)
         WHERE participant_name = 'Fronting Co') IS DISTINCT FROM -16500.00 THEN
      RAISE EXCEPTION '0018-T1 FAILED: the 60%% participant''s share of -27500.00 is not -16500.00';
    END IF;

    -- And the ADR 0018 addendum's own read side shows it, unsuperseded.
    SELECT count(*) INTO v_n FROM luxauto_policy_cancellation_view
    WHERE policy_id = v_policy AND NOT superseded
      AND cancelled_at = '2026-04-01 00:00:00+00'::timestamptz;
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0018-T1 FAILED: luxauto_policy_cancellation_view shows % live cancellation rows, expected 1', v_n;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0018-T1 pass: status, term, snapshots, cancellation row, refund, event and waterfall all correct';
END $$;

-- ---------------------------------------------------------------------------
-- T2  ADR 0018 section 1: a mid-term coverage reduction is an endorsement with
--     a negative premium_delta, and needs no special-casing. That section is a
--     confirmation rather than a build, which is exactly the kind of claim
--     that rots silently without a committed test - nothing would fail if a
--     later change made the waterfall asymmetric on negatives.
--
--     The waterfall is linear in amount, so -6,000 must be the exact mirror
--     image of +6,000: -3,600.00 / -360.00 / -3,240.00 at a 60% share with a
--     10% commission.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_program UUID; v_end UUID;
        v_gross NUMERIC; v_comm NUMERIC; v_net NUMERIC;
        v_pos_gross NUMERIC; v_pos_comm NUMERIC; v_pos_net NUMERIC;
        v_sum NUMERIC;
BEGIN
  BEGIN
    v_policy := pg_temp.mk_policy('T2', 'NV', 36500,
      tstzrange('2026-01-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'));
    SELECT q.program_id INTO v_program
    FROM policies p JOIN quotes q ON q.quote_id = p.quote_id
    WHERE p.policy_id = v_policy;

    SELECT gross_share, commission_amount, net_due INTO v_gross, v_comm, v_net
    FROM calculate_premium_waterfall(v_program, -6000, '2026-06-01 00:00:00+00')
    WHERE participant_name = 'Fronting Co';
    SELECT gross_share, commission_amount, net_due INTO v_pos_gross, v_pos_comm, v_pos_net
    FROM calculate_premium_waterfall(v_program, 6000, '2026-06-01 00:00:00+00')
    WHERE participant_name = 'Fronting Co';

    IF (v_gross, v_comm, v_net) IS DISTINCT FROM (-3600.00, -360.00, -3240.00) THEN
      RAISE EXCEPTION '0018-T2 FAILED: a -6000 waterfall returned %/%/%, expected -3600.00/-360.00/-3240.00',
        v_gross, v_comm, v_net;
    END IF;
    IF (v_gross, v_comm, v_net) IS DISTINCT FROM (-v_pos_gross, -v_pos_comm, -v_pos_net) THEN
      RAISE EXCEPTION '0018-T2 FAILED: the negative waterfall is not the mirror image of the positive one (%/%/% vs %/%/%)',
        v_gross, v_comm, v_net, v_pos_gross, v_pos_comm, v_pos_net;
    END IF;

    -- endorse_policy() accepts the negative delta - no CHECK constraint
    -- anywhere requires a positive premium - and the endorsement waterfall
    -- splits it exactly.
    v_end := endorse_policy(v_policy,
      tstzrange('2026-02-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'),
      'premium_adjustment', -6000, 'coverage reduced mid-term', '0018-suite');

    SELECT SUM(gross_share) INTO v_sum FROM calculate_endorsement_waterfall(v_end);
    IF v_sum IS DISTINCT FROM -6000.00 THEN
      RAISE EXCEPTION '0018-T2 FAILED: the per-participant shares of a -6000 endorsement sum to %, not -6000.00', v_sum;
    END IF;
    IF EXISTS (
      SELECT 1 FROM calculate_endorsement_waterfall(v_end)
      WHERE commission_amount + net_due <> gross_share
    ) THEN
      RAISE EXCEPTION '0018-T2 FAILED: commission + net does not reconstruct gross on a negative delta';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0018-T2 pass: a negative premium_delta needs no special-casing, and the arithmetic is exactly mirrored';
END $$;

-- ---------------------------------------------------------------------------
-- T3  ADR 0018 section 1's last confirmation: correct_policy_endorsement()
--     works on a negative-delta endorsement, INCLUDING when its id is resolved
--     by a subquery scanning policy_endorsements in the same statement. That
--     is the ADR 0016 addendum 2 trap - the shape that used to fail with
--     "cannot ALTER TABLE because it is being used by active queries in this
--     session" - so the call below is deliberately written the failing way.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_old UUID; v_new UUID; v_old_upper TIMESTAMPTZ; v_delta NUMERIC;
BEGIN
  BEGIN
    v_policy := pg_temp.mk_policy('T3', 'AZ', 36500,
      tstzrange('2026-01-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'));

    v_old := endorse_policy(v_policy,
      tstzrange('2026-02-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'),
      'premium_adjustment', -6000, 'reduction, wrong amount', '0018-suite');

    SELECT correct_policy_endorsement(
             (SELECT endorsement_id FROM policy_endorsements
               WHERE policy_id = v_policy AND premium_delta = -6000),
             tstzrange('2026-03-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'),
             'premium_adjustment', -6500, 'reduction, corrected', '0018-suite')
      INTO v_new;

    SELECT upper(effective_range) INTO v_old_upper
    FROM policy_endorsements WHERE endorsement_id = v_old;
    IF v_old_upper IS DISTINCT FROM '2026-03-01 00:00:00+00'::timestamptz THEN
      RAISE EXCEPTION '0018-T3 FAILED: the superseded negative endorsement was not closed at the successor start, got %', v_old_upper;
    END IF;

    SELECT premium_delta INTO v_delta FROM policy_endorsements WHERE endorsement_id = v_new;
    IF v_delta IS DISTINCT FROM -6500.00 THEN
      RAISE EXCEPTION '0018-T3 FAILED: the corrected delta is %, expected -6500.00', v_delta;
    END IF;
    IF (SELECT SUM(gross_share) FROM calculate_endorsement_waterfall(v_new)) IS DISTINCT FROM -6500.00 THEN
      RAISE EXCEPTION '0018-T3 FAILED: the corrected negative endorsement does not split to -6500.00';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0018-T3 pass: a negative endorsement corrects cleanly, including through a subquery on its own table';
END $$;

-- ---------------------------------------------------------------------------
-- T4  ADR 0018 section 6: correcting a cancellation to an EARLIER date. This
--     is the direction that breaks the other four correction functions (the
--     consequence ADR 0018 recorded and ADR 0016 addendum 3 later fixed):
--     there is no valid closed range to leave behind, because upper < lower is
--     not a range. This function empties the old row instead.
--
--     Cancelled at day 90, corrected back to day 31 (2026-02-01): 334 days
--     remain of a 100/day policy, so the refund must be recomputed against the
--     ORIGINAL term - 33,400.00, not a re-prorating of the already-truncated
--     one.
--
--     The second vehicle is here for the GREATEST() in the snapshot move: it
--     starts on 2026-03-01, AFTER the corrected date, so it must close to its
--     own start (an empty range) rather than to an impossible one.
--
--     The correction is called with its target id resolved by a subquery
--     scanning policy_cancellations, for the same reason as T3.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_cx UUID; v_new UUID; v_src UUID; v_state CHAR(2) := 'OR';
        v_return NUMERIC; v_range TSTZRANGE; v_n INT; v_sum NUMERIC;
BEGIN
  BEGIN
    v_policy := pg_temp.mk_policy('T4', v_state, 36500,
      tstzrange('2026-01-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'));

    SELECT v.vehicle_id INTO v_src
    FROM policies p
    JOIN quotes q ON q.quote_id = p.quote_id
    JOIN vehicles v ON v.application_id = q.application_id
    WHERE p.policy_id = v_policy;

    INSERT INTO policy_vehicles
      (policy_id, source_vehicle_id, effective_range, year, make, model, vin,
       vehicle_category, garaging_state)
    VALUES (v_policy, v_src,
            tstzrange('2026-03-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'),
            2025, 'Ferrari', 'Roma', 'VIN0018T4-LATE', 'exotic', v_state);

    SELECT cancel_policy(v_policy, 'company_initiated', 'CX_NONPAYMENT',
                         'pro_rata', '2026-04-01 00:00:00+00', 'wrong date',
                         '0018-suite')
      INTO v_cx;

    SELECT correct_policy_cancellation(
             (SELECT cancellation_id FROM policy_cancellations
               WHERE policy_id = v_policy AND NOT isempty(effective_range)),
             '2026-02-01 00:00:00+00', 'company_initiated', 'CX_NONPAYMENT',
             'pro_rata', 'corrected to the real notice date', '0018-suite')
      INTO v_new;

    -- The superseded row is emptied outright, not closed at the new start.
    IF NOT (SELECT isempty(effective_range) FROM policy_cancellations WHERE cancellation_id = v_cx) THEN
      RAISE EXCEPTION '0018-T4 FAILED: the superseded cancellation was not emptied - it still claims a period it never covered';
    END IF;

    SELECT effective_range, return_premium INTO v_range, v_return
    FROM policy_cancellations WHERE cancellation_id = v_new;
    IF v_range IS DISTINCT FROM tstzrange('2026-02-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)') THEN
      RAISE EXCEPTION '0018-T4 FAILED: the corrected row does not run from the new date to the ORIGINAL term end, got %', v_range;
    END IF;
    IF v_return IS DISTINCT FROM -33400.00 THEN
      RAISE EXCEPTION '0018-T4 FAILED: expected -33400.00 recomputed against the original term (334 days at 100/day), got %', v_return;
    END IF;

    -- Append-only: two rows, not one edited in place.
    SELECT count(*) INTO v_n FROM policy_cancellations WHERE policy_id = v_policy;
    IF v_n <> 2 THEN
      RAISE EXCEPTION '0018-T4 FAILED: expected 2 cancellation rows after a correction, got %', v_n;
    END IF;

    -- Coverage follows the corrected date.
    IF (SELECT effective_range FROM policies WHERE policy_id = v_policy)
       IS DISTINCT FROM tstzrange('2026-01-01 00:00:00+00', '2026-02-01 00:00:00+00', '[)') THEN
      RAISE EXCEPTION '0018-T4 FAILED: the policy term did not move back to the corrected date';
    END IF;
    IF (SELECT upper(effective_range) FROM policy_vehicles
         WHERE policy_id = v_policy AND vin = 'VIN0018T4')
       IS DISTINCT FROM '2026-02-01 00:00:00+00'::timestamptz THEN
      RAISE EXCEPTION '0018-T4 FAILED: the vehicle snapshot did not follow the corrected date';
    END IF;
    IF (SELECT upper(effective_range) FROM policy_drivers WHERE policy_id = v_policy)
       IS DISTINCT FROM '2026-02-01 00:00:00+00'::timestamptz THEN
      RAISE EXCEPTION '0018-T4 FAILED: the driver snapshot did not follow the corrected date';
    END IF;

    -- GREATEST(): the row that started after the corrected date closes to its
    -- own start, which is an empty range - not upper < lower.
    IF NOT (SELECT isempty(effective_range) FROM policy_vehicles
             WHERE policy_id = v_policy AND vin = 'VIN0018T4-LATE') THEN
      RAISE EXCEPTION '0018-T4 FAILED: a snapshot starting after the corrected date was not emptied, got %',
        (SELECT effective_range FROM policy_vehicles WHERE policy_id = v_policy AND vin = 'VIN0018T4-LATE');
    END IF;

    SELECT count(*) INTO v_n FROM policy_events
    WHERE policy_id = v_policy AND event_type = 'cancellation_corrected';
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0018-T4 FAILED: expected exactly one cancellation_corrected event, got %', v_n;
    END IF;

    -- The emptied row is never owed: the settlement report drops it, and the
    -- read-side view keeps it visible but flagged (ADR 0018's addendum).
    SELECT count(*), COALESCE(SUM(gross_share), 0) INTO v_n, v_sum
    FROM luxauto_settlement_view
    WHERE policy_id = v_policy AND transaction_type = 'return_premium';
    IF v_n <> 2 OR v_sum IS DISTINCT FROM -33400.00 THEN
      RAISE EXCEPTION '0018-T4 FAILED: the settlement report shows % return-premium rows summing to %, expected 2 rows (one per participant) summing to -33400.00 - the emptied cancellation must not appear',
        v_n, v_sum;
    END IF;
    SELECT count(*) INTO v_n FROM luxauto_policy_cancellation_view
    WHERE policy_id = v_policy AND superseded;
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0018-T4 FAILED: luxauto_policy_cancellation_view shows % superseded rows, expected exactly 1', v_n;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0018-T4 pass: an earlier-date correction empties, recomputes against the original term, and moves coverage with it';
END $$;

-- ---------------------------------------------------------------------------
-- T5  ADR 0018's FIRST addendum, which is the reason this case exists: an
--     endorsement whose range extends past a cancellation is deliberately NOT
--     closed out. That looks like an oversight and is not one - the range is
--     the period the premium is EARNED OVER, and it is the denominator
--     correct_policy_cancellation() needs when it recomputes a refund.
--
--     The addendum proved this by hand, once, with a measured table of what
--     truncation would have cost. This case is that measurement, committed, so
--     it never has to be hand-verified again - and so that anyone "tidying up"
--     the stale range gets a failing test instead of a wrong refund.
--
--     36,500 over 365 days = 100/day. A +6,700 endorsement over its own 335
--     days = 20/day. Cancelled at day 90 with 275 days left: 27,500 + 5,500 =
--     33,000.00. Corrected back to 2026-03-01 with 306 days left:
--     30,600 + 6,120 = 36,720.00.
--
--     Had the endorsement been truncated at the cancellation date, its 6,700
--     would have been re-prorated over 60 days instead of 335, and the same
--     correction would have returned 34,061.67 - a 2,658.33 error in a number
--     somebody gets paid. That counterfactual is computed here rather than
--     quoted, so the assertion is that the two answers genuinely differ.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_end UUID; v_cx UUID; v_new UUID;
        v_return NUMERIC; v_counterfactual NUMERIC;
        v_before NUMERIC; v_after NUMERIC; v_range TSTZRANGE;
BEGIN
  BEGIN
    v_policy := pg_temp.mk_policy('T5', 'WA', 36500,
      tstzrange('2026-01-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'));

    v_end := endorse_policy(v_policy,
      tstzrange('2026-01-31 00:00:00+00', '2027-01-01 00:00:00+00', '[)'),
      'premium_adjustment', 6700, 'added a vehicle', '0018-suite');

    SELECT SUM(gross_share) INTO v_before FROM calculate_endorsement_waterfall(v_end);

    SELECT cancel_policy(v_policy, 'insured_initiated', 'CX_INSURED_REQUEST',
                         'pro_rata', '2026-04-01 00:00:00+00', NULL, '0018-suite')
      INTO v_cx;

    -- The stale range is the point: it must still read day 30 -> term end.
    SELECT effective_range INTO v_range FROM policy_endorsements WHERE endorsement_id = v_end;
    IF v_range IS DISTINCT FROM tstzrange('2026-01-31 00:00:00+00', '2027-01-01 00:00:00+00', '[)') THEN
      RAISE EXCEPTION '0018-T5 FAILED: the endorsement range was closed at cancellation (%). ADR 0018''s addendum decided it must not be - truncating it destroys the denominator the refund recompute needs.', v_range;
    END IF;

    -- ...and the refund is already right, because each amount is prorated over
    -- its own period.
    IF (SELECT return_premium FROM policy_cancellations WHERE cancellation_id = v_cx) IS DISTINCT FROM -33000.00 THEN
      RAISE EXCEPTION '0018-T5 FAILED: expected -33000.00 (27500 base + 5500 endorsement), got %',
        (SELECT return_premium FROM policy_cancellations WHERE cancellation_id = v_cx);
    END IF;

    -- calculate_endorsement_waterfall() is dated by the endorsement's own
    -- start, which a cancellation does not move.
    SELECT SUM(gross_share) INTO v_after FROM calculate_endorsement_waterfall(v_end);
    IF v_after IS DISTINCT FROM v_before THEN
      RAISE EXCEPTION '0018-T5 FAILED: the endorsement waterfall changed across a cancellation (% -> %)', v_before, v_after;
    END IF;

    -- The property that would have been lost: the refund stays arithmetically
    -- correct through a cancellation-date correction with the endorsement in
    -- force.
    SELECT correct_policy_cancellation(v_cx, '2026-03-01 00:00:00+00',
             'insured_initiated', 'CX_INSURED_REQUEST', 'pro_rata',
             'corrected', '0018-suite')
      INTO v_new;

    SELECT return_premium INTO v_return FROM policy_cancellations WHERE cancellation_id = v_new;
    IF v_return IS DISTINCT FROM -36720.00 THEN
      RAISE EXCEPTION '0018-T5 FAILED: expected -36720.00 (30600 base + 6120 endorsement) after correcting to 2026-03-01, got %', v_return;
    END IF;

    -- What the "obvious tidy-up" would have produced instead: the same 6,700
    -- re-prorated over the truncated 60-day range.
    v_counterfactual := -ROUND(
        36500 * 306::numeric / 365
      + 6700  *  31::numeric / 60
    , 2);
    IF v_return = v_counterfactual THEN
      RAISE EXCEPTION '0018-T5 FAILED: the corrected refund equals the truncated-endorsement figure (%), which means the endorsement range is being closed out somewhere', v_counterfactual;
    END IF;
    IF ROUND(v_return - v_counterfactual, 2) IS DISTINCT FROM -2658.33 THEN
      RAISE EXCEPTION '0018-T5 FAILED: the gap against the truncated-endorsement figure is %, expected -2658.33 (the addendum''s measured error)',
        ROUND(v_return - v_counterfactual, 2);
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0018-T5 pass: endorsement ranges stay intact at cancellation, and the refund survives a correction to the cent';
END $$;

-- ---------------------------------------------------------------------------
-- T6  ADR 0018 section 5: selecting short-rate with no factor loaded is REFUSED,
--     not approximated - the error names SHORT_RATE_TABLE_NOT_CONFIGURED and
--     nothing is written.
--
--     REVISED for ADR 0025: onboarding a state now AUTO-SEEDS a short-rate
--     factor (the trigger on state_rating_table_versions), so the original
--     "licensed state but short_rate_factors empty" combination this case used
--     is unreachable by design - a state with a rating table always has a
--     factor. The refusal is exercised two ways instead:
--       (A) short_rate_factor() called directly for a genuinely UNLICENSED
--           state (no rating table, hence no seeded factor); and
--       (B) cancel_policy()'s refuse-loudly-and-write-nothing transactionality,
--           by removing the auto-seeded row for a licensed state first so the
--           factor is genuinely absent.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_state CHAR(2) := 'TX'; v_unlicensed CHAR(2) := 'ZZ';
        v_ok BOOLEAN; v_err TEXT; v_status policy_status_t;
BEGIN
  BEGIN
    -- (A) A genuinely unlicensed state (no rating table, so the ADR 0025 seed
    -- never fired) has no factor, and the lookup refuses loudly.
    IF EXISTS (SELECT 1 FROM short_rate_factors WHERE state = v_unlicensed) THEN
      RAISE EXCEPTION '0018-T6 FAILED: % unexpectedly has a short-rate factor - this half needs a genuinely unlicensed state', v_unlicensed;
    END IF;
    v_ok := false;
    BEGIN
      PERFORM short_rate_factor(v_unlicensed, NULL, 'insured_initiated'::cancellation_type_t, 0.5, now());
    EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok OR v_err NOT LIKE '%SHORT_RATE_TABLE_NOT_CONFIGURED%' THEN
      RAISE EXCEPTION '0018-T6 FAILED: short_rate_factor() for an unlicensed state did not refuse with SHORT_RATE_TABLE_NOT_CONFIGURED (ok=%, err=%)', v_ok, v_err;
    END IF;

    -- (B) cancel_policy() still refuses and writes nothing when the factor is
    -- absent. Onboarding TX auto-seeds one (ADR 0025), so remove it first to
    -- recreate the "no factor for this state" condition.
    v_policy := pg_temp.mk_policy('T6', v_state, 36500,
      tstzrange('2026-01-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'));
    DELETE FROM short_rate_factors WHERE state = v_state;
    IF EXISTS (SELECT 1 FROM short_rate_factors WHERE state = v_state) THEN
      RAISE EXCEPTION '0018-T6 FAILED: could not clear the seeded factor for %', v_state;
    END IF;

    v_ok := false;
    BEGIN
      PERFORM cancel_policy(v_policy, 'insured_initiated', 'CX_INSURED_REQUEST',
                            'short_rate', '2026-04-01 00:00:00+00', NULL, '0018-suite');
    EXCEPTION WHEN OTHERS THEN
      v_ok := true; v_err := SQLERRM;
    END;

    IF NOT v_ok THEN
      RAISE EXCEPTION '0018-T6 FAILED: a short-rate cancellation succeeded with no factor loaded';
    END IF;
    IF v_err NOT LIKE '%SHORT_RATE_TABLE_NOT_CONFIGURED%' THEN
      RAISE EXCEPTION '0018-T6 FAILED: wrong error: %', v_err;
    END IF;

    -- Nothing partial survived the refusal.
    SELECT status INTO v_status FROM policies WHERE policy_id = v_policy;
    IF v_status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION '0018-T6 FAILED: the policy is % after a refused cancellation, expected active', v_status;
    END IF;
    IF (SELECT effective_range FROM policies WHERE policy_id = v_policy)
       IS DISTINCT FROM tstzrange('2026-01-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)') THEN
      RAISE EXCEPTION '0018-T6 FAILED: the policy term was truncated by a cancellation that failed';
    END IF;
    IF EXISTS (SELECT 1 FROM policy_cancellations WHERE policy_id = v_policy) THEN
      RAISE EXCEPTION '0018-T6 FAILED: a refused cancellation still wrote a cancellation row';
    END IF;
    IF (SELECT upper(effective_range) FROM policy_vehicles WHERE policy_id = v_policy)
       IS DISTINCT FROM '2027-01-01 00:00:00+00'::timestamptz THEN
      RAISE EXCEPTION '0018-T6 FAILED: a refused cancellation still closed the vehicle snapshot';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0018-T6 pass: short-rate with no loaded factor is refused loudly (direct lookup on an unlicensed state, and cancel_policy after clearing the seed), and writes nothing';
END $$;

-- ---------------------------------------------------------------------------
-- T7  ADR 0018 section 7: the original three-argument cancel_policy() stays
--     callable and refuses. It is not silently forwarded to the new one under
--     assumed arguments - recording a guess about who initiated a cancellation
--     is worse than an error, because it looks like a fact.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    v_policy := pg_temp.mk_policy('T7', 'FL', 36500,
      tstzrange('2026-01-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'));

    BEGIN
      PERFORM cancel_policy(v_policy, '0018-suite', 'cancelling the old way');
    EXCEPTION WHEN OTHERS THEN
      v_ok := true; v_err := SQLERRM;
    END;

    IF NOT v_ok THEN
      RAISE EXCEPTION '0018-T7 FAILED: the three-argument cancel_policy() cancelled a policy without an initiator';
    END IF;
    IF v_err NOT LIKE '%CANCELLATION_TYPE_REQUIRED%' THEN
      RAISE EXCEPTION '0018-T7 FAILED: wrong error: %', v_err;
    END IF;
    IF (SELECT status FROM policies WHERE policy_id = v_policy) IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION '0018-T7 FAILED: the refusing overload still changed the policy status';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0018-T7 pass: the ADR 0012 signature refuses rather than guessing an initiator';
END $$;

-- ---------------------------------------------------------------------------
-- T8  A cancellation date outside the term is refused. A date outside the term
--     is either a typo or a different event (expiry, nonrenewal - ADR 0019),
--     and this function deliberately handles neither.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    v_policy := pg_temp.mk_policy('T8', 'CO', 36500,
      tstzrange('2026-01-01 00:00:00+00', '2027-01-01 00:00:00+00', '[)'));

    BEGIN
      PERFORM cancel_policy(v_policy, 'company_initiated', 'CX_NONPAYMENT',
                            'pro_rata', '2027-06-01 00:00:00+00', NULL, '0018-suite');
    EXCEPTION WHEN OTHERS THEN
      v_ok := true; v_err := SQLERRM;
    END;

    IF NOT v_ok THEN
      RAISE EXCEPTION '0018-T8 FAILED: a cancellation dated after the term end was accepted';
    END IF;
    IF v_err NOT LIKE '%CANCELLATION_DATE_OUTSIDE_TERM%' THEN
      RAISE EXCEPTION '0018-T8 FAILED: wrong error: %', v_err;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0018-T8 pass: a cancellation date outside the term is refused';
END $$;

ROLLBACK;

\echo '0018: 8/8 cases passed (nothing committed)'
