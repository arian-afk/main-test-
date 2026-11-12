# Recipe for services/example-api. Sourced by run-gate.sh; PG_PORT and PG_DB come from gate.conf.

SERVICE_DIR=services/example-api
SERVICE_PORT=4201
HEALTH_PATH=/health

recipe_env() {
  export EXAMPLE_API_DB="postgresql://user:password@127.0.0.1:$PG_PORT/$PG_DB"
}

# Runs inside SERVICE_DIR. Must not modify tracked files (npm ci never rewrites the lockfile).
recipe_prepare() {
  npm ci --no-fund --no-audit &&
    npm run --silent db:setup
}

# Runs inside SERVICE_DIR. Must exec so the background PID is the server itself.
recipe_start() {
  PORT="$SERVICE_PORT" exec node src/server.js
}
