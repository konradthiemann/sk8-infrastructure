#!/usr/bin/env bash
# Creates the application databases on a PostgreSQL instance (Railway, ADR-005).
#
#   scripts/db-bootstrap.sh <ADMIN_DATABASE_URL>
#   DATABASE_URL=postgresql://... scripts/db-bootstrap.sh
#
# The admin URL is the DATABASE_PUBLIC_URL of the Railway Postgres service
# (or any URL with permission to CREATE DATABASE). The script creates
# sk8_backend and sk8_docs if they do not exist yet and prints the derived
# connection URLs with the password masked. Safe to re-run.
set -euo pipefail

DATABASES=(sk8_backend sk8_docs)

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

admin_url="${1:-${DATABASE_URL:-}}"
if [ -z "$admin_url" ]; then
  usage >&2
  exit 2
fi

command -v psql >/dev/null 2>&1 || die "psql not found (brew install libpq && brew link --force libpq)"

# postgres[ql]://user[:password]@host[:port][/dbname][?query]
url_re='^postgres(ql)?://([^:/@]+)(:[^@]*)?@([^/?]+)(/[^?]*)?(\?.*)?$'
if [[ ! "$admin_url" =~ $url_re ]]; then
  die "argument is not a PostgreSQL connection URL"
fi
db_user="${BASH_REMATCH[2]}"
host_port="${BASH_REMATCH[4]}"

psql_admin() {
  PGCONNECT_TIMEOUT=15 psql "$admin_url" -v ON_ERROR_STOP=1 -qtA "$@"
}

echo "connecting to postgresql://${db_user}:****@${host_port} ..."
server_version_num="$(psql_admin -c 'SHOW server_version_num' | tr -d '[:space:]')"
[ -n "$server_version_num" ] || die "could not read server version (connection failed?)"
server_major=$((server_version_num / 10000))
echo "server version: PostgreSQL ${server_major}"
echo

for db in "${DATABASES[@]}"; do
  exists="$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname = '$db'" | tr -d '[:space:]')"
  if [ "$exists" = "1" ]; then
    echo "  $db: exists"
  else
    psql_admin -c "CREATE DATABASE \"$db\"" >/dev/null
    echo "  $db: created"
  fi
done

suffix="serverVersion=${server_major}&charset=utf8"

echo
echo "Connection URLs (password masked - take it from the Postgres service variable PGPASSWORD):"
for db in "${DATABASES[@]}"; do
  echo "  postgresql://${db_user}:****@${host_port}/${db}?${suffix}"
done

echo
echo "Recommended: use Railway reference variables instead of copying secrets"
echo "(service name 'postgres' must match the Railway service exactly):"
echo "  backend  DATABASE_URL=postgresql://\${{postgres.PGUSER}}:\${{postgres.PGPASSWORD}}@\${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_backend?${suffix}"
echo "  docs     DATABASE_URL=postgresql://\${{postgres.PGUSER}}:\${{postgres.PGPASSWORD}}@\${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_docs?${suffix}"
