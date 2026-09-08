#!/usr/bin/env bash
# Creates the additional local databases next to POSTGRES_DB (sk8_backend).
#
# The postgres image runs everything in /docker-entrypoint-initdb.d once, when
# the data volume is initialised for the first time. The script is still written
# idempotently so it can be re-run manually inside the container:
#   docker compose exec postgres /docker-entrypoint-initdb.d/01-databases.sh
set -euo pipefail

DATABASES=(sk8_docs sk8_backend_test sk8_docs_test)

create_database() {
  local db="$1"
  local exists

  exists="$(psql -v ON_ERROR_STOP=1 -qtA --username "$POSTGRES_USER" --dbname postgres \
    -c "SELECT 1 FROM pg_database WHERE datname = '$db'")"

  if [ "$exists" = "1" ]; then
    echo "database $db already exists"
  else
    psql -v ON_ERROR_STOP=1 -q --username "$POSTGRES_USER" --dbname postgres \
      -c "CREATE DATABASE \"$db\" OWNER \"$POSTGRES_USER\""
    echo "database $db created (owner $POSTGRES_USER)"
  fi
}

for db in "${DATABASES[@]}"; do
  create_database "$db"
done
