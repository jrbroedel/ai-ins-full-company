-- Behavioural tests for ADR 0039: broker/MGA acquisition commission wired into
-- the premium waterfall.
--
-- The ADR 0007 waterfall, now end to end: gross - broker - MGA = net to the
-- capacity panel -> split among participants. calculate_commission_waterfall()
-- is the acquisition breakdown (top); calculate_premium_waterfall() now cedes the
-- panel NET of acquisition. Because mga = 30 - broker (generated column), broker +
-- mga = 30 always, so net-to-panel = gross * 0.70 for every quote, invariant to
-- the split - the split only moves dollars between broker and MGA, never changes
-- what the panel receives.
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, IS DISTINCT FROM on nullable reads, RAISE
-- on any failed assertion.

\set ON_ERROR_STOP on
BEGIN;
-- ADR 0035: this suite writes state_rating_table_versions rows directly as fixtures;
-- the onboard_state() guard permits that through the escape flag, set for this
-- rolled-back test transaction (tests use the hatch; production goes through onboard_state).
SET LOCAL luxauto.onboarding_state = 'on';

-- Shared infra: a rating record and a program with a chosen panel. Returns both
-- ids so a case can hang quotes off them.
CREATE FUNCTION pg_temp.mk_infra(p_tag TEXT, p_single BOOLEAN, OUT o_rating UUID, OUT o_program UUID) AS $fx$
DECLARE v_term TSTZRANGE := tstzrange(now() - interval '1 year', now() + interval '1 year', '[)');
BEGIN
  INSERT INTO state_rating_table_versions
    (state, regulator_name, filing_status, line_of_business_code, serff_filing_tracking_number, effective_range)
  VALUES ('WF', 'WF DOI', 'file_and_use', 'PPA-LUX', 'SERFF-0039-' || p_tag,
          tstzrange('2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00', '[)'))
  RETURNING record_id INTO o_rating;

  INSERT INTO insurance_programs (program_name, capacity_provider_name, effective_range)
  VALUES ('0039 program ' || p_tag, 'Fronting Co', v_term) RETURNING program_id INTO o_program;

  IF p_single THEN
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, commission_rate, effective_range)
    VALUES (o_program, 'capacity_provider', 'Solo Capacity', 100, 0, v_term);
  ELSE
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, commission_rate, effective_range)
    VALUES (o_program, 'capacity_provider', 'Fronting Co', 60, 10, v_term),
           (o_program, 'reinsurer',         'Re Two',      40,  0, v_term);
  END IF;
  SET CONSTRAINTS ALL IMMEDIATE;  -- the share-sum trigger is deferred; force it now (suite never commits)
END;
$fx$ LANGUAGE plpgsql;

-- A bound quote with a chosen gross premium and broker rate.
CREATE FUNCTION pg_temp.mk_quote(p_rating UUID, p_program UUID, p_premium NUMERIC, p_broker NUMERIC) RETURNS UUID AS $fx$
DECLARE v_applicant UUID; v_app UUID; v_quote UUID;
BEGIN
  INSERT INTO applicants (first_name, last_name) VALUES ('Test', '0039') RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state) VALUES (v_applicant, 'submitted', 'WF') RETURNING application_id INTO v_app;
  INSERT INTO quotes
    (application_id, state_rating_table_record_id, program_id, premium_amount, rating_basis, status,
     broker_channel, broker_commission_rate, quoted_by)
  VALUES (v_app, p_rating, p_program, p_premium, '{}'::jsonb, 'bound', 'retail', p_broker, '0039-fixture')
  RETURNING quote_id INTO v_quote;
  RETURN v_quote;
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  Acquisition breakdown across broker rates incl. the 0% and 15% boundaries,
--     the net-to-panel = gross * 0.70 invariant, and the full reconciliation
--     broker$ + mga$ + net = gross. Exactly one row per quote.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_rating UUID; v_program UUID; v_q UUID; r RECORD; v_n INT;
BEGIN
  BEGIN
    SELECT o_rating, o_program FROM pg_temp.mk_infra('T1', true) INTO v_rating, v_program;

    -- (a) broker 10 on 100000: broker 10000, mga 20000 (30-10), net 70000.
    v_q := pg_temp.mk_quote(v_rating, v_program, 100000, 10);
    SELECT count(*) INTO v_n FROM calculate_commission_waterfall(v_q);
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0039-T1 FAILED: expected exactly 1 commission-waterfall row per quote, got %', v_n;
    END IF;
    SELECT * INTO r FROM calculate_commission_waterfall(v_q);
    IF (r.gross_premium, r.broker_commission_rate, r.broker_commission_amount,
        r.mga_commission_rate, r.mga_commission_amount, r.net_premium_to_panel)
       IS DISTINCT FROM (100000.00, 10.00, 10000.00, 20.00, 20000.00, 70000.00) THEN
      RAISE EXCEPTION '0039-T1 FAILED: broker 10/100000 breakdown is %/%/%/%/%/%, expected 100000/10/10000/20/20000/70000',
        r.gross_premium, r.broker_commission_rate, r.broker_commission_amount, r.mga_commission_rate, r.mga_commission_amount, r.net_premium_to_panel;
    END IF;
    IF r.broker_commission_amount + r.mga_commission_amount + r.net_premium_to_panel IS DISTINCT FROM r.gross_premium THEN
      RAISE EXCEPTION '0039-T1 FAILED: broker + mga + net (% + % + %) does not reconstruct gross %',
        r.broker_commission_amount, r.mga_commission_amount, r.net_premium_to_panel, r.gross_premium;
    END IF;

    -- (b) broker 0 (boundary): mga fills the whole 30. broker 0, mga 30000, net 70000.
    v_q := pg_temp.mk_quote(v_rating, v_program, 100000, 0);
    SELECT * INTO r FROM calculate_commission_waterfall(v_q);
    IF (r.broker_commission_rate, r.broker_commission_amount, r.mga_commission_rate, r.mga_commission_amount, r.net_premium_to_panel)
       IS DISTINCT FROM (0.00, 0.00, 30.00, 30000.00, 70000.00) THEN
      RAISE EXCEPTION '0039-T1 FAILED: broker 0/100000 breakdown is %/%/%/%/%, expected 0/0/30/30000/70000',
        r.broker_commission_rate, r.broker_commission_amount, r.mga_commission_rate, r.mga_commission_amount, r.net_premium_to_panel;
    END IF;

    -- (c) broker 15 (ceiling boundary): broker 15000, mga 15000, net 70000 - net is
    --     the SAME as (a) and (b), the invariant.
    v_q := pg_temp.mk_quote(v_rating, v_program, 100000, 15);
    SELECT * INTO r FROM calculate_commission_waterfall(v_q);
    IF (r.broker_commission_rate, r.broker_commission_amount, r.mga_commission_rate, r.mga_commission_amount, r.net_premium_to_panel)
       IS DISTINCT FROM (15.00, 15000.00, 15.00, 15000.00, 70000.00) THEN
      RAISE EXCEPTION '0039-T1 FAILED: broker 15/100000 breakdown is %/%/%/%/%, expected 15/15000/15/15000/70000',
        r.broker_commission_rate, r.broker_commission_amount, r.mga_commission_rate, r.mga_commission_amount, r.net_premium_to_panel;
    END IF;

    -- (d) real-data premium 36500 (the 0018 figure) at broker 10: broker 3650, mga
    --     7300, net 25550 - confirms it holds off a round number and reconciles.
    v_q := pg_temp.mk_quote(v_rating, v_program, 36500, 10);
    SELECT * INTO r FROM calculate_commission_waterfall(v_q);
    IF (r.broker_commission_amount, r.mga_commission_amount, r.net_premium_to_panel)
       IS DISTINCT FROM (3650.00, 7300.00, 25550.00) THEN
      RAISE EXCEPTION '0039-T1 FAILED: broker 10/36500 breakdown is %/%/%, expected 3650/7300/25550',
        r.broker_commission_amount, r.mga_commission_amount, r.net_premium_to_panel;
    END IF;
    IF r.broker_commission_amount + r.mga_commission_amount + r.net_premium_to_panel IS DISTINCT FROM 36500.00 THEN
      RAISE EXCEPTION '0039-T1 FAILED: 36500 breakdown does not reconcile to gross';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0039-T1 pass: acquisition breakdown correct across broker 0/10/15, net-to-panel = gross * 0.70 invariant, and broker + mga + net reconciles to gross (incl. the real 36500 figure)';
END $$;

-- ---------------------------------------------------------------------------
-- T2  The panel now cedes NET of acquisition: calculate_premium_waterfall(quote)
--     distributes gross * 0.70, not gross. Full-waterfall reconciliation across
--     the acquisition layer and the panel.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_rating UUID; v_program UUID; v_q UUID; v_net NUMERIC; v_panel_sum NUMERIC;
        v_fronting NUMERIC; r RECORD;
BEGIN
  BEGIN
    SELECT o_rating, o_program FROM pg_temp.mk_infra('T2', false) INTO v_rating, v_program;  -- 60/40 panel
    v_q := pg_temp.mk_quote(v_rating, v_program, 100000, 10);

    -- Panel shares sum to net-of-acquisition (70000), not gross (100000).
    SELECT SUM(gross_share) INTO v_panel_sum FROM calculate_premium_waterfall(v_q);
    IF v_panel_sum IS DISTINCT FROM 70000.00 THEN
      RAISE EXCEPTION '0039-T2 FAILED: panel gross_share sums to %, expected the net-of-acquisition 70000.00', v_panel_sum;
    END IF;

    -- Fronting Co (60%) gets 60% of the NET: 42000, not 60% of gross (60000).
    SELECT gross_share INTO v_fronting FROM calculate_premium_waterfall(v_q) WHERE participant_name = 'Fronting Co';
    IF v_fronting IS DISTINCT FROM 42000.00 THEN
      RAISE EXCEPTION '0039-T2 FAILED: the 60%% participant gets %, expected 42000.00 (60%% of the net 70000)', v_fronting;
    END IF;

    -- Full-waterfall reconciliation: broker$ + mga$ + panel gross_share = gross.
    SELECT net_premium_to_panel, broker_commission_amount, mga_commission_amount INTO r
    FROM calculate_commission_waterfall(v_q);
    IF r.broker_commission_amount + r.mga_commission_amount + v_panel_sum IS DISTINCT FROM 100000.00 THEN
      RAISE EXCEPTION '0039-T2 FAILED: full waterfall (broker % + mga % + panel %) does not reconcile to gross 100000',
        r.broker_commission_amount, r.mga_commission_amount, v_panel_sum;
    END IF;
    -- And the panel base equals the acquisition layer's net_premium_to_panel.
    IF v_panel_sum IS DISTINCT FROM r.net_premium_to_panel THEN
      RAISE EXCEPTION '0039-T2 FAILED: panel sum % != commission-waterfall net_premium_to_panel %', v_panel_sum, r.net_premium_to_panel;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0039-T2 pass: calculate_premium_waterfall cedes NET of acquisition (panel sums to 70000 not 100000, 60%% share = 42000), and broker + mga + panel reconciles to gross';
END $$;

-- ---------------------------------------------------------------------------
-- T3  luxauto_premium_waterfall_view exposes the appended acquisition columns,
--     and its panel figures are net-based - one place to read the full waterfall.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_rating UUID; v_program UUID; v_q UUID; r RECORD; v_panel_sum NUMERIC;
BEGIN
  BEGIN
    SELECT o_rating, o_program FROM pg_temp.mk_infra('T3', false) INTO v_rating, v_program;  -- 60/40
    v_q := pg_temp.mk_quote(v_rating, v_program, 100000, 10);

    -- Acquisition columns are repeated on every participant row (per-quote layer).
    SELECT DISTINCT broker_channel, broker_commission_amount, mga_commission_amount, net_premium_to_panel
      INTO r
    FROM luxauto_premium_waterfall_view WHERE quote_id = v_q;
    IF (r.broker_channel, r.broker_commission_amount, r.mga_commission_amount, r.net_premium_to_panel)
       IS DISTINCT FROM ('retail'::broker_channel_t, 10000.00, 20000.00, 70000.00) THEN
      RAISE EXCEPTION '0039-T3 FAILED: view acquisition columns are %/%/%/%, expected retail/10000/20000/70000',
        r.broker_channel, r.broker_commission_amount, r.mga_commission_amount, r.net_premium_to_panel;
    END IF;

    -- The view's panel gross_share is net-based: sums to 70000.
    SELECT SUM(gross_share) INTO v_panel_sum FROM luxauto_premium_waterfall_view WHERE quote_id = v_q;
    IF v_panel_sum IS DISTINCT FROM 70000.00 THEN
      RAISE EXCEPTION '0039-T3 FAILED: view panel gross_share sums to %, expected net-of-acquisition 70000.00', v_panel_sum;
    END IF;
    -- gross_premium column still shows the gross (unchanged).
    IF (SELECT DISTINCT premium_amount FROM luxauto_premium_waterfall_view WHERE quote_id = v_q) IS DISTINCT FROM 100000.00 THEN
      RAISE EXCEPTION '0039-T3 FAILED: the view no longer shows gross premium_amount 100000.00';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0039-T3 pass: luxauto_premium_waterfall_view exposes the acquisition columns and its panel figures are net-based, with gross premium_amount still shown';
END $$;

ROLLBACK;

\echo '0039: 3/3 cases passed (nothing committed)'
