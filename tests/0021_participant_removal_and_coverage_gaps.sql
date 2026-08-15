-- Behavioural tests for ADR 0021: mid-term participant removal, program-term
-- protection, and bundled reallocation.
-- See docs/decisions/0021-participant-removal-and-coverage-gaps.md.
--
-- The addendum's own cases live in
-- tests/0021_addendum_widen_gap_suppression.sql - see ADR 0022 section 3 for
-- why that one got its own file rather than being appended here.
--
-- Same structure as the 0017 suite: one transaction rolled back at the end,
-- one self-unwinding DO block per case, SET CONSTRAINTS ALL IMMEDIATE instead
-- of committing, RAISE on any assertion that does not hold.

\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- T1  A mid-term close with NO gap row is rejected. Removal does not relax the
--     rule; the gap row is the only thing that suppresses it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000001';
        v_re UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T1','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;

    -- the raw close remove_program_participant() would do, without the gap row
    PERFORM set_config('luxauto.superseding_participant','on',true);
    UPDATE program_participants
       SET effective_range = tstzrange(lower(effective_range),
                                       GREATEST(lower(effective_range),'2026-07-01'::timestamptz))
     WHERE participant_id = v_re;
    PERFORM set_config('luxauto.superseding_participant','off',true);
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0021-T1 FAILED: an untracked mid-term hole was accepted';
  END IF;
  IF v_err NOT LIKE '%PROGRAM_SHARES_NOT_100_AT_INSTANT%' THEN
    RAISE EXCEPTION '0021-T1 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0021-T1 pass: untracked removal rejected';
END $$;

-- ---------------------------------------------------------------------------
-- T2  remove_program_participant() opens a gap row and the same hole is then
--     tolerated. Also checks the row's own shape.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000002';
        v_re UUID; v_gap UUID; v_direction TEXT; v_linked UUID;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T2','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;

    v_gap := remove_program_participant(v_re,'2026-07-01','Re Two exited mid-term');
    SET CONSTRAINTS ALL IMMEDIATE;

    SELECT direction INTO v_direction FROM program_share_gaps(p) ORDER BY bad_instant LIMIT 1;
    IF v_direction IS DISTINCT FROM 'under' THEN
      RAISE EXCEPTION '0021-T2 FAILED: expected an under-100 hole after removal, got %', COALESCE(v_direction,'none');
    END IF;

    SELECT participant_id_removed INTO v_linked FROM program_coverage_gaps WHERE gap_id = v_gap;
    IF v_linked IS DISTINCT FROM v_re THEN
      RAISE EXCEPTION '0021-T2 FAILED: the gap row does not point at the removed participant';
    END IF;
    IF (SELECT upper(effective_range) FROM program_participants WHERE participant_id = v_re)
       IS DISTINCT FROM '2026-07-01'::timestamptz THEN
      RAISE EXCEPTION '0021-T2 FAILED: the removed row was not closed at the removal date';
    END IF;
    IF EXISTS (SELECT 1 FROM program_participants
                WHERE program_id = p AND participant_name = 'Re Two'
                  AND lower(effective_range) = '2026-07-01'::timestamptz) THEN
      RAISE EXCEPTION '0021-T2 FAILED: a replacement row was inserted - removal must insert none';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021-T2 pass: removal tracked, suppressed, no replacement inserted';
END $$;

-- ---------------------------------------------------------------------------
-- T3  A gap cannot be resolved while the panel is still under-placed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000003';
        v_re UUID; v_gap UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T3','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;
    v_gap := remove_program_participant(v_re,'2026-07-01','exited');
    PERFORM resolve_program_coverage_gap(v_gap,'claiming this is fine');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0021-T3 FAILED: a gap was resolved while the panel was still broken';
  END IF;
  IF v_err NOT LIKE '%PROGRAM_COVERAGE_GAP_STILL_UNPLACED%' THEN
    RAISE EXCEPTION '0021-T3 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0021-T3 pass: premature resolve refused';
END $$;

-- ---------------------------------------------------------------------------
-- T4  Rebuild the panel, then resolve. The resolution is stamped.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000004';
        v_re UUID; v_gap UUID; v_resolved BOOLEAN; v_stamped BOOLEAN;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T4','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;
    v_gap := remove_program_participant(v_re,'2026-07-01','exited');

    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Replacement',40,tstzrange('2026-07-01','2027-01-01','[)'));

    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0021-T4 FAILED: the rebuilt panel still reports a gap';
    END IF;

    PERFORM resolve_program_coverage_gap(v_gap,'Re Replacement bound at 40 from 2026-07-01');
    SELECT resolved, resolved_at IS NOT NULL INTO v_resolved, v_stamped
    FROM program_coverage_gaps WHERE gap_id = v_gap;
    IF NOT v_resolved OR NOT v_stamped THEN
      RAISE EXCEPTION '0021-T4 FAILED: resolve did not set resolved/resolved_at';
    END IF;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021-T4 pass: rebuild then resolve';
END $$;

-- ---------------------------------------------------------------------------
-- T5  Resolving a gap twice is refused.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000005';
        v_re UUID; v_gap UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T5','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;
    v_gap := remove_program_participant(v_re,'2026-07-01','exited');
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Replacement',40,tstzrange('2026-07-01','2027-01-01','[)'));
    PERFORM resolve_program_coverage_gap(v_gap,'first');
    PERFORM resolve_program_coverage_gap(v_gap,'second');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION '0021-T5 FAILED: a gap was resolved twice'; END IF;
  IF v_err NOT LIKE '%PROGRAM_COVERAGE_GAP_ALREADY_RESOLVED%' THEN
    RAISE EXCEPTION '0021-T5 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0021-T5 pass: double resolve refused';
END $$;

-- ---------------------------------------------------------------------------
-- T6  Over-100% is NOT suppressed by an open gap on the same program.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000006';
        v_re UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T6','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;
    PERFORM remove_program_participant(v_re,'2026-07-01','exited');
    -- overlap earlier in the timeline: Mar-Jun goes to 130
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Duplicate',30,tstzrange('2026-03-01','2026-06-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0021-T6 FAILED: an overlap was suppressed by an open coverage gap';
  END IF;
  IF v_err NOT LIKE '%PROGRAM_SHARES_NOT_100_AT_INSTANT%' OR v_err NOT LIKE '%130%' THEN
    RAISE EXCEPTION '0021-T6 FAILED: expected the 130-percent overlap, got: %', v_err;
  END IF;
  RAISE NOTICE '0021-T6 pass: overlap still hard-blocks with a gap open';
END $$;

-- ---------------------------------------------------------------------------
-- T7  The case the probe split exists for: an UNDER earlier in the timeline
--     than an OVER. A LIMIT-1 probe returns only the (suppressed) under, so a
--     trigger built on it would let the later overlap through. ADR 0021
--     section 2.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000007';
        v_re UUID; v_first TEXT; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T7','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;
    PERFORM remove_program_participant(v_re,'2026-03-01','exited in March');
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Late',50,tstzrange('2026-09-01','2027-01-01','[)'));

    -- the premise: the earliest bad instant really is the suppressible one
    SELECT direction INTO v_first FROM first_program_share_gap(p);
    IF v_first IS DISTINCT FROM 'under' THEN
      RAISE EXCEPTION '0021-T7 FAILED: premise broken - earliest bad instant is %, expected under', COALESCE(v_first,'none');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM program_share_gaps(p) WHERE direction = 'over') THEN
      RAISE EXCEPTION '0021-T7 FAILED: premise broken - no over-100 instant was created';
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0021-T7 FAILED: a later overlap was hidden behind an earlier suppressed gap';
  END IF;
  IF v_err NOT LIKE '%110%' THEN
    RAISE EXCEPTION '0021-T7 FAILED: expected the 110-percent overlap, got: %', v_err;
  END IF;
  RAISE NOTICE '0021-T7 pass: later overlap caught despite an earlier suppressed gap';
END $$;

-- ---------------------------------------------------------------------------
-- T8  Narrowing a program term that would strand a participant is refused.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000008';
        v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T8','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;
    UPDATE insurance_programs SET effective_range = tstzrange('2026-01-01','2026-06-01','[)')
     WHERE program_id = p;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0021-T8 FAILED: a narrow stranded the panel and was accepted';
  END IF;
  IF v_err NOT LIKE '%PROGRAM_TERM_STRANDS_PARTICIPANT%' THEN
    RAISE EXCEPTION '0021-T8 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0021-T8 pass: stranding narrow refused';
END $$;

-- ---------------------------------------------------------------------------
-- T9  A narrow that strands nobody is accepted, and opens no gap row: every
--     instant it keeps was already inside the old term.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000009';
        v_gaps INT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T9','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2026-06-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2026-06-01','[)'));
    UPDATE insurance_programs SET effective_range = tstzrange('2026-01-01','2026-06-01','[)')
     WHERE program_id = p;
    SET CONSTRAINTS ALL IMMEDIATE;

    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0021-T9 FAILED: the narrowed term reports a share gap';
    END IF;
    SELECT count(*) INTO v_gaps FROM program_coverage_gaps WHERE program_id = p;
    IF v_gaps <> 0 THEN
      RAISE EXCEPTION '0021-T9 FAILED: a narrow opened % coverage gap row(s)', v_gaps;
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021-T9 pass: harmless narrow accepted, no gap opened';
END $$;

-- ---------------------------------------------------------------------------
-- T10 add_program_participant_with_reallocation(): explicit targets, one
--     coherent panel, judged once.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-00000000000a';
        v_cap UUID; v_re UUID; v_new UUID; v_share NUMERIC;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T10','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_cap;
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;

    -- 60/40 becomes 50/25 with a new 25, all three numbers given explicitly
    v_new := add_program_participant_with_reallocation(
      p,'reinsurer','Re Three',25,NULL,NULL,
      tstzrange('2026-07-01','2027-01-01','[)'),
      ARRAY[v_cap, v_re], ARRAY[50,25]::NUMERIC[]);
    SET CONSTRAINTS ALL IMMEDIATE;

    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0021-T10 FAILED: the reallocated panel does not total 100 at every instant';
    END IF;
    SELECT share_percentage INTO v_share FROM program_participants
     WHERE program_id = p AND participant_name = 'Fronting Co'
       AND lower(effective_range) = '2026-07-01'::timestamptz;
    IF v_share IS DISTINCT FROM 50 THEN
      RAISE EXCEPTION '0021-T10 FAILED: expected the capacity provider at 50 from the changeover, got %', v_share;
    END IF;
    IF (SELECT upper(effective_range) FROM program_participants WHERE participant_id = v_cap)
       IS DISTINCT FROM '2026-07-01'::timestamptz THEN
      RAISE EXCEPTION '0021-T10 FAILED: the outgoing row was not closed at the changeover';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021-T10 pass: add-with-reallocation produces one coherent panel';
END $$;

-- ---------------------------------------------------------------------------
-- T11 Mismatched array lengths are refused (the check the composite type
--     would otherwise have bought).
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-00000000000b';
        v_cap UUID; v_re UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T11','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_cap;
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;
    PERFORM add_program_participant_with_reallocation(
      p,'reinsurer','Re Three',25,NULL,NULL,
      tstzrange('2026-07-01','2027-01-01','[)'),
      ARRAY[v_cap, v_re], ARRAY[50]::NUMERIC[]);
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION '0021-T11 FAILED: mismatched arrays were accepted'; END IF;
  IF v_err NOT LIKE '%PROGRAM_REALLOCATION_MALFORMED%' THEN
    RAISE EXCEPTION '0021-T11 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0021-T11 pass: mismatched arrays refused';
END $$;

-- ---------------------------------------------------------------------------
-- T12 A participant belonging to another program is refused.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-00000000000c';
        q UUID := '00000021-0000-0000-0000-00000000000d';
        v_other UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T12a','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)')),
           (q,'0021-T12b','Other Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',100,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (q,'capacity_provider','Other Co',100,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_other;
    PERFORM add_program_participant_with_reallocation(
      p,'reinsurer','Re Three',25,NULL,NULL,
      tstzrange('2026-07-01','2027-01-01','[)'),
      ARRAY[v_other], ARRAY[75]::NUMERIC[]);
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0021-T12 FAILED: a participant from another program was reallocated';
  END IF;
  IF v_err NOT LIKE '%PROGRAM_REALLOCATION_WRONG_PROGRAM%' THEN
    RAISE EXCEPTION '0021-T12 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0021-T12 pass: cross-program reallocation refused';
END $$;

-- ---------------------------------------------------------------------------
-- T13 The ADR 0016 addendum 2 trap: calling a supersession function with a
--     subquery over the very table it locks. The flag mechanism is immune;
--     DISABLE TRIGGER was not. Both new functions are exercised this way.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-00000000000e';
        v_cap UUID;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T13','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_cap;
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'));

    PERFORM remove_program_participant(
      (SELECT participant_id FROM program_participants
        WHERE program_id = p AND participant_name = 'Re Two'),
      '2026-07-01','removed via a subquery over the same table');
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021-T13 pass: same-table subquery trap does not apply to remove_program_participant';
END $$;

DO $$
DECLARE p UUID := '00000021-0000-0000-0000-00000000000f';
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T14','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'));

    PERFORM add_program_participant_with_reallocation(
      p,'reinsurer','Re Three',25,NULL,NULL,
      tstzrange('2026-07-01','2027-01-01','[)'),
      ARRAY(SELECT participant_id FROM program_participants
             WHERE program_id = p ORDER BY participant_name),
      ARRAY[50,25]::NUMERIC[]);
    SET CONSTRAINTS ALL IMMEDIATE;

    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0021-T14 FAILED: the reallocated panel reports a gap';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021-T14 pass: same-table subquery trap does not apply to add..._with_reallocation';
END $$;

-- ---------------------------------------------------------------------------
-- T15 A removal needs a non-empty reason - it is the only description of the
--     hole a later reader will ever see.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000010';
        v_re UUID; v_ok BOOLEAN := false; v_err TEXT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T15','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;
    PERFORM remove_program_participant(v_re,'2026-07-01','   ');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION '0021-T15 FAILED: a blank reason was accepted'; END IF;
  IF v_err NOT LIKE '%PROGRAM_REMOVAL_REASON_REQUIRED%' THEN
    RAISE EXCEPTION '0021-T15 FAILED: wrong error: %', v_err;
  END IF;
  RAISE NOTICE '0021-T15 pass: blank reason refused';
END $$;

-- ---------------------------------------------------------------------------
-- T16 A removal dated at or before the row's own start EMPTIES it, reusing
--     ADR 0016 addendum 3's GREATEST() bound rather than producing an
--     inverted range.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '00000021-0000-0000-0000-000000000011';
        v_mga UUID; v_emptied BOOLEAN;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021-T16','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',100,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'mga_retention','LuxAuto MGA',10,tstzrange('2026-06-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_mga;

    PERFORM remove_program_participant(v_mga,'2026-01-01','dated before its own start');
    SET CONSTRAINTS ALL IMMEDIATE;

    SELECT isempty(effective_range) INTO v_emptied
    FROM program_participants WHERE participant_id = v_mga;
    IF NOT v_emptied THEN
      RAISE EXCEPTION '0021-T16 FAILED: the row was not emptied by an early removal date';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021-T16 pass: early removal date empties the row';
END $$;

ROLLBACK;

\echo '0021: 16/16 cases passed (nothing committed)'
