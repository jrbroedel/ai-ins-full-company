-- Behavioural tests for ADR 0040: the two read views backing the Odoo underwriter
-- override UI - luxauto_underwriter_review_view and luxauto_underwriter_view.
--
-- The write/authority behaviour is already covered by tests/0032 and tests/0038;
-- this suite proves the UI-facing view logic: a flagged application shows as
-- PENDING in the review queue, and flips to RELEASED (with the authorizer and
-- reason) once authorize_referral_override() runs - the exact "authorize an
-- override, see it reflected" transition the demo walks through. Also that a
-- non-overridable disposition never enters the queue, and the roster view exposes
-- the underwriters table with a stable integer id for Odoo.
--
-- Same discipline as the sibling suites: one transaction rolled back at the end,
-- one self-unwinding DO block per case, IS DISTINCT FROM on nullable reads.

\set ON_ERROR_STOP on
BEGIN;

-- A submitted application with a single staged decision_log disposition, so
-- luxauto_application_referral_view derives that action as most_severe (one rule
-- row -> most_severe = that action, evaluated_at = its created_at).
CREATE FUNCTION pg_temp.mk_flagged(p_tag TEXT, p_action referral_action_t, OUT app_id UUID) AS $fx$
DECLARE v_applicant UUID;
BEGIN
  INSERT INTO applicants (first_name, last_name) VALUES ('Test', '0040-' || p_tag) RETURNING applicant_id INTO v_applicant;
  INSERT INTO applications (applicant_id, status, garaging_state) VALUES (v_applicant, 'submitted', 'CA') RETURNING application_id INTO app_id;
  INSERT INTO decision_log (application_id, rule_id, reason_code, action_taken, fired, decided_by)
  VALUES (app_id, 'TEST-RULE', 'TEST_REASON', p_action, p_action <> 'AUTO_PROCEED', 'system');
END;
$fx$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- T1  A flagged application shows in the review queue as PENDING; a clean
--     (AUTO_PROCEED) application never enters the queue.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_flagged UUID; v_clean UUID; r RECORD; v_n INT;
BEGIN
  BEGIN
    v_flagged := pg_temp.mk_flagged('T1flag', 'MANUAL_REVIEW_REQUIRED');
    v_clean   := pg_temp.mk_flagged('T1clean', 'AUTO_PROCEED');

    SELECT * INTO r FROM luxauto_underwriter_review_view WHERE application_id = v_flagged;
    IF r.application_id IS NULL THEN
      RAISE EXCEPTION '0040-T1 FAILED: a MANUAL_REVIEW_REQUIRED application did not appear in the review queue';
    END IF;
    IF (r.most_severe_action, r.override_status, r.override_id, r.authorized_by_name)
       IS DISTINCT FROM ('MANUAL_REVIEW_REQUIRED'::referral_action_t, 'pending', NULL::uuid, NULL::text) THEN
      RAISE EXCEPTION '0040-T1 FAILED: flagged row is action=%/status=%/override=%/by=%, expected MANUAL_REVIEW_REQUIRED/pending/NULL/NULL',
        r.most_severe_action, r.override_status, r.override_id, r.authorized_by_name;
    END IF;

    SELECT count(*) INTO v_n FROM luxauto_underwriter_review_view WHERE application_id = v_clean;
    IF v_n <> 0 THEN
      RAISE EXCEPTION '0040-T1 FAILED: an AUTO_PROCEED application entered the review queue (% rows) - only overridable dispositions belong', v_n;
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0040-T1 pass: a flagged application shows as pending in the review queue; a clean application never enters it';
END $$;

-- ---------------------------------------------------------------------------
-- T2  After authorize_referral_override(), the same row flips to RELEASED, with
--     the authorizer's name and the reason surfaced - the demo transition.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_app UUID; v_uw UUID; r RECORD;
BEGIN
  BEGIN
    v_app := pg_temp.mk_flagged('T2', 'MANUAL_REVIEW_REQUIRED');
    v_uw  := add_underwriter('Bob Standard', 'standard');

    -- Pending before.
    SELECT override_status INTO r FROM luxauto_underwriter_review_view WHERE application_id = v_app;
    IF r.override_status IS DISTINCT FROM 'pending' THEN
      RAISE EXCEPTION '0040-T2 FAILED: expected pending before the override, got %', r.override_status;
    END IF;

    PERFORM authorize_referral_override(v_app, 'MANUAL_REVIEW_REQUIRED', 'reviewed the file, releasing', v_uw);

    -- Released after, with authorizer + reason.
    SELECT * INTO r FROM luxauto_underwriter_review_view WHERE application_id = v_app;
    IF (r.override_status, r.authorized_by_name, r.authorized_by_authority, r.override_reason)
       IS DISTINCT FROM ('released', 'Bob Standard', 'standard'::underwriter_authority_t, 'reviewed the file, releasing') THEN
      RAISE EXCEPTION '0040-T2 FAILED: released row is status=%/by=%/authority=%/reason=%, expected released/Bob Standard/standard/"reviewed the file, releasing"',
        r.override_status, r.authorized_by_name, r.authorized_by_authority, r.override_reason;
    END IF;
    IF r.override_id IS NULL OR r.overridden_at IS NULL THEN
      RAISE EXCEPTION '0040-T2 FAILED: released row is missing override_id or overridden_at';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0040-T2 pass: authorize_referral_override flips the queue row pending -> released, surfacing the authorizer (Bob Standard/standard) and reason';
END $$;

-- ---------------------------------------------------------------------------
-- T3  The roster view exposes the underwriters table with a stable integer id
--     (Odoo requires one over the UUID-keyed table) and carries underwriter_id
--     through for the wizard.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_uw UUID; r RECORD;
BEGIN
  BEGIN
    v_uw := add_underwriter('Alice Senior', 'senior');
    SELECT * INTO r FROM luxauto_underwriter_view WHERE underwriter_id = v_uw;
    IF (r.name, r.authority_level, r.is_active) IS DISTINCT FROM ('Alice Senior', 'senior'::underwriter_authority_t, true) THEN
      RAISE EXCEPTION '0040-T3 FAILED: roster row is %/%/%, expected Alice Senior/senior/true', r.name, r.authority_level, r.is_active;
    END IF;
    IF r.id IS NULL THEN
      RAISE EXCEPTION '0040-T3 FAILED: roster view row has a NULL integer id - Odoo requires one';
    END IF;
    -- update_underwriter (ADR 0038) is reflected in the view.
    PERFORM update_underwriter(v_uw, p_active => false);
    SELECT is_active AS active INTO r FROM luxauto_underwriter_view WHERE underwriter_id = v_uw;
    IF r.active IS DISTINCT FROM false THEN
      RAISE EXCEPTION '0040-T3 FAILED: the roster view did not reflect a deactivation';
    END IF;

    RAISE EXCEPTION 'ROLLBACK_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CASE' THEN RAISE; END IF;
  END;
  RAISE NOTICE '0040-T3 pass: luxauto_underwriter_view exposes the roster with a stable integer id and reflects add_underwriter/update_underwriter';
END $$;

ROLLBACK;

\echo '0040: 3/3 cases passed (nothing committed)'
