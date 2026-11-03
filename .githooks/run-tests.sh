#!/bin/sh
# Runs the external testing repo's test command against this repo.
# Configure with:
#   git config tests.repo "C:/Data/GitProjects/<testing-repo>"
#   git config tests.cmd  "npm test"

MAIN_REPO="$(git rev-parse --show-toplevel)"
TESTS_REPO="$(git config --get tests.repo)"
TESTS_CMD="$(git config --get tests.cmd)"

if [ -z "$TESTS_REPO" ] || [ -z "$TESTS_CMD" ]; then
  echo "BLOCKED: tests.repo / tests.cmd are not configured." >&2
  echo "  git config tests.repo \"C:/Data/GitProjects/<testing-repo>\"" >&2
  echo "  git config tests.cmd  \"<test command>\"" >&2
  exit 1
fi

if [ ! -d "$TESTS_REPO" ]; then
  echo "BLOCKED: testing repo not found at $TESTS_REPO" >&2
  exit 1
fi

echo "Running tests in $TESTS_REPO: $TESTS_CMD"
export MAIN_REPO
(cd "$TESTS_REPO" && sh -c "$TESTS_CMD")
status=$?

if [ $status -ne 0 ]; then
  echo "BLOCKED: tests failed (exit $status). Not merging into main." >&2
  exit $status
fi

echo "Tests passed."
