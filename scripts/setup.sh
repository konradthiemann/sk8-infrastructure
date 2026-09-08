#!/usr/bin/env bash
# One-time setup for this repository: activates the versioned git hooks,
# creates .env from .env.example and checks that the required tools exist.
# Safe to re-run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

git config core.hooksPath .githooks
echo "git hooks: core.hooksPath = .githooks"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "created .env from .env.example"
fi

missing=0
for tool in git docker psql; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "found: $tool"
  else
    echo "MISSING: $tool" >&2
    missing=1
  fi
done

if docker compose version >/dev/null 2>&1; then
  echo "found: docker compose ($(docker compose version --short))"
else
  echo "MISSING: docker compose plugin" >&2
  missing=1
fi

if command -v shellcheck >/dev/null 2>&1; then
  echo "found: shellcheck"
else
  echo "optional: shellcheck not installed (brew install shellcheck) - checks fall back to the docker image koalaman/shellcheck"
fi

if [ "$missing" -ne 0 ]; then
  echo "some required tools are missing, see above" >&2
  exit 1
fi

echo "setup complete - start the database with: make up"
