#!/bin/bash
# Runs the behavioural test suites in tests/ against the database
# apply-and-verify-schema.sh just applied to. ADR 0022.
#
# Each suite is a .sql file that reproduces the failure modes one ADR closed
# and asserts the current behaviour, wrapped in BEGIN ... ROLLBACK so nothing
# is ever committed - the pattern every ADR since 0017 used by hand. psql runs
# with ON_ERROR_STOP=1, so an assertion that RAISEs stops that file immediately
# with a non-zero exit and the message in the log.
#
# Every file is run even after one fails; the summary at the end reports all of
# them, because "the first thing that broke" is rarely the whole story.
#
# Usage:
#   scripts/run-tests.sh                 # every tests/*.sql
#   scripts/run-tests.sh tests/0017_*.sql   # one file, for local iteration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"

if [[ $# -gt 0 ]]; then
  TEST_FILES=("$@")
else
  # Sorted so the run order is the ADR order, and so a failure is reported at
  # a stable position rather than wherever the filesystem happened to put it.
  mapfile -t TEST_FILES < <(find "$TESTS_DIR" -maxdepth 1 -name '*.sql' -type f | sort)
fi

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
  echo "No test files found in $TESTS_DIR - nothing to run." >&2
  echo "This is treated as a failure: a silently empty test run looks identical" >&2
  echo "to a passing one in a CI log, which is the failure mode worth avoiding." >&2
  exit 1
fi

# Static safety check, applied before any file is executed.
#
# The suites' whole safety property is that they never commit: they run against
# luxauto-pg itself (ADR 0022 names that as the open item), so a file that
# committed would leave test rows in a production table - and on the
# append-only tables those rows could not then be deleted. This is a cheap net
# against a future suite being written without that discipline, checked rather
# than trusted.
#
# The patterns are line-anchored on purpose: they look for transaction control
# at the psql level, so a plpgsql `BEGIN` opening a block body does not satisfy
# the BEGIN requirement, and the word "committed" in a comment does not trip
# the COMMIT check.
safety_check() {
  local file="$1" problem=""

  if ! grep -qE '^[[:space:]]*BEGIN[[:space:]]*;' "$file"; then
    problem="no top-level 'BEGIN;'"
  elif ! grep -qE '^[[:space:]]*ROLLBACK[[:space:]]*;' "$file"; then
    problem="no top-level 'ROLLBACK;'"
  elif grep -qE '^[[:space:]]*COMMIT[[:space:]]*;' "$file"; then
    problem="contains a bare 'COMMIT;' - suites must never commit"
  fi

  if [[ -n "$problem" ]]; then
    echo "  REFUSED: $problem"
    return 1
  fi
  return 0
}

# shellcheck source=lib/fetch-pg-credentials.sh
source "$SCRIPT_DIR/lib/fetch-pg-credentials.sh"

echo "=== Running ${#TEST_FILES[@]} test suite(s) against $PGDATABASE@$PGHOST ==="
echo ""

PASSED=()
FAILED=()

for file in "${TEST_FILES[@]}"; do
  name="$(basename "$file")"
  echo "--- $name ---"

  if [[ ! -f "$file" ]]; then
    echo "  REFUSED: no such file"
    FAILED+=("$name (missing)")
    echo ""
    continue
  fi

  if ! safety_check "$file"; then
    FAILED+=("$name (safety check)")
    echo ""
    continue
  fi

  # Not `set -e`-fatal: every suite runs even after one fails.
  if psql -v ON_ERROR_STOP=1 -f "$file"; then
    echo "  PASS: $name"
    PASSED+=("$name")
  else
    echo "  FAIL: $name (psql exited non-zero - see the error above)"
    FAILED+=("$name")
  fi
  echo ""
done

echo "=== Summary ==="
for name in "${PASSED[@]:-}"; do
  [[ -n "$name" ]] && echo "  PASS  $name"
done
for name in "${FAILED[@]:-}"; do
  [[ -n "$name" ]] && echo "  FAIL  $name"
done

echo ""
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "${#FAILED[@]} of ${#TEST_FILES[@]} suite(s) FAILED."
  exit 1
fi

echo "All ${#TEST_FILES[@]} suite(s) passed. Nothing was committed."
exit 0
