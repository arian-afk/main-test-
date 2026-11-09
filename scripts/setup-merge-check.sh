#!/usr/bin/env bash
# Sets up the "tests must pass before merging into main" check, proves it blocks a
# broken merge, then merges ari into main for real. Never pushes.
#
# Usage (from Git Bash):  bash scripts/setup-merge-check.sh

# Checking out main removes this file from the working tree, so run from a temp copy.
if [ -z "${MERGE_CHECK_REEXEC:-}" ]; then
  tmp="$(mktemp)"
  cp "$0" "$tmp"
  MERGE_CHECK_REEXEC=1 MERGE_CHECK_REPO="$(cd "$(dirname "$0")/.." && pwd)" exec bash "$tmp" "$@"
fi

set -euo pipefail

TESTS_REPO="C:/Data/GitProjects/main-test-tests"
WORK_BRANCH="ari"
DEMO_BRANCH="merge-check-demo-broken"

step() { printf '\n==== %s ====\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

main() {
  cd "$MERGE_CHECK_REPO"
  trap 'rm -f "$0"' EXIT

  step "Checking preconditions"
  [ -d "$TESTS_REPO" ] || fail "Test repo not found at $TESTS_REPO"
  git rev-parse --verify -q main >/dev/null || fail "No local 'main' branch"
  git rev-parse --verify -q "$WORK_BRANCH" >/dev/null || fail "No local '$WORK_BRANCH' branch"
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] && fail "A merge is in progress; run 'git merge --abort' first"

  local current
  current="$(git symbolic-ref --short HEAD)"
  if [ "$current" != "$WORK_BRANCH" ]; then
    git diff --quiet && git diff --cached --quiet || fail "Uncommitted changes on '$current'; commit or stash them first"
    git checkout -q "$WORK_BRANCH"
  fi

  local unexpected
  unexpected="$(git status --porcelain | grep -v -e ' \.githooks/' -e ' scripts/' || true)"
  [ -z "$unexpected" ] || fail "Unexpected uncommitted changes on $WORK_BRANCH:
$unexpected"
  echo "OK"

  step "Applying git settings"
  git config core.hooksPath .githooks
  git config branch.main.mergeoptions --no-ff
  git config tests.repo "$TESTS_REPO"
  git config tests.cmd "npm test --silent"
  git config alias.safe-merge '!f() { m="$(git rev-parse --git-path TESTS_FAILED)"; rm -f "$m"; git merge "$@"; s=$?; if [ -f "$m" ]; then rm -f "$m"; git merge --abort; echo "Merge aborted automatically: tests failed, main is unchanged." >&2; fi; return $s; }; f'
  echo "OK"

  step "Committing hook changes on $WORK_BRANCH"
  if [ -n "$(git status --porcelain .githooks)" ]; then
    git add .githooks
    git commit -q -m "Auto-abort support for failed test merges"
    git log --oneline -1
  else
    echo "Nothing to commit"
  fi

  step "Running tests against $WORK_BRANCH"
  sh .githooks/run-tests.sh >/dev/null 2>&1 || fail "Tests fail on $WORK_BRANCH itself; fix them before merging"
  echo "Tests pass"

  step "Demo: merging a branch with a broken multiply() into main"
  git branch -D -q "$DEMO_BRANCH" 2>/dev/null || true
  git checkout -q -b "$DEMO_BRANCH"
  sed -i 's/return a \* b;/return a + b;/' src/calculator.js
  grep -q 'return a + b;' <(sed -n '/function multiply/,/}/p' src/calculator.js) || fail "Could not break multiply() for the demo"
  git commit -q -am "Demo: break multiply"

  git checkout -q main
  local main_before
  main_before="$(git rev-parse HEAD)"
  if git safe-merge "$DEMO_BRANCH" -m "Demo merge (should be blocked)"; then
    fail "Broken merge was NOT blocked; check the hooks"
  fi
  [ "$(git rev-parse HEAD)" = "$main_before" ] || fail "main changed during the blocked merge"
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] && fail "Merge was left in progress"
  echo
  echo "Blocked and auto-aborted as expected; main is unchanged."

  step "Merging $WORK_BRANCH into main for real"
  git safe-merge "$WORK_BRANCH" -m "Merge $WORK_BRANCH into main" || fail "Merge of $WORK_BRANCH was blocked; see test output above"
  git log --oneline -1

  step "Cleaning up"
  git checkout -q "$WORK_BRANCH"
  git branch -D -q "$DEMO_BRANCH"
  echo "Back on $WORK_BRANCH; deleted $DEMO_BRANCH"

  step "Done"
  echo "main now has the hooks, so direct commits to main are refused and merges into main run the tests."
  echo "Nothing was pushed. When ready:  git push origin $WORK_BRANCH main"
}

main "$@"
