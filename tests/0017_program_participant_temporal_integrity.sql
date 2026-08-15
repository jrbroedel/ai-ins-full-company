-- Behavioural tests for ADR 0017: temporal integrity for program_participants.
-- See docs/decisions/0017-program-participant-temporal-integrity.md.
--
-- Backfilled by ADR 0022 from ADR 0017's own text and the session that built
-- it. Every case here corresponds to something that ADR argued or demonstrated.
--
-- Structure (ADR 0022 section 2):
--   * the whole file is one transaction, rolled back at the end - nothing is
--     ever committed, because this runs against luxauto-pg itself;
--   * each case is a DO block that ends by unwinding its own subtransaction,
--     so cases cannot contaminate each other's panels;
--   * the share-sum trigger is DEFERRABLE INITIALLY DEFERRED, so cases force
--     it with SET CONSTRAINTS ALL IMMEDIATE instead of committing;
--   * a case that does not hold RAISEs, and psql runs with ON_ERROR_STOP=1.

\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- T1  A panel totalling 100% at every instant is accepted.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-000000000001';
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T1','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;

    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0017-T1 FAILED: a sound 60/40 panel reported a share gap';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0017-T1 pass: sound panel accepted';
END $$;

-- ---------------------------------------------------------------------------
-- T2  A legitimate supersession is accepted. ADR 0017 finding 1: the old
--     non-temporal check summed every row regardless of date, so closing a
--     reinsurer's row and inserting its replacement summed 60+40+40=140 and
--     was REJECTED - it blocked correct data, which is why no panel change
--     had ever been possible.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-000000000002';
        v_old UUID; v_new UUID; v_rows INT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T2','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_old;

    v_new := correct_program_participant(
      v_old, tstzrange('2026-07-01','2027-01-01','[)'),
      'reinsurer','Re Two',40,NULL,NULL);
    SET CONSTRAINTS ALL IMMEDIATE;

    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0017-T2 FAILED: a legitimate supersession left a share gap';
    END IF;
    SELECT count(*) INTO v_rows FROM program_participants WHERE program_id = p;
    IF v_rows <> 3 THEN
      RAISE EXCEPTION '0017-T2 FAILED: expected 3 rows after supersession (append-only), got %', v_rows;
    END IF;
    IF (SELECT upper(effective_range) FROM program_participants WHERE participant_id = v_old)
       IS DISTINCT FROM '2026-07-01'::timestamptz THEN
      RAISE EXCEPTION '0017-T2 FAILED: the superseded row was not closed at the successor start';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0017-T2 pass: supersession accepted, old row closed, nothing mutated in place';
END $$;

-- ---------------------------------------------------------------------------
-- T3  Two concurrent rows for the same (program, name, role) are rejected.
--     ADR 0017 finding 2: these used to be accepted, and
--     calculate_premium_waterfall then paid that participant twice.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-000000000003';
        v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T3','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',40,tstzrange('2026-03-01','2026-09-01','[)'));
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0017-T3 FAILED: a duplicate (program, name, role) overlap was accepted';
  END IF;
  IF v_err NOT LIKE '%no_overlapping_program_participants%' THEN
    RAISE EXCEPTION '0017-T3 FAILED: expected the exclusion constraint, got: %', v_err;
  END IF;
  RAISE NOTICE '0017-T3 pass: duplicate identity rejected by the exclusion constraint';
END $$;

-- ---------------------------------------------------------------------------
-- T4  A panel with a hole is rejected. ADR 0017 finding 3: a panel ending
--     mid-term used to pass, and a quote written during the hole allocated
--     nothing to anybody, silently.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-000000000004';
        v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T4','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',100,tstzrange('2026-01-01','2026-06-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0017-T4 FAILED: a panel ending mid-term was accepted';
  END IF;
  IF v_err NOT LIKE '%PROGRAM_SHARES_NOT_100_AT_INSTANT%' THEN
    RAISE EXCEPTION '0017-T4 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0017-T4 pass: mid-term hole rejected';
END $$;

-- ---------------------------------------------------------------------------
-- T5  Participation outside the program term is rejected. This is what makes
--     "100% at every instant of the term" well defined from both ends.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-000000000005';
        v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T5','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',100,tstzrange('2026-01-01','2027-01-01','[)')),
           (p,'mga_retention','LuxAuto MGA',10,tstzrange('2025-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0017-T5 FAILED: participation outside the program term was accepted';
  END IF;
  IF v_err NOT LIKE '%PROGRAM_PARTICIPANT_OUTSIDE_TERM%' THEN
    RAISE EXCEPTION '0017-T5 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0017-T5 pass: participation outside the term rejected';
END $$;

-- ---------------------------------------------------------------------------
-- T6  The zero-participant escape survives, in temporal form: a program whose
--     panel has not been negotiated yet must remain insertable. Only
--     risk-bearing roles count, so an mga_retention row alone does not
--     trigger the rule.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-000000000006';
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T6','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'mga_retention','LuxAuto MGA',10,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;

    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0017-T6 FAILED: a program with no risk-bearing panel was checked anyway';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0017-T6 pass: bootstrapping escape intact';
END $$;

-- ---------------------------------------------------------------------------
-- T7  The probe set includes the program term's own lower bound. Without it a
--     panel starting a month after the program would never be probed during
--     the uncovered month and the hole would pass.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-000000000007';
        v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T7','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',100,tstzrange('2026-06-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0017-T7 FAILED: a panel starting late was accepted - the term lower bound is not being probed';
  END IF;
  IF v_err NOT LIKE '%PROGRAM_SHARES_NOT_100_AT_INSTANT%' THEN
    RAISE EXCEPTION '0017-T7 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0017-T7 pass: late-starting panel caught by the term-lower-bound probe';
END $$;

-- ---------------------------------------------------------------------------
-- T8  program_participants is append-only: a bare UPDATE is rejected.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-000000000008';
        v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T8','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',100,tstzrange('2026-01-01','2027-01-01','[)'));
    UPDATE program_participants SET share_percentage = 90 WHERE program_id = p;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION '0017-T8 FAILED: a bare UPDATE was accepted'; END IF;
  IF v_err NOT LIKE '%append-only%' THEN
    RAISE EXCEPTION '0017-T8 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0017-T8 pass: bare UPDATE rejected';
END $$;

-- ---------------------------------------------------------------------------
-- T9  ... and so is DELETE.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-000000000009';
        v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T9','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',100,tstzrange('2026-01-01','2027-01-01','[)'));
    DELETE FROM program_participants WHERE program_id = p;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION '0017-T9 FAILED: a DELETE was accepted'; END IF;
  IF v_err NOT LIKE '%append-only%' THEN
    RAISE EXCEPTION '0017-T9 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0017-T9 pass: DELETE rejected';
END $$;

-- ---------------------------------------------------------------------------
-- T10 The supersession escape hatch is NARROW. ADR 0017 section 4: the flag
--     permits closing a row's upper bound and nothing else, which is stricter
--     than the DISABLE TRIGGER the policy-side tables use. A share change made
--     while the flag is on must still be rejected.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-00000000000a';
        v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T10','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',100,tstzrange('2026-01-01','2027-01-01','[)'));
    PERFORM set_config('luxauto.superseding_participant','on',true);
    UPDATE program_participants SET share_percentage = 90 WHERE program_id = p;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  PERFORM set_config('luxauto.superseding_participant','off',true);
  IF NOT v_ok THEN
    RAISE EXCEPTION '0017-T10 FAILED: the flag permitted a share change - the escape hatch is too wide';
  END IF;
  IF v_err NOT LIKE '%append-only%' THEN
    RAISE EXCEPTION '0017-T10 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0017-T10 pass: flag permits only the closing update';
END $$;

-- ---------------------------------------------------------------------------
-- T11 ADR 0017 addendum / ADR 0016 addendum 3: correcting a row to a start at
--     or before its own empties it rather than asking for an inverted range.
--     An empty range contains no instant, so it contributes nothing to any
--     probe and satisfies the containment check.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-00000000000b';
        v_old UUID; v_emptied BOOLEAN;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T11','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',100,tstzrange('2026-06-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_old;

    PERFORM correct_program_participant(
      v_old, tstzrange('2026-01-01','2027-01-01','[)'),
      'capacity_provider','Fronting Co',100,NULL,NULL);
    SET CONSTRAINTS ALL IMMEDIATE;

    SELECT isempty(effective_range) INTO v_emptied
    FROM program_participants WHERE participant_id = v_old;
    IF NOT v_emptied THEN
      RAISE EXCEPTION '0017-T11 FAILED: the superseded row was not emptied by an earlier-start correction';
    END IF;
    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0017-T11 FAILED: an emptied row disturbed the timeline';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0017-T11 pass: earlier-start correction empties, no inverted range';
END $$;

-- ---------------------------------------------------------------------------
-- T12 Deferral is load-bearing. ADR 0017 section 2: a real panel change is
--     several statements and is only coherent as a unit, so the panel must be
--     allowed to sit at 85% mid-transaction and be judged once at the end.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000017-0000-0000-0000-00000000000c';
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0017-T12','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    -- intermediate state: 60 + 25 = 85, which would fail if checked per statement
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',25,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Three',15,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;

    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0017-T12 FAILED: the completed panel reported a gap';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0017-T12 pass: 85%% mid-transaction tolerated, judged once at the end';
END $$;

ROLLBACK;

\echo '0017: 12/12 cases passed (nothing committed)'
