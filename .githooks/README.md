# Merge gate

Blocks merges into `main` (and pushes of `main`) unless the pinned tests in
`main-test-tests` pass against a freshly started `services/example-api` backed
by a throwaway Postgres container.

## Setup (once per clone)

```bash
bash scripts/setup-merge-check.sh
```

This sets `core.hooksPath=.githooks`, forces `--no-ff` merges into the protected
branch, adds the `git safe-merge` alias, and runs a blocked/allowed merge demo.
Docker Desktop must be running.

## Daily use

```bash
git checkout main
git safe-merge ari      # aborts automatically if the tests fail
```

Run the gate by hand at any time: `bash .githooks/run-gate.sh --all`.

## What triggers it

- `pre-merge-commit`: merges into `PROTECTED_BRANCH` whose changes touch `TRIGGER_PATHS` or `PIN_FILE`.
- `pre-commit`: refuses direct commits on `PROTECTED_BRANCH`, and runs the gate when finishing a merge after resolving conflicts.
- `pre-push`: pushing `PROTECTED_BRANCH` runs the gate against the exact commit being pushed.

Merges that don't touch gated paths skip the tests.

## Files

| File | Purpose |
|---|---|
| `gate.conf` | Branch, ports, Postgres image, trigger paths, test command |
| `recipes/<service>.sh` | How to set env, prepare (install, seed), and start one service |
| `run-gate.sh` | Postgres + services + pinned tests, with cleanup on exit |
| `../services/example-api/test.env` | `TESTS_REF`: the `main-test-tests` commit to run |

Logs from each run: `.git/gate-logs/`. Worktrees for non-current test pins: `.git/gate-cache/`.

## Updating the tests

Commit in `main-test-tests` and push it to GitHub, then put the new SHA in
`services/example-api/test.env` as `TESTS_REF` and commit that on `ari`.

## GitHub enforcement

`.github/workflows/merge-gate.yml` runs the same check on GitHub for every pull
request into `main` (check name `run-external-tests`), using `TESTS_GITHUB_REPOSITORY`
from the pin file. A branch ruleset on `main` that requires that check is what actually
blocks merges on GitHub. While `main-test-tests` is private, the workflow reads it
with the `TESTS_REPO_DEPLOY_KEY` secret (a read-only deploy key on that repo).
