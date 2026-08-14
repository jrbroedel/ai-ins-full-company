-- Behavioural tests for the ADR 0021 addendum: term changes that expose new
-- instants. See the addendum at the end of
-- docs/decisions/0021-participant-removal-and-coverage-gaps.md.
--
-- Kept as its own file rather than appended to the parent ADR's suite (ADR
-- 0022 section 3): these cases are about range semantics on
-- insurance_programs, not about participant removal, and two of them exist
-- specifically to pin down which range comparison is correct - a question the
-- parent suite never asks. Reading them next to the parent's removal cases
-- would obscure both.
--
-- Same structure as the other suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, SET CONSTRAINTS ALL IMMEDIATE rather
-- than committing, RAISE on any assertion that does not hold.

\set ON_ERROR_STOP on
BEGIN;

-- ---------------------------------------------------------------------------
-- A1  The range algebra the trigger's condition rests on. Pure predicate
--     assertions, no tables touched - these are the claims the addendum makes
--     about what "widening" means, checked directly.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  old_r TSTZRANGE; new_r TSTZRANGE;
BEGIN
  -- (a) lower-bound-only extension: upper() is unchanged, six months exposed
  old_r := tstzrange('2026-06-01','2027-01-01','[)');
  new_r := tstzrange('2026-01-01','2027-01-01','[)');
  IF upper(new_r) > upper(old_r) THEN
    RAISE EXCEPTION 'A1a FAILED: premise broken - upper() did change';
  END IF;
  IF (new_r <@ old_r) THEN
    RAISE EXCEPTION 'A1a FAILED: the containment test missed a lower-bound extension';
  END IF;

  -- (b) shift: neither range contains the other, yet instants are exposed
  old_r := tstzrange('2026-01-01','2027-01-01','[)');
  new_r := tstzrange('2026-06-01','2027-06-01','[)');
  IF (old_r <@ new_r) THEN
    RAISE EXCEPTION 'A1b FAILED: premise broken - a shift should not be a superset';
  END IF;
  IF (new_r <@ old_r) THEN
    RAISE EXCEPTION 'A1b FAILED: the containment test missed a shift';
  END IF;

  -- (c) pure narrow: nothing exposed, must be skipped
  old_r := tstzrange('2026-01-01','2027-01-01','[)');
  new_r := tstzrange('2026-03-01','2026-09-01','[)');
  IF NOT (new_r <@ old_r) THEN
    RAISE EXCEPTION 'A1c FAILED: a pure narrow was treated as exposing new instants';
  END IF;

  RAISE NOTICE '0021add-A1 pass: NOT (NEW <@ OLD) is the correct exposure test';
END $$;

-- ---------------------------------------------------------------------------
-- A2  A proper widen that exposes an unplaced stretch opens a gap row in the
--     same transaction, and does not block. This is the ADR 0021 open item.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '21ADD000-0000-0000-0000-000000000002'::UUID;
        v_gaps INT; v_linked UUID; v_reason TEXT; v_when TIMESTAMPTZ;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021add-A2','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;

    UPDATE insurance_programs SET effective_range = tstzrange('2025-06-01','2028-01-01','[)')
     WHERE program_id = p;

    SELECT count(*) INTO v_gaps FROM program_coverage_gaps WHERE program_id = p AND NOT resolved;
    IF v_gaps <> 1 THEN
      RAISE EXCEPTION '0021add-A2 FAILED: expected exactly 1 open gap row after the widen, got %', v_gaps;
    END IF;

    SELECT participant_id_removed, reason, removal_date
      INTO v_linked, v_reason, v_when
    FROM program_coverage_gaps WHERE program_id = p;

    IF v_linked IS NOT NULL THEN
      RAISE EXCEPTION '0021add-A2 FAILED: a term-change gap must not point at a participant';
    END IF;
    IF v_reason NOT LIKE 'program term widened%' THEN
      RAISE EXCEPTION '0021add-A2 FAILED: unexpected reason text: %', v_reason;
    END IF;
    IF v_when <> '2025-06-01'::timestamptz THEN
      RAISE EXCEPTION '0021add-A2 FAILED: expected the gap dated at the first exposed instant, got %', v_when;
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021add-A2 pass: widen opens one unlinked gap row at the first exposed instant';
END $$;

-- ---------------------------------------------------------------------------
-- A3  ... and the hole is then tolerated by a later unrelated participant
--     write, which before the addendum raised out of nowhere.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '21ADD000-0000-0000-0000-000000000003'::UUID;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021add-A3','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;

    UPDATE insurance_programs SET effective_range = tstzrange('2025-06-01','2028-01-01','[)')
     WHERE program_id = p;

    -- an unrelated write to the panel: must be suppressed, not raised
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'mga_retention','LuxAuto MGA',10,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021add-A3 pass: the later unrelated write is suppressed, not raised';
END $$;

-- ---------------------------------------------------------------------------
-- A4  A shift opens a gap too - the case a superset test would have missed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '21ADD000-0000-0000-0000-000000000004'::UUID;
        v_when TIMESTAMPTZ; v_gaps INT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021add-A4','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    -- panel sits inside the overlap, so the containment guard lets the shift through
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-06-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-06-01','2027-01-01','[)'));

    UPDATE insurance_programs SET effective_range = tstzrange('2026-06-01','2027-06-01','[)')
     WHERE program_id = p;

    SELECT count(*), min(removal_date) INTO v_gaps, v_when
    FROM program_coverage_gaps WHERE program_id = p;
    IF v_gaps <> 1 THEN
      RAISE EXCEPTION '0021add-A4 FAILED: a shift opened % gap row(s), expected 1', v_gaps;
    END IF;
    IF v_when <> '2027-01-01'::timestamptz THEN
      RAISE EXCEPTION '0021add-A4 FAILED: expected the gap at 2027-01-01, got %', v_when;
    END IF;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021add-A4 pass: a shift opens a gap at the newly exposed tail';
END $$;

-- ---------------------------------------------------------------------------
-- A5  A lower-bound-only extension opens a gap - the case a
--     "upper(NEW) > upper(OLD)" test would have skipped entirely.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '21ADD000-0000-0000-0000-000000000005'::UUID;
        v_when TIMESTAMPTZ; v_gaps INT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021add-A5','Fronting Co',tstzrange('2026-06-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-06-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-06-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;

    UPDATE insurance_programs SET effective_range = tstzrange('2026-01-01','2027-01-01','[)')
     WHERE program_id = p;

    SELECT count(*), min(removal_date) INTO v_gaps, v_when
    FROM program_coverage_gaps WHERE program_id = p;
    IF v_gaps <> 1 THEN
      RAISE EXCEPTION '0021add-A5 FAILED: a lower-bound extension opened % gap row(s), expected 1', v_gaps;
    END IF;
    IF v_when <> '2026-01-01'::timestamptz THEN
      RAISE EXCEPTION '0021add-A5 FAILED: expected the gap at 2026-01-01, got %', v_when;
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021add-A5 pass: lower-bound extension caught';
END $$;

-- ---------------------------------------------------------------------------
-- A6  A widen that exposes nothing unplaced opens NO gap row. The trigger must
--     not suppress on every term change, only where a hole actually appears.
--     A program whose risk-bearing panel does not exist yet is ADR 0017's
--     bootstrapping escape, and must survive a widen untouched.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '21ADD000-0000-0000-0000-000000000006'::UUID;
        v_gaps INT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021add-A6','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'mga_retention','LuxAuto MGA',10,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;

    UPDATE insurance_programs SET effective_range = tstzrange('2025-06-01','2028-01-01','[)')
     WHERE program_id = p;

    SELECT count(*) INTO v_gaps FROM program_coverage_gaps WHERE program_id = p;
    IF v_gaps <> 0 THEN
      RAISE EXCEPTION '0021add-A6 FAILED: a widen over an un-panelled program opened % gap row(s)', v_gaps;
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021add-A6 pass: no over-suppression - a harmless widen opens nothing';
END $$;

-- ---------------------------------------------------------------------------
-- A7  An OVER-100 finding is reachable at widen time (the participants check
--     is deferred, so an overlap inserted earlier in the same transaction is
--     visible to this BEFORE trigger) and must NOT be auto-suppressed. The
--     widen may open a row for the under; the overlap must still fail.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '21ADD000-0000-0000-0000-000000000007'::UUID;
        v_ok BOOLEAN := false; v_err TEXT; v_over INT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021add-A7','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    -- uncommitted overlap; its own check is still pending
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Overlap',30,tstzrange('2026-03-01','2026-06-01','[)'));

    UPDATE insurance_programs SET effective_range = tstzrange('2025-06-01','2028-01-01','[)')
     WHERE program_id = p;

    -- premise: the trigger really could see an over at this point
    SELECT count(*) INTO v_over
    FROM program_share_gaps(p, tstzrange('2025-06-01','2028-01-01','[)'))
    WHERE direction = 'over';
    IF v_over = 0 THEN
      RAISE EXCEPTION '0021add-A7 FAILED: premise broken - no over-100 instant was visible at widen time';
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION '0021add-A7 FAILED: a term change suppressed an overlap - the one exception ADR 0021 forbids';
  END IF;
  IF v_err NOT LIKE '%PROGRAM_SHARES_NOT_100_AT_INSTANT%' OR v_err NOT LIKE '%130%' THEN
    RAISE EXCEPTION '0021add-A7 FAILED: expected the 130-percent overlap to fail, got: %', v_err;
  END IF;
  RAISE NOTICE '0021add-A7 pass: over-100 at widen time is never auto-suppressed';
END $$;

-- ---------------------------------------------------------------------------
-- A8  A widen while a gap is already open adds no second row: suppression is
--     per-program, so one open row already covers the timeline.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '21ADD000-0000-0000-0000-000000000008'::UUID;
        v_re UUID; v_gaps INT;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021add-A8','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'))
    RETURNING participant_id INTO v_re;

    PERFORM remove_program_participant(v_re,'2026-07-01','exited');
    UPDATE insurance_programs SET effective_range = tstzrange('2025-06-01','2028-01-01','[)')
     WHERE program_id = p;

    SELECT count(*) INTO v_gaps FROM program_coverage_gaps WHERE program_id = p;
    IF v_gaps <> 1 THEN
      RAISE EXCEPTION '0021add-A8 FAILED: expected 1 gap row, got % - the widen duplicated it', v_gaps;
    END IF;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021add-A8 pass: no duplicate gap row';
END $$;

-- ---------------------------------------------------------------------------
-- A9  resolve_program_coverage_gap() works unchanged on a gap opened this way:
--     it refuses while the newly exposed stretch is unplaced, and succeeds
--     once the panel actually covers the widened term.
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '21ADD000-0000-0000-0000-000000000009'::UUID;
        v_gap UUID; v_ok BOOLEAN := false; v_err TEXT; v_resolved BOOLEAN;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021add-A9','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;

    UPDATE insurance_programs SET effective_range = tstzrange('2026-01-01','2028-01-01','[)')
     WHERE program_id = p;
    SELECT gap_id INTO v_gap FROM program_coverage_gaps WHERE program_id = p;

    -- premature resolve must refuse
    BEGIN
      PERFORM resolve_program_coverage_gap(v_gap,'premature');
    EXCEPTION WHEN OTHERS THEN
      v_ok := true; v_err := SQLERRM;
    END;
    IF NOT v_ok THEN
      RAISE EXCEPTION '0021add-A9 FAILED: resolved a term-change gap while the stretch was unplaced';
    END IF;
    IF v_err NOT LIKE '%PROGRAM_COVERAGE_GAP_STILL_UNPLACED%' THEN
      RAISE EXCEPTION '0021add-A9 FAILED: wrong error: %', v_err;
    END IF;

    -- place the exposed 2027 layer, then resolve
    SET CONSTRAINTS ALL DEFERRED;
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2027-01-01','2028-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2027-01-01','2028-01-01','[)'));
    IF EXISTS (SELECT 1 FROM program_share_gaps(p)) THEN
      RAISE EXCEPTION '0021add-A9 FAILED: the widened term is still not fully placed';
    END IF;

    PERFORM resolve_program_coverage_gap(v_gap,'2027 layer placed');
    SELECT resolved INTO v_resolved FROM program_coverage_gaps WHERE gap_id = v_gap;
    IF NOT v_resolved THEN
      RAISE EXCEPTION '0021add-A9 FAILED: resolve did not take';
    END IF;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021add-A9 pass: resolve unchanged for a term-change gap';
END $$;

-- ---------------------------------------------------------------------------
-- A10 The term override is read-only: probing a hypothetical term must not
--     touch the stored row, and the bare one-argument call must still resolve
--     (a defaulted parameter overloads rather than replaces, so leaving the
--     old signature behind would make this ambiguous).
-- ---------------------------------------------------------------------------
DO $$
DECLARE p UUID := '21ADD000-0000-0000-0000-00000000000a'::UUID;
        v_live INT; v_hypo INT; v_wrapper INT; v_stored TSTZRANGE;
BEGIN
  BEGIN
    INSERT INTO insurance_programs (program_id, program_name, capacity_provider_name, effective_range)
    VALUES (p,'0021add-A10','Fronting Co',tstzrange('2026-01-01','2027-01-01','[)'));
    INSERT INTO program_participants (program_id, participant_type, participant_name, share_percentage, effective_range)
    VALUES (p,'capacity_provider','Fronting Co',60,tstzrange('2026-01-01','2027-01-01','[)')),
           (p,'reinsurer','Re Two',40,tstzrange('2026-01-01','2027-01-01','[)'));
    SET CONSTRAINTS ALL IMMEDIATE;

    SELECT count(*) INTO v_live FROM program_share_gaps(p);
    SELECT count(*) INTO v_wrapper FROM first_program_share_gap(p);
    SELECT count(*) INTO v_hypo
    FROM program_share_gaps(p, tstzrange('2025-01-01','2028-01-01','[)'));
    SELECT effective_range INTO v_stored FROM insurance_programs WHERE program_id = p;

    IF v_live <> 0 OR v_wrapper <> 0 THEN
      RAISE EXCEPTION '0021add-A10 FAILED: the live term should be sound (got % / %)', v_live, v_wrapper;
    END IF;
    IF v_hypo = 0 THEN
      RAISE EXCEPTION '0021add-A10 FAILED: the hypothetical wider term should report holes';
    END IF;
    IF v_stored <> tstzrange('2026-01-01','2027-01-01','[)') THEN
      RAISE EXCEPTION '0021add-A10 FAILED: probing with an override mutated the stored term';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0021add-A10 pass: override is read-only and the bare call still resolves';
END $$;

ROLLBACK;

\echo '0021 addendum: 10/10 cases passed (nothing committed)'
