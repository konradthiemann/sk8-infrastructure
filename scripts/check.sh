#!/usr/bin/env bash
# Runs every static validation of this repository:
#   - docker compose --profile full config -q (validates every service, not only the default profile)
#   - bash -n on all shell scripts and hooks
#   - shellcheck: local binary if installed, otherwise the official Docker image;
#     CHECK_REQUIRE_SHELLCHECK=1 turns "neither available" into a failure (CI)
#
# Used by .githooks/pre-commit, `make check` and the CI workflow so that all
# three stay identical.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SHELLCHECK_IMAGE=koalaman/shellcheck:stable

status=0
shell_files=(scripts/*.sh postgres/init/*.sh .githooks/*)

echo "==> docker compose --profile full config -q"
if docker compose --profile full config -q; then
  echo "    ok"
else
  echo "    FAILED"
  status=1
fi

echo "==> bash -n"
for file in "${shell_files[@]}"; do
  if bash -n "$file"; then
    echo "    ok    $file"
  else
    echo "    FAIL  $file"
    status=1
  fi
done

echo "==> shellcheck"
shellcheck_mode=none
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_mode=local
elif docker info >/dev/null 2>&1; then
  shellcheck_mode=docker
fi

run_shellcheck() {
  case "$shellcheck_mode" in
    local) shellcheck "$@" ;;
    docker) docker run --rm -v "$PWD:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" "$@" ;;
  esac
}

case "$shellcheck_mode" in
  local|docker)
    [ "$shellcheck_mode" = docker ] && echo "    (not installed locally, using $SHELLCHECK_IMAGE)"
    if run_shellcheck "${shell_files[@]}"; then
      echo "    ok"
    else
      echo "    FAILED"
      status=1
    fi
    ;;
  none)
    if [ "${CHECK_REQUIRE_SHELLCHECK:-0}" = "1" ]; then
      echo "    FAILED (shellcheck required but neither shellcheck nor docker is available)"
      status=1
    else
      echo "    skipped (install shellcheck or start docker)"
    fi
    ;;
esac

exit "$status"
