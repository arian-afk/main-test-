#!/usr/bin/env bash
# Starts the configured services against a throwaway Postgres, then runs the pinned
# external test suite against them. Exit 0 = allowed, non-zero = blocked.
#
# Usage (from inside the repo):
#   git diff --name-only A B | bash .githooks/run-gate.sh   # gate only if gated paths changed
#   bash .githooks/run-gate.sh --all                         # always run

set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gate.conf
. "$HOOKS_DIR/gate.conf"

REPO="$(git rev-parse --show-toplevel)" || { echo "BLOCKED: not inside a git repo" >&2; exit 1; }
GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
cd "$REPO" || exit 1

START_TS=$(date +%s)
LOG_DIR="$GIT_COMMON_DIR/gate-logs/$(date +%Y%m%d-%H%M%S)"
CACHE_DIR="$GIT_COMMON_DIR/gate-cache"

say() { echo "[gate] $*"; }
block() { echo "BLOCKED: $*" >&2; exit 1; }
elapsed() { echo "$(( $(date +%s) - START_TS ))s"; }

# ---- 1. Decide whether this change needs the gate -------------------------------

if [ "${1:-}" = "--all" ]; then
  needs_gate=1
else
  needs_gate=0
  while IFS= read -r f; do
    f="${f%$'\r'}"
    [ -z "$f" ] && continue
    [ "$f" = "$PIN_FILE" ] && needs_gate=1
    for p in $TRIGGER_PATHS; do
      case "$f" in "$p"*) needs_gate=1 ;; esac
    done
  done
fi

if [ "$needs_gate" -ne 1 ]; then
  say "No gated paths changed; skipping tests."
  exit 0
fi

# ---- 2. Read the test-repo pin ------------------------------------------------------

[ -f "$PIN_FILE" ] || block "pin file $PIN_FILE not found in $REPO"
pin_get() { sed -n "s/^TESTS_$1=//p" "$PIN_FILE" | tr -d '\r' | tail -n 1; }

if [ "$(pin_get ENABLED)" != "true" ]; then
  say "Tests disabled in $PIN_FILE; skipping."
  exit 0
fi
PIN_REF="$(pin_get REF)"
PIN_TARGET="$(pin_get TARGET)"
[ -n "$PIN_REF" ] || block "TESTS_REF missing in $PIN_FILE"
[ "${#PIN_REF}" -ge 7 ] || block "TESTS_REF looks too short: $PIN_REF"

# ---- 3. Resolve the test repo at the pinned commit -----------------------------------

install_deps() {
  if [ -f yarn.lock ]; then yarn install --immutable
  elif [ -f package-lock.json ]; then npm ci --no-fund --no-audit
  elif [ -f package.json ]; then npm install --no-fund --no-audit
  fi
}

# Hooks run with GIT_DIR/GIT_INDEX_FILE etc. pointing at this repo; they must not leak into the test repo.
tests_git() {
  env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_PREFIX -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR git -C "$TESTS_LOCAL_DIR" "$@"
}

[ -e "$TESTS_LOCAL_DIR/.git" ] || block "test repo not found at $TESTS_LOCAL_DIR"

full_ref="$(tests_git rev-parse --verify -q "$PIN_REF^{commit}")"
if [ -z "$full_ref" ]; then
  tests_git fetch -q origin "$PIN_REF" 2>/dev/null
  full_ref="$(tests_git rev-parse --verify -q "$PIN_REF^{commit}")" ||
    block "pinned test commit $PIN_REF not found in $TESTS_LOCAL_DIR (fetch it or fix $PIN_FILE)"
fi

if [ "$(tests_git rev-parse HEAD)" = "$full_ref" ]; then
  TESTS_DIR="$TESTS_LOCAL_DIR"
  say "Tests: $TESTS_DIR (local checkout is at the pinned commit ${full_ref:0:7})"
else
  TESTS_DIR="$CACHE_DIR/tests-$full_ref"
  if [ ! -d "$TESTS_DIR" ]; then
    say "Creating test worktree for pinned commit ${full_ref:0:7}"
    mkdir -p "$CACHE_DIR"
    tests_git worktree add -q --detach "$TESTS_DIR" "$full_ref" ||
      block "could not create worktree at $TESTS_DIR"
    if ! (cd "$TESTS_DIR" && install_deps); then
      tests_git worktree remove --force "$TESTS_DIR" 2>/dev/null
      block "installing test dependencies failed"
    fi
  fi
  say "Tests: $TESTS_DIR (worktree at pinned commit ${full_ref:0:7})"
fi

if [ -z "$PIN_TARGET" ] || [ "$PIN_TARGET" = "." ]; then
  TESTS_WORKDIR="$TESTS_DIR"
else
  TESTS_WORKDIR="$TESTS_DIR/$PIN_TARGET"
fi
[ -f "$TESTS_WORKDIR/package.json" ] || block "no package.json in test folder $TESTS_WORKDIR"

# ---- 4. Docker --------------------------------------------------------------------

docker info >/dev/null 2>&1 || block "Docker is not running; start Docker Desktop and retry."

# ---- 5. Load recipes and check ports -------------------------------------------------

declare -A SVC_DIR SVC_PORT SVC_HEALTH

load_recipe() {
  local recipe="$HOOKS_DIR/recipes/$1.sh"
  [ -f "$recipe" ] || block "missing recipe $recipe"
  unset SERVICE_DIR SERVICE_PORT HEALTH_PATH
  unset -f recipe_env recipe_prepare recipe_start
  # shellcheck disable=SC1090
  . "$recipe"
  [ -n "${SERVICE_DIR:-}" ] && [ -n "${SERVICE_PORT:-}" ] ||
    block "recipe $1 must set SERVICE_DIR and SERVICE_PORT"
}

for svc in $SERVICES; do
  load_recipe "$svc"
  SVC_DIR[$svc]="$SERVICE_DIR"
  SVC_PORT[$svc]="$SERVICE_PORT"
  SVC_HEALTH[$svc]="${HEALTH_PATH:-/health}"
done
[ -n "${SVC_PORT[$BASE_URL_SERVICE]:-}" ] || block "BASE_URL_SERVICE=$BASE_URL_SERVICE is not in SERVICES"

port_in_use() {
  netstat -ano -p tcp 2>/dev/null | awk '/LISTENING/ {print $2}' | grep -qE "[:.]$1\$"
}
for port in "$PG_PORT" "${SVC_PORT[@]}"; do
  port_in_use "$port" && block "port $port is already in use; free it or change it in gate.conf / the recipe"
done

# ---- 6. Cleanup trap ------------------------------------------------------------------

PIDS=()
PG_STARTED=0
SUCCEEDED=0
DIRTY_BEFORE="$(git diff --name-only)"

kill_tree() {
  local pid="$1" winpid
  winpid="$(cat "/proc/$pid/winpid" 2>/dev/null)"
  if [ -n "$winpid" ]; then
    taskkill //F //T //PID "$winpid" >/dev/null 2>&1 || kill "$pid" 2>/dev/null
  else
    kill "$pid" 2>/dev/null
  fi
}

cleanup() {
  local pid f
  for pid in "${PIDS[@]}"; do kill_tree "$pid"; done
  [ "$PG_STARTED" -eq 1 ] && docker rm -f "$PG_CONTAINER" >/dev/null 2>&1
  # Tracked files touched by installs/builds would block `git merge --abort`; restore them from the index.
  git diff --name-only | while IFS= read -r f; do
    printf '%s\n' "$DIRTY_BEFORE" | grep -qxF "$f" && continue
    git checkout -q -- "$f" && say "Restored $f (modified during the gate run)"
  done
  if [ "$SUCCEEDED" -ne 1 ]; then
    for f in "$LOG_DIR"/*.log; do
      [ -s "$f" ] || continue
      echo "---- last 40 lines of $f" >&2
      tail -n 40 "$f" >&2
    done
  fi
}
trap cleanup EXIT

mkdir -p "$LOG_DIR"

# ---- 7. Throwaway Postgres ------------------------------------------------------------

say "Starting $PG_IMAGE as $PG_CONTAINER on port $PG_PORT"
docker rm -f "$PG_CONTAINER" >/dev/null 2>&1
docker run -d --rm --name "$PG_CONTAINER" \
  -e POSTGRES_USER=user -e POSTGRES_PASSWORD=password -e POSTGRES_DB="$PG_DB" \
  -p "$PG_PORT:5432" "$PG_IMAGE" >/dev/null || block "could not start $PG_IMAGE"
PG_STARTED=1

pg_ready=0
for _ in $(seq 1 60); do
  # -h 127.0.0.1: the image's init server only listens on the socket, so TCP means truly ready.
  if docker exec "$PG_CONTAINER" pg_isready -q -h 127.0.0.1 -U user -d "$PG_DB" >/dev/null 2>&1; then
    pg_ready=1; break
  fi
  sleep 1
done
[ "$pg_ready" -eq 1 ] || block "Postgres did not become ready within 60s"

# ---- 8. Prepare and start services ----------------------------------------------------

check_db_urls() {
  local name value
  for name in $(compgen -e); do
    case "$name" in *_DB) ;; *) continue ;; esac
    value="${!name}"
    case "$value" in postgres://*|postgresql://*) ;; *) continue ;; esac
    case "$value" in
      *":$PG_PORT/"*) ;;
      *) block "$name points at ${value%%@*}@... (not the throwaway database on port $PG_PORT)" ;;
    esac
  done
}

wait_for_health() {
  local svc="$1" pid="$2" url="http://127.0.0.1:${SVC_PORT[$1]}${SVC_HEALTH[$1]}"
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SEC ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    kill -0 "$pid" 2>/dev/null || block "$svc exited during startup"
    curl -fsS -m 2 "$url" >/dev/null 2>&1 && { say "$svc is healthy at $url"; return 0; }
    sleep 1
  done
  block "$svc did not become healthy within ${HEALTH_TIMEOUT_SEC}s ($url)"
}

for svc in $SERVICES; do
  load_recipe "$svc"
  recipe_env
  check_db_urls

  say "Preparing $svc"
  (cd "$REPO/$SERVICE_DIR" && recipe_prepare) >"$LOG_DIR/$svc-prepare.log" 2>&1 ||
    block "preparing $svc failed"

  say "Starting $svc on port $SERVICE_PORT"
  (cd "$REPO/$SERVICE_DIR" && recipe_start) >"$LOG_DIR/$svc.log" 2>&1 &
  PIDS+=("$!")
  wait_for_health "$svc" "$!"
done

# ---- 9. Run the tests -----------------------------------------------------------------

base_url="http://127.0.0.1:${SVC_PORT[$BASE_URL_SERVICE]}"
export MAIN_REPO="$REPO"
say "Running '$TEST_CMD' in $TESTS_WORKDIR with $BASE_URL_VAR=$base_url"
if ! (cd "$TESTS_WORKDIR" && env "$BASE_URL_VAR=$base_url" bash -c "$TEST_CMD"); then
  block "tests failed after $(elapsed). Not merging into $PROTECTED_BRANCH."
fi

# ---- 10. Done -------------------------------------------------------------------------

SUCCEEDED=1
echo "Tests passed. ($(elapsed))"
