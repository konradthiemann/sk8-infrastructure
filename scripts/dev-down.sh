#!/usr/bin/env bash
# Stops the local development stack (all compose profiles).
#
#   scripts/dev-down.sh            stop and remove containers, keep the database volume
#   scripts/dev-down.sh --volumes  additionally delete the PostgreSQL volume (asks for confirmation)
#   scripts/dev-down.sh --volumes --yes   ... without asking
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() {
  sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

remove_volumes=0
assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --volumes|-v) remove_volumes=1 ;;
    --yes|-y) assume_yes=1 ;;
    --full) ;; # accepted for symmetry with dev-up.sh; down always covers every profile
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$remove_volumes" -eq 1 ] && [ "$assume_yes" -ne 1 ]; then
  echo "This deletes the PostgreSQL volume and ALL local data (sk8_backend, sk8_docs, sk8_backend_test, sk8_docs_test)."
  read -r -p "Continue? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "aborted"; exit 1 ;;
  esac
fi

if [ "$remove_volumes" -eq 1 ]; then
  docker compose --profile full down --volumes --remove-orphans
  echo "stack stopped, database volume removed"
else
  docker compose --profile full down --remove-orphans
  echo "stack stopped, database volume kept"
fi
