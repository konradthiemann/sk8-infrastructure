#!/usr/bin/env bash
# Starts the local development stack.
#
#   scripts/dev-up.sh          PostgreSQL only (default)
#   scripts/dev-up.sh --full   PostgreSQL + backend, docs and the three frontends (built from ../sk8-*)
#
# Waits until PostgreSQL reports healthy and prints the connection URLs.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONTAINER=sk8-postgres
DB_USER=sk8
DB_PASSWORD=sk8

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

full=0
case "${1:-}" in
  "") ;;
  --full) full=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

# Host port: environment wins over .env, default 5432 (ADR-005).
host_port="${POSTGRES_PORT:-}"
if [ -z "$host_port" ] && [ -f .env ]; then
  host_port="$(grep -E '^POSTGRES_PORT=' .env | tail -n 1 | cut -d= -f2- || true)"
fi
host_port="${host_port:-5432}"

container_running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ]
}

# Friendly error when another PostgreSQL already occupies the host port.
if ! container_running && command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$host_port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $host_port is already in use on this machine." >&2
    echo "Either stop the other service or set POSTGRES_PORT in .env (see .env.example), e.g.:" >&2
    echo "  echo 'POSTGRES_PORT=5433' > .env" >&2
    exit 1
  fi
fi

if [ "$full" -eq 1 ]; then
  docker compose --profile full up -d --build
else
  docker compose up -d postgres
fi

printf 'waiting for %s to become healthy ' "$CONTAINER"
health=unknown
for _ in $(seq 1 60); do
  health="$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo unknown)"
  if [ "$health" = "healthy" ]; then
    break
  fi
  printf '.'
  sleep 1
done
echo

if [ "$health" != "healthy" ]; then
  echo "PostgreSQL did not become healthy (status: $health). Logs:" >&2
  docker compose logs --tail 30 postgres >&2
  exit 1
fi

base="postgresql://${DB_USER}:${DB_PASSWORD}@127.0.0.1:${host_port}"
echo "PostgreSQL 16 is ready on 127.0.0.1:${host_port}"
echo
echo "  sk8_backend       ${base}/sk8_backend?serverVersion=16&charset=utf8"
echo "  sk8_docs          ${base}/sk8_docs?serverVersion=16&charset=utf8"
echo "  sk8_backend_test  ${base}/sk8_backend_test?serverVersion=16&charset=utf8"
echo "  sk8_docs_test     ${base}/sk8_docs_test?serverVersion=16&charset=utf8"

if [ "$full" -eq 1 ]; then
  echo
  echo "Services:"
  echo "  backend    http://localhost:8000"
  echo "  docs       http://localhost:8001"
  echo "  skate      http://localhost:5173"
  echo "  nutrition  http://localhost:5174"
  echo "  habits     http://localhost:5175"
fi
