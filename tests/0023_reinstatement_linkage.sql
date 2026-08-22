-- Behavioural tests for ADR 0023: the ">14-day" reinstatement path.
-- See docs/decisions/0023-reinstatement-linkage.md.
--
-- ADR 0023 links a freshly-bound policy back to the cancelled policy it
-- succeeds, as ordinary new business, via link_reinstated_policy() called
-- AFTER a normal bind_policy(). The whole design bet is that the common bind
-- path is untouched, so T5 is the regression that proves it: a bind with no
-- reinstatement behaves exactly as before.
--
-- Same structure as the 0017/0018/0021 suites: one transaction rolled back at
-- the end, one self-unwinding DO block per case, SET CONSTRAINTS ALL IMMEDIATE
-- instead of committing, RAISE on any assertion that does not hold, IS DISTINCT
-- FROM for the comparisons, and cases asserting a rejection assert on the error
-- MESSAGE rather than merely that something failed.
--
-- Unlike the 0018 suite, the fixture binds through bind_policy() rather than
-- INSERTing a policies row directly - because exercising the real common path
-- is the point here, not asserting exact refund arithmetic (which 0018 owns).
-- bind_policy() dates the term from now(); every cancellation below is taken at
-- now() + a small interval so it lands inside that term without the fixture
-- needing to pin one.

\set ON_ERROR_STOP on
BEGIN;
-- ADR 0035: this suite writes state_rating_table_versions rows directly as fixtures;
-- the onboard_state() guard permits that through the escape flag, set for this
-- rolled-back test transaction (tests use the hatch; production goes through onboard_state).
SET LOCAL luxauto.onboarding_state = 'on';

-- ---------------------------------------------------------------------------
-- Fixture. A full applicant -> application -> vehicle(+vin) -> driver(+name,dob)
-- -> program -> panel -> issued quote chain, then bind_policy() itself, so the
-- returned policy is one the ordinary flow produced. One state per tag keeps
-- the state_rating_table_versions exclusion constraint from colliding across
-- cases. Everything is in pg_temp and the suite never commits.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.mk_bound_policy(
  p_tag TEXT,
  p_state CHAR(2)
) RETURNS UUID AS $fx$
DECLARE
  v_rating UUID; v_applicant UUID; v_app UUID; v_program UUID;
  v_quote UUID; v_policy UUID; v_program_term TSTZRANGE;
BEGIN
  -- Wide, now()-centred program term: bind_policy() terms start at now(), and
  -- the panel must be in force across that whole term.
  v_program_term := tstzrange(now() - interval '1 year', now() + interval '2 years', '[)');

  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code,
     serff_filing_tracking_number, effective_range)
  VALUES (p_state, p_state || ' DOI', 'file_and_use', 'PPA-LUX',
          'SERFF-0023-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO v_rating;

  INSERT INTO applicants (first_name, last_name)
  VALUES ('Test', '0023-' || p_tag)
  RETURNING applicant_id INTO v_applicant;

  INSERT INTO applications (applicant_id, status, garaging_state)
  VALUES (v_applicant, 'quoted', p_state)
  RETURNING application_id INTO v_app;

  -- vin present and driver identity present: bind_policy() blocks on either
  -- being null (ADR 0016 addendum), and this fixture is meant to reach bind.
  INSERT INTO vehicles (application_id, year, make, model, vin, vehicle_category, garaging_state)
  VALUES (v_app, 2024, 'Aston Martin', 'DB12', 'VIN0023' || p_tag, 'exotic', p_state);

  INSERT INTO additional_drivers (application_id, name, date_of_birth)
  VALUES (v_app, 'Driver ' || p_tag, DATE '1980-01-01');

  INSERT INTO insurance_programs (program_name, capacity_provider_name, effective_range)
  VALUES ('0023-' || p_tag, 'Fronting Co', v_program_term)
  RETURNING program_id INTO v_program;

  INSERT INTO program_participants
    (program_id, participant_type, participant_name, share_percentage, commission_rate, effective_range)
  VALUES (v_program, 'capacity_provider', 'Fronting Co', 60, 10, v_program_term),
         (v_program, 'reinsurer',         'Re Two',      40,  0, v_program_term);

  INSERT INTO quotes
    (application_id, state_rating_table_record_id, program_id, premium_amount, rating_basis, status,
     broker_channel, broker_commission_rate, quoted_by)
  VALUES (v_app, v_rating, v_program, 36500, '{}'::jsonb, 'issued',
          'retail', 10, '0023-fixture')
  RETURNING quote_id INTO v_quote;

  -- The real common path under test.
  v_policy := bind_policy(v_quote, 'POL-0023-' || p_tag, '0023-suite');

  SET CONSTRAINTS ALL IMMEDIATE;
  RETURN v_policy;
END;
$fx$ LANGUAGE plpgsql;

-- Cancels a fixture policy so it is a valid reinstatement target. pro_rata at
-- now() + 1 day, safely inside bind_policy()'s [now(), now()+1yr) term.
CREATE FUNCTION pg_temp.cancel_it(p_policy UUID) RETURNS VOID AS $fx$
BEGIN
  PERFORM cancel_policy(p_policy, 'insured_initiated', 'CX_INSURED_REQUEST',
                        'pro_rata', now() + interval '1 day', 'fixture cancel',
                        '0023-suite');
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  Happy path. A cancelled prior policy, a freshly-bound new policy, linked.
--     Asserts the column is set on the new policy, and that BOTH policies carry
--     a 'reinstatement_linked' event so the relationship reads from either side.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_prior UUID; v_new UUID; v_link UUID; v_n_new INT; v_n_prior INT;
BEGIN
  BEGIN
    v_prior := pg_temp.mk_bound_policy('T1P', 'CA');
    PERFORM pg_temp.cancel_it(v_prior);
    v_new := pg_temp.mk_bound_policy('T1N', 'NV');

    PERFORM link_reinstated_policy(v_new, v_prior, '0023-suite');

    SELECT reinstated_from_policy_id INTO v_link FROM policies WHERE policy_id = v_new;
    IF v_link IS DISTINCT FROM v_prior THEN
      RAISE EXCEPTION '0023-T1 FAILED: new policy reinstated_from is %, expected %', v_link, v_prior;
    END IF;

    -- The prior policy is not itself mutated to point anywhere.
    IF (SELECT reinstated_from_policy_id FROM policies WHERE policy_id = v_prior) IS NOT NULL THEN
      RAISE EXCEPTION '0023-T1 FAILED: the prior (cancelled) policy should not carry a reinstated_from link';
    END IF;

    -- One event on each side, both 'reinstatement_linked'.
    SELECT count(*) INTO v_n_new   FROM policy_events
      WHERE policy_id = v_new   AND event_type = 'reinstatement_linked';
    SELECT count(*) INTO v_n_prior FROM policy_events
      WHERE policy_id = v_prior AND event_type = 'reinstatement_linked';
    IF v_n_new <> 1 OR v_n_prior <> 1 THEN
      RAISE EXCEPTION '0023-T1 FAILED: expected one reinstatement_linked event on each policy, got new=% prior=%',
        v_n_new, v_n_prior;
    END IF;

    -- The read-side view exposes the predecessor.
    IF (SELECT reinstated_from_policy_id FROM luxauto_policy_view WHERE policy_id = v_new)
       IS DISTINCT FROM v_prior THEN
      RAISE EXCEPTION '0023-T1 FAILED: luxauto_policy_view does not expose the reinstated_from link';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0023-T1 pass: a >14-day reinstatement links the new policy to the prior cancelled one, visible from both sides and the view';
END $$;

-- ---------------------------------------------------------------------------
-- T2  The prior policy is still active, not cancelled. Only a cancelled policy
--     is a reinstatement target; linking to an active one is rejected.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_prior UUID; v_new UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  v_prior := pg_temp.mk_bound_policy('T2P', 'CO');   -- left ACTIVE, not cancelled
  v_new   := pg_temp.mk_bound_policy('T2N', 'AZ');
  BEGIN
    PERFORM link_reinstated_policy(v_new, v_prior, '0023-suite');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0023-T2 FAILED: linking to an ACTIVE prior policy was accepted';
  END IF;
  IF v_err NOT LIKE '%REINSTATEMENT_PRIOR_NOT_CANCELLED%' THEN
    RAISE EXCEPTION '0023-T2 FAILED: wrong error: %', v_err;
  END IF;
  -- And nothing was written on the new policy despite the rejection.
  IF (SELECT reinstated_from_policy_id FROM policies WHERE policy_id = v_new) IS NOT NULL THEN
    RAISE EXCEPTION '0023-T2 FAILED: a rejected link still set the column';
  END IF;
  RAISE NOTICE '0023-T2 pass: linking to a non-cancelled prior policy is refused';
END $$;

-- ---------------------------------------------------------------------------
-- T3  The link is set-once. A second call on a policy that already has one is
--     rejected rather than silently overwriting.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_prior1 UUID; v_prior2 UUID; v_new UUID; v_ok BOOLEAN := false; v_err TEXT; v_link UUID;
BEGIN
  v_prior1 := pg_temp.mk_bound_policy('T3A', 'OR'); PERFORM pg_temp.cancel_it(v_prior1);
  v_prior2 := pg_temp.mk_bound_policy('T3B', 'WA'); PERFORM pg_temp.cancel_it(v_prior2);
  v_new    := pg_temp.mk_bound_policy('T3N', 'ID');

  PERFORM link_reinstated_policy(v_new, v_prior1, '0023-suite');   -- first link OK
  BEGIN
    PERFORM link_reinstated_policy(v_new, v_prior2, '0023-suite'); -- second must fail
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0023-T3 FAILED: a second link overwrote the first';
  END IF;
  IF v_err NOT LIKE '%REINSTATEMENT_ALREADY_LINKED%' THEN
    RAISE EXCEPTION '0023-T3 FAILED: wrong error: %', v_err;
  END IF;
  -- The original link is intact - the second call changed nothing.
  SELECT reinstated_from_policy_id INTO v_link FROM policies WHERE policy_id = v_new;
  IF v_link IS DISTINCT FROM v_prior1 THEN
    RAISE EXCEPTION '0023-T3 FAILED: the original link was disturbed, now %, expected %', v_link, v_prior1;
  END IF;
  RAISE NOTICE '0023-T3 pass: the reinstated_from link is set-once; a second attempt is refused and the first survives';
END $$;

-- ---------------------------------------------------------------------------
-- T4  Self-reference is impossible two ways: the function's own guard, and the
--     policies_no_self_reinstatement CHECK for anything bypassing the function
--     with a raw UPDATE.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  v_policy := pg_temp.mk_bound_policy('T4', 'TX');

  -- (a) the function guard
  BEGIN
    PERFORM link_reinstated_policy(v_policy, v_policy, '0023-suite');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0023-T4 FAILED: link_reinstated_policy allowed a self-reference';
  END IF;
  IF v_err NOT LIKE '%REINSTATEMENT_SELF_REFERENCE%' THEN
    RAISE EXCEPTION '0023-T4 FAILED: wrong error from the function guard: %', v_err;
  END IF;

  -- (b) the CHECK constraint, reached by a raw UPDATE that skips the function
  v_ok := false; v_err := NULL;
  BEGIN
    UPDATE policies SET reinstated_from_policy_id = policy_id WHERE policy_id = v_policy;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0023-T4 FAILED: a raw self-reference UPDATE was not rejected by the CHECK constraint';
  END IF;
  IF v_err NOT LIKE '%policies_no_self_reinstatement%' THEN
    RAISE EXCEPTION '0023-T4 FAILED: wrong error from the CHECK constraint: %', v_err;
  END IF;

  RAISE NOTICE '0023-T4 pass: self-reference is blocked by both the function guard and the CHECK constraint';
END $$;

-- ---------------------------------------------------------------------------
-- T5  REGRESSION - the decision that mattered: the common bind path is
--     untouched. An ordinary bind_policy() with no reinstatement produces a
--     policy whose reinstated_from is null, with no reinstatement_linked event
--     and its usual single 'bound' event. If a future change ever routes normal
--     binds through reinstatement machinery, this fails.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_policy UUID; v_link UUID; v_n_link INT; v_n_bound INT;
BEGIN
  BEGIN
    v_policy := pg_temp.mk_bound_policy('T5', 'FL');

    SELECT reinstated_from_policy_id INTO v_link FROM policies WHERE policy_id = v_policy;
    IF v_link IS NOT NULL THEN
      RAISE EXCEPTION '0023-T5 FAILED: an ordinary bind set reinstated_from to %, expected null', v_link;
    END IF;

    SELECT count(*) INTO v_n_link FROM policy_events
      WHERE policy_id = v_policy AND event_type = 'reinstatement_linked';
    IF v_n_link <> 0 THEN
      RAISE EXCEPTION '0023-T5 FAILED: an ordinary bind wrote % reinstatement_linked event(s), expected 0', v_n_link;
    END IF;

    -- The pre-existing behaviour: exactly one 'bound' event, unchanged.
    SELECT count(*) INTO v_n_bound FROM policy_events
      WHERE policy_id = v_policy AND event_type = 'bound';
    IF v_n_bound <> 1 THEN
      RAISE EXCEPTION '0023-T5 FAILED: expected exactly one bound event on a normal bind, got %', v_n_bound;
    END IF;

    -- The view returns the row with a null predecessor, not a filtered-out row.
    IF (SELECT reinstated_from_policy_id FROM luxauto_policy_view WHERE policy_id = v_policy) IS NOT NULL THEN
      RAISE EXCEPTION '0023-T5 FAILED: luxauto_policy_view shows a predecessor for a non-reinstatement policy';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0023-T5 pass: an ordinary bind_policy() is completely unaffected - null link, no reinstatement event, unchanged bound event';
END $$;

ROLLBACK;
