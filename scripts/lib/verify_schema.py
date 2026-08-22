"""
Parses schemas/db/postgresql_schema.sql for every object it declares
(tables, enum types, functions, views, triggers, and the columns the file
explicitly SET NOT NULL), cross-checks the parser's own counts against a
manually verified baseline (ADR 0015 section 2) before trusting it, then
confirms each parsed object actually exists in the target database. Exits
non-zero if the parser disagrees with the baseline, or if any expected
object is missing from the database.

The SET NOT NULL category is the ADR 0016 addendum's extension to ADR 0015
section 2's contract: that addendum's fix *is* a column constraint, and one
applied to already-created tables by an ALTER, so "the table exists" says
nothing about whether it took. Only columns the file alters explicitly are
checked - inline NOT NULLs in CREATE TABLE bodies are covered by the table's
own existence check, and parsing them would mean parsing column definitions.

Usage: verify_schema.py <path-to-postgresql_schema.sql>
Connection: standard libpq environment variables (PGHOST, PGUSER, PGPASSWORD,
PGDATABASE, PGSSLMODE, ...).
"""
import re
import sys
from collections import Counter

import psycopg2

# Manually verified snapshot (ADR 0015 section 2's acceptance-test discipline;
# counts updated for ADR 0016's policy_vehicles/policy_drivers addition, its
# addendum's three SET NOT NULL columns, and ADR 0017's program_participants
# work: +3 functions (first_program_share_gap, correct_program_participant,
# reject_program_participants_mutation), +2 triggers (the two append-only
# ones), +3 SET NOT NULL columns, ADR 0018's cancellation work, and ADR
# 0019's nonrenewal/expiration work: +2 tables (nonrenewal_notice_requirements,
# policy_nonrenewals), +5 functions (nonrenewal_notice_days, nonrenew_policy,
# correct_policy_nonrenewal, expire_policies,
# reject_policy_nonrenewals_mutation), +2 triggers, no new types or views;
# and ADR 0021's participant-removal work: +1 table (program_coverage_gaps),
# +5 functions (program_share_gaps, remove_program_participant,
# resolve_program_coverage_gap, check_program_term_contains_participants,
# add_program_participant_with_reallocation), +1 trigger
# (insurance_programs_term_check), no new types, views or SET NOT NULL columns.
# first_program_share_gap is NOT a sixth new function - ADR 0021 changes its
# return type, which needs a DROP before the CREATE OR REPLACE, but it is the
# same one object the baseline already counted).
#
# ADR 0021's addendum moves no count. It adds a defaulted p_term_override
# parameter to program_share_gaps and first_program_share_gap - which needs a
# DROP of each one-argument form first, since a defaulted parameter overloads
# rather than replaces - and extends the body of
# check_program_term_contains_participants. Same objects, same names, new
# signatures, so all six categories stay where ADR 0021 left them. Confirmed
# by running the parser, not assumed.
#
# ADR 0018's addendum moves exactly one count: +1 view
# (luxauto_policy_cancellation_view), the read side over policy_cancellations
# that ADR 0018 named as an open item. It adds no table, type, function,
# trigger or SET NOT NULL column - a view and a GRANT are the whole schema
# change, and the GRANT is not a category this parser tracks (it checks that
# declared objects exist, not who may read them).
#
# ADR 0023's ">14-day" reinstatement moves exactly one count: +1 function
# (link_reinstated_policy). It adds a nullable reinstated_from_policy_id column
# and a policies_no_self_reinstatement CHECK to policies, but this parser tracks
# neither added columns nor CHECK constraints - only SET NOT NULL columns and
# object existence - so those are covered by the behavioural suite (tests/0023)
# and the policies table's own existence check, not here. No new table, type,
# view, trigger or SET NOT NULL column; luxauto_policy_view gains a column but
# is the same CREATE OR REPLACE VIEW, so the view count is unchanged.
#
# ADR 0024's backdated reinstatement-as-new-business moves three counts: +1 table
# (policy_reinstatements, the append-only link-and-attestation audit), +2 functions
# (reinstate_policy, reject_policy_reinstatements_mutation), +2 triggers (the two
# append-only ones on that table). bind_policy gains an optional inception-date
# parameter, which needs a DROP of the three-argument form before the CREATE (a
# defaulted parameter overloads rather than replaces, same as ADR 0021's addendum)
# - but it is the SAME one object, same name, so the function count moves only by
# the two genuinely new functions, not by three. The added UNIQUE/CHECK constraints
# and the new 'reinstated' event-type string are not categories this parser tracks;
# they are covered by tests/0024. No new type, view or SET NOT NULL column.
# (This supersedes the earlier, rejected gap-only ADR 0024 build; that version
# happened to move the same three counts, but for different objects - it is not
# what shipped. See docs/decisions/0024 for the rejected-design record.)
#
# ADR 0025's short-rate state-onboarding seed moves two counts: +1 function
# (seed_short_rate_factor_for_state) and +1 trigger
# (state_rating_versions_seed_short_rate, AFTER INSERT on
# state_rating_table_versions). It adds no table, type, view or SET NOT NULL
# column - the short_rate_factors table and short_rate_factor() lookup already
# existed (ADR 0018); this only wires an automatic seed onto state onboarding.
#
# ADR 0026's referral engine moves one count: +5 functions (evaluate_al01,
# evaluate_cp02, evaluate_dh01, evaluate_pc03, evaluate_application_referrals).
# It adds no table, type, view, trigger or SET NOT NULL column - the tables it
# reads (applications, vehicles, claims_history, person_violations,
# state_rating_table_versions), the append-only decision_log it writes, and the
# referral_action_t enum all already existed (ADR 0005); only the evaluation
# functions are new.
#
# ADR 0007's broker/MGA-commission addendum moves two counts: +1 type
# (broker_channel_t) and +2 SET NOT NULL columns (quotes.broker_channel,
# quotes.broker_commission_rate, both added by ALTER for existing databases and
# then SET NOT NULL under a guard). quotes.mga_commission_rate is a GENERATED
# STORED column, not a SET NOT NULL one, so it does not move the not_null count;
# the broker CHECK and the generated column are not categories this parser tracks.
# No new table, function, view or trigger.
#
# ADR 0028's rating engine v1 moves two counts: +3 tables (rating_base_rates,
# vehicle_category_rating_class, territory_factors) and +2 functions
# (compute_indicative_premium, and evaluate_el01 - the $100k eligibility floor
# wired into evaluate_application_referrals as a fifth referral rule). No new
# type, view, trigger or SET NOT NULL column; the seeded base-rate/territory rows
# and the CHECK/EXCLUDE constraints are not categories this parser tracks (they
# are covered by tests/0028).
#
# ADR 0035's onboard_state moves two counts: +2 functions (onboard_state, the
# sole sanctioned path for onboarding a state's rating data; and
# reject_unonboarded_state_rating_insert, the BEFORE INSERT guard trigger function
# that makes it sole by rejecting a direct insert without the luxauto.onboarding_
# state flag) and +1 trigger (state_rating_versions_onboard_guard). It also
# migrates ADR 0034's raw CT insert to an onboard_state() call and adds a
# REVOKE/GRANT, neither of which the parser tracks. No new table, type, view or
# SET NOT NULL column. Covered by tests/0035.
#
# ADR 0033's renewal workflow moves one count: +4 functions (policy_tenure_years,
# copy_application_for_renewal, renew_policy, generate_renewal_offers). It adds
# three columns to policies (renewed_from_policy_id, original_policy_id,
# renewal_generation) and their CHECK/index, and changes the tenure line in both
# nonrenew_policy and correct_policy_nonrenewal to call policy_tenure_years (the
# scoped Flag B relaxation, extended to both to avoid a divergence) - but
# added columns, CHECK constraints and CREATE-OR-REPLACE bodies are not categories
# this parser tracks (renewal_generation is added via ADD COLUMN ... NOT NULL
# DEFAULT, not an ALTER ... SET NOT NULL, so it does not move not_null_columns).
# No new table (A1: the successor policy IS the offer, no renewal_offers table),
# type, view or trigger. Covered by tests/0033.
#
# ADR 0032's underwriter supervised-release moves four counts: +1 type
# (underwriter_authority_t), +2 tables (underwriters, referral_overrides),
# +5 functions (add_underwriter, current_referral_evaluated_at,
# authorize_referral_override, and the two trigger functions
# reject_referral_overrides_mutation + enforce_referral_override_authority), and
# +3 triggers (referral_overrides_no_update/_no_delete append-only, plus
# referral_overrides_authority_check). create_quote() gains the override branch
# but is the same object. No new view or SET NOT NULL column (the referral_overrides
# CHECKs and the FK/NOT NULL in its CREATE TABLE body are not categories this
# parser tracks). Covered by tests/0032.
#
# ADR 0031's referral-gate wiring moves one count: +2 functions
# (current_referral_action, the latest-per-rule disposition read helper mirroring
# the ADR 0029 view; and submit_application, the first applications-lifecycle
# transition that evaluates the referral engine). create_quote() gains a guard
# but is the same one function (CREATE OR REPLACE), so it does not move any count.
# No new table, type, view, trigger or SET NOT NULL column. Covered by tests/0031
# (and the tests/0030 fixtures now submit before quoting).
#
# ADR 0030's quote-creation wiring moves two counts: +1 function (create_quote,
# the first real write path into quotes, which rates the quote via
# compute_indicative_premium() as it creates it) and +1 SET NOT NULL column
# (quotes.quoted_by, the quote-creation audit column create_quote persists
# p_performed_by into - added by ALTER then SET NOT NULL under a guard, the same
# idiom as the ADR 0007 addendum's broker columns). It adds no table, type, view
# or trigger. Behaviour is covered by tests/0030.
#
# ADR 0029's read-side visibility batch moves exactly one count: +6 views
# (luxauto_policy_reinstatement_view, luxauto_short_rate_factor_view,
# luxauto_decision_log_view, luxauto_application_referral_view,
# luxauto_quote_commission_view, luxauto_quote_rating_view) - the Odoo read side
# for ADRs 0024-0028, deferred and batched here. Each is a plain
# CREATE OR REPLACE VIEW plus a GRANT SELECT (the GRANT is not a category this
# parser tracks). No new table, type, function, trigger or SET NOT NULL column:
# these views only read tables and functions that already exist. Behaviour is
# covered by tests/0029.
#
# This is the acceptance test for the parser itself - if the parser's counts don't
# match this, that's a parser bug to fix, not a schema surprise, and the
# parser is not trusted against a live database until it does. Updated by
# hand each time the schema file changes - the object *names* are parsed
# automatically, but this snapshot is a fact about the file's current state,
# not something the parser can derive about itself.
BASELINE = {
    "tables": 35,
    "types": 21,
    "functions": 68,
    "views": 13,
    "triggers": 28,
    "not_null_columns": 9,
}

# Parsed and verified separately from PATTERNS/DB_QUERIES: a column isn't a
# named object in a catalog the way a table or a trigger is, so it needs its
# own (table, column) pair and its own information_schema question.
NOT_NULL_PATTERN = re.compile(
    r"^\s*ALTER TABLE (\w+) ALTER COLUMN (\w+) SET NOT NULL", re.MULTILINE
)

PATTERNS = {
    "tables": re.compile(r"^CREATE TABLE IF NOT EXISTS (\w+)", re.MULTILINE),
    "types": re.compile(r"^\s*CREATE TYPE (\w+) AS ENUM", re.MULTILINE),
    "functions": re.compile(r"^CREATE OR REPLACE FUNCTION (\w+)", re.MULTILINE),
    "views": re.compile(r"^CREATE OR REPLACE VIEW (\w+)", re.MULTILINE),
    "triggers": re.compile(
        r"^\s*CREATE (?:OR REPLACE )?(?:CONSTRAINT )?TRIGGER (\w+)", re.MULTILINE
    ),
}

DB_QUERIES = {
    "tables": "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'",
    "types": """
        SELECT t.typname FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public' AND t.typtype = 'e'
    """,
    "functions": """
        SELECT p.proname FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
    """,
    "views": "SELECT table_name FROM information_schema.views WHERE table_schema = 'public'",
    "triggers": "SELECT DISTINCT trigger_name FROM information_schema.triggers WHERE trigger_schema = 'public'",
}


def parse_expected(sql_text):
    return {
        category: Counter(pattern.findall(sql_text))
        for category, pattern in PATTERNS.items()
    }


def parse_not_null_columns(sql_text):
    return sorted(set(NOT_NULL_PATTERN.findall(sql_text)))


def check_parser_against_baseline(expected, not_null_columns):
    print("=== Parser vs. baseline (ADR 0015 section 2 acceptance test) ===")
    ok = True
    for category, baseline_count in BASELINE.items():
        if category == "not_null_columns":
            parsed_count = len(not_null_columns)
        else:
            parsed_count = sum(expected[category].values())
        match = parsed_count == baseline_count
        ok = ok and match
        status = "OK" if match else "MISMATCH"
        print(f"  {category:10s} baseline={baseline_count:3d} parsed={parsed_count:3d}  [{status}]")
    if not ok:
        print(
            "\nParser disagrees with the manually verified baseline - this is a "
            "parser bug (a missed statement, a bad regex, a miscount), not a "
            "schema surprise. Fix the parser before trusting it against a live "
            "database. Refusing to proceed."
        )
    else:
        print("\nParser counts match the baseline exactly - trusted to proceed.")
    return ok


def check_not_null_columns(not_null_columns, conn):
    all_ok = True
    with conn.cursor() as cur:
        for table, column in not_null_columns:
            cur.execute(
                """
                SELECT is_nullable FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = %s AND column_name = %s
                """,
                (table, column),
            )
            row = cur.fetchone()
            if row is None:
                ok, detail = False, "column not found"
            else:
                ok = row[0] == "NO"
                detail = "NOT NULL" if ok else "still nullable"
            all_ok = all_ok and ok
            status = "PASS" if ok else "FAIL"
            print(f"  [{status}] not_null: {table}.{column} ({detail})")
    return all_ok


def check_database(expected, not_null_columns, conn):
    print("\n=== Live database verification ===")
    all_ok = check_not_null_columns(not_null_columns, conn)
    with conn.cursor() as cur:
        for category, query in DB_QUERIES.items():
            cur.execute(query)
            actual = Counter(row[0] for row in cur.fetchall())
            for name, expected_count in sorted(expected[category].items()):
                actual_count = actual.get(name, 0)
                ok = actual_count >= expected_count
                all_ok = all_ok and ok
                status = "PASS" if ok else "FAIL"
                suffix = f" (expected {expected_count}, found {actual_count})" if expected_count > 1 or not ok else ""
                print(f"  [{status}] {category}: {name}{suffix}")
    return all_ok


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-postgresql_schema.sql>", file=sys.stderr)
        sys.exit(2)

    with open(sys.argv[1]) as f:
        sql_text = f.read()

    expected = parse_expected(sql_text)
    not_null_columns = parse_not_null_columns(sql_text)

    if not check_parser_against_baseline(expected, not_null_columns):
        sys.exit(1)

    conn = psycopg2.connect()
    try:
        if not check_database(expected, not_null_columns, conn):
            print("\nOne or more expected objects are missing from the database.")
            sys.exit(1)
    finally:
        conn.close()

    print("\nAll expected objects verified present. Schema apply confirmed, not assumed.")
    sys.exit(0)


if __name__ == "__main__":
    main()
