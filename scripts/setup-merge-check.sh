#!/usr/bin/env bash
# Sets up the "tests must pass before merging into main" gate, proves it blocks a
# broken merge, then merges ari into the protected branch for real. Never pushes.
# The protected branch comes from .githooks/gate.conf (PROTECTED_BRANCH).
#
# Usage (from Git Bash):  bash scripts/setup-merge-check.sh

# Checking out the protected branch can remove this file from the working tree, so run from a temp copy.
if [ -z "${MERGE_CHECK_REEXEC:-}" ]; then
  tmp="$(mktemp)"
  cp "$0" "$tmp"
  MERGE_CHECK_REEXEC=1 MERGE_CHECK_REPO="$(cd "$(dirname "$0")/.." && pwd)" exec bash "$tmp" "$@"
fi

set -euo pipefail

WORK_BRANCH="ari"
DEMO_BRANCH="merge-check-demo-broken"

step() { printf '\n==== %s ====\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

main() {
  cd "$MERGE_CHECK_REPO"
  trap 'rm -f "$0"' EXIT

  step "Checking preconditions"
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

  # shellcheck source=../.githooks/gate.conf
  . .githooks/gate.conf
  local target="$PROTECTED_BRANCH"
  git rev-parse --verify -q "$target" >/dev/null || fail "No local '$target' branch"
  [ -d "$TESTS_LOCAL_DIR" ] || fail "Test repo not found at $TESTS_LOCAL_DIR"
  docker info >/dev/null 2>&1 || fail "Docker is not running; start Docker Desktop first"
  echo "OK (protected branch: $target)"

  step "Applying git settings"
  git config core.hooksPath .githooks
  git config "branch.$target.mergeoptions" --no-ff
  git config --unset tests.repo || true
  git config --unset tests.cmd || true
  git config alias.safe-merge '!f() { m="$(git rev-parse --git-path TESTS_FAILED)"; rm -f "$m"; git merge "$@"; s=$?; if [ -f "$m" ]; then rm -f "$m"; git merge --abort; echo "Merge aborted automatically: tests failed, the branch is unchanged." >&2; fi; return $s; }; f'
  echo "OK"

  step "Committing hook changes on $WORK_BRANCH"
  if [ -n "$(git status --porcelain .githooks)" ]; then
    git add .githooks
    git commit -q -m "Update merge gate hooks"
    git log --oneline -1
  else
    echo "Nothing to commit"
  fi

  step "Running the gate against $WORK_BRANCH"
  bash .githooks/run-gate.sh --all >/dev/null 2>&1 || fail "Gate fails on $WORK_BRANCH itself; run 'bash .githooks/run-gate.sh --all' to see why"
  echo "Tests pass"

  step "Demo: merging a branch where /items returns only two rows into $target"
  git branch -D -q "$DEMO_BRANCH" 2>/dev/null || true
  git checkout -q -b "$DEMO_BRANCH"
  sed -i 's/ORDER BY id"/ORDER BY id LIMIT 2"/' services/example-api/src/server.js
  grep -q 'LIMIT 2' services/example-api/src/server.js || fail "Could not break /items for the demo"
  git commit -q -am "Demo: break /items"

  git checkout -q "$target"
  local target_before
  target_before="$(git rev-parse HEAD)"
  if git safe-merge "$DEMO_BRANCH" -m "Demo merge (should be blocked)"; then
    fail "Broken merge was NOT blocked; check the hooks"
  fi
  [ "$(git rev-parse HEAD)" = "$target_before" ] || fail "$target changed during the blocked merge"
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] && fail "Merge was left in progress"
  echo
  echo "Blocked and auto-aborted as expected; $target is unchanged."

  step "Merging $WORK_BRANCH into $target for real"
  git safe-merge "$WORK_BRANCH" -m "Merge $WORK_BRANCH into $target" || fail "Merge of $WORK_BRANCH was blocked; see test output above"
  git log --oneline -1

  step "Cleaning up"
  git checkout -q "$WORK_BRANCH"
  git branch -D -q "$DEMO_BRANCH"
  echo "Back on $WORK_BRANCH; deleted $DEMO_BRANCH"

  step "Done"
  echo "$target now has the gate: direct commits are refused, and merges that touch services/ or src/ run the tests."
  echo "Nothing was pushed. When ready:  git push origin $WORK_BRANCH $target"
}

main "$@"
