#!/usr/bin/env bash
set -euo pipefail

# Usage: ./cleanup-orphaned-previews.sh owner/repo1 owner/repo2 ...
# Finds docker compose projects named "preview-*", checks if the corresponding
# PR is still open, and tears down any where the PR is closed or merged.

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 owner/repo1 [owner/repo2 ...]" >&2
  exit 1
fi

REPOS=("$@")
PREVIEWS_DIR="${PREVIEWS_DIR:-/opt/previews}"

log "Starting orphaned preview cleanup"
log "Repos: ${REPOS[*]}"

# Collect all compose projects matching preview-*
projects_json=$(docker compose ls --format json 2>/dev/null || echo "[]")
preview_projects=$(echo "$projects_json" | jq -r '.[].Name | select(startswith("preview-"))')

if [[ -z "$preview_projects" ]]; then
  log "No preview-* compose projects found. Nothing to do."
  exit 0
fi

for project in $preview_projects; do
  # Extract PR number: project name format is preview-<pr-number>
  pr_number="${project#preview-}"

  if [[ -z "$pr_number" || ! "$pr_number" =~ ^[0-9]+$ ]]; then
    log "SKIP $project — could not parse PR number from project name"
    continue
  fi

  pr_is_open=false

  for repo in "${REPOS[@]}"; do
    pr_state=$(gh pr view "$pr_number" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

    if [[ "$pr_state" == "OPEN" ]]; then
      pr_is_open=true
      log "OK $project — PR #$pr_number is still OPEN in $repo"
      break
    fi

    log "FOUND $project — PR #$pr_number state=$pr_state in $repo"
  done

  if [[ "$pr_is_open" == "true" ]]; then
    continue
  fi

  log "TEARDOWN $project — PR #$pr_number is not open in any configured repo"

  if docker compose -p "$project" down --rmi all --remove-orphans; then
    log "TEARDOWN $project — compose stack removed"
  else
    log "WARN $project — compose down failed (stack may already be gone)"
  fi

  project_dir="${PREVIEWS_DIR}/${project}"
  if [[ -d "$project_dir" ]]; then
    rm -rf "$project_dir"
    log "TEARDOWN $project — removed directory $project_dir"
  else
    log "SKIP $project — directory $project_dir does not exist"
  fi
done

log "Cleanup complete"
