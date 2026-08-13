"""
Parses schemas/db/postgresql_schema.sql for every object it declares
(tables, enum types, functions, views, triggers), cross-checks the parser's
own counts against a manually verified baseline (ADR 0015 section 2) before
trusting it, then confirms each parsed object actually exists in the target
database. Exits non-zero if the parser disagrees with the baseline, or if
any expected object is missing from the database.

Usage: verify_schema.py <path-to-postgresql_schema.sql>
Connection: standard libpq environment variables (PGHOST, PGUSER, PGPASSWORD,
PGDATABASE, PGSSLMODE, ...).
"""
import re
import sys
from collections import Counter

import psycopg2

# Manually verified snapshot (ADR 0015 section 2's acceptance-test discipline;
# counts updated for ADR 0016's policy_vehicles/policy_drivers addition). This
# is the acceptance test for the parser itself - if the parser's counts don't
# match this, that's a parser bug to fix, not a schema surprise, and the
# parser is not trusted against a live database until it does. Updated by
# hand each time the schema file changes - the object *names* are parsed
# automatically, but this snapshot is a fact about the file's current state,
# not something the parser can derive about itself.
BASELINE = {
    "tables": 24,
    "types": 16,
    "functions": 16,
    "views": 6,
    "triggers": 14,
}

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


def check_parser_against_baseline(expected):
    print("=== Parser vs. baseline (ADR 0015 section 2 acceptance test) ===")
    ok = True
    for category, baseline_count in BASELINE.items():
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


def check_database(expected, conn):
    print("\n=== Live database verification ===")
    all_ok = True
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

    if not check_parser_against_baseline(expected):
        sys.exit(1)

    conn = psycopg2.connect()
    try:
        if not check_database(expected, conn):
            print("\nOne or more expected objects are missing from the database.")
            sys.exit(1)
    finally:
        conn.close()

    print("\nAll expected objects verified present. Schema apply confirmed, not assumed.")
    sys.exit(0)


if __name__ == "__main__":
    main()
