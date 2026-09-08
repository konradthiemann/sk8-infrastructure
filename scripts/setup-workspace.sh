#!/usr/bin/env bash
# Prepares the multi-repo workspace (ADR-001):
#   - clones every missing sk8-* repository next to this one via SSH
#   - activates the versioned git hooks (core.hooksPath=.githooks) in each repo
#
# Run from anywhere; the workspace root is the parent directory of this repo.
# Override the GitHub owner with SK8_GITHUB_OWNER. Safe to re-run.
set -euo pipefail

REPOS=(sk8-backend sk8-skate sk8-nutrition sk8-habits sk8-docs sk8-infrastructure)
GITHUB_OWNER="${SK8_GITHUB_OWNER:-konradthiemann}"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$(dirname "$repo_dir")"

echo "workspace root: $workspace_root"
echo

for repo in "${REPOS[@]}"; do
  target="$workspace_root/$repo"

  if [ -d "$target/.git" ]; then
    echo "[$repo] present"
  elif [ -e "$target" ]; then
    echo "[$repo] WARNING: $target exists but is not a git repository - skipping" >&2
    continue
  else
    echo "[$repo] cloning git@github.com:$GITHUB_OWNER/$repo.git"
    git clone "git@github.com:$GITHUB_OWNER/$repo.git" "$target"
  fi

  if [ -d "$target/.githooks" ]; then
    git -C "$target" config core.hooksPath .githooks
    echo "[$repo] hooks: core.hooksPath = .githooks"
  else
    echo "[$repo] hooks: no .githooks directory (nothing to activate)"
  fi
done

echo
echo "workspace ready"
