#!/usr/bin/env bash
set -euo pipefail

# Usage: ./teardown.sh \
#   --project-id <id> \
#   --pr-number <n> \
#   --host <tailscale-ip> \
#   --user <ssh-user>
#
# Tears down a PR preview environment on the home server via SSH.

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

PROJECT_ID=""
PR_NUMBER=""
PREVIEW_HOST=""
PREVIEW_USER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="$2";   shift 2 ;;
    --pr-number)  PR_NUMBER="$2";    shift 2 ;;
    --host)       PREVIEW_HOST="$2"; shift 2 ;;
    --user)       PREVIEW_USER="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${PROJECT_ID:?--project-id is required}"
: "${PR_NUMBER:?--pr-number is required}"
: "${PREVIEW_HOST:?--host is required}"
: "${PREVIEW_USER:?--user is required}"

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------

PROJECT_NAME="preview-${PROJECT_ID}-${PR_NUMBER}"
REMOTE_DIR="/opt/previews/${PROJECT_NAME}"

# ---------------------------------------------------------------------------
# Teardown on remote
# ---------------------------------------------------------------------------

echo "========================================"
echo "  Tearing down preview environment"
echo "  Project : ${PROJECT_ID}"
echo "  PR      : #${PR_NUMBER}"
echo "========================================"

# shellcheck disable=SC2029
ssh "${PREVIEW_USER}@${PREVIEW_HOST}" \
  "cd ${REMOTE_DIR} 2>/dev/null \
     && docker compose -p ${PROJECT_NAME} down --rmi all --remove-orphans \
     || true \
   ; rm -rf ${REMOTE_DIR}" \
  || true

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------

echo "========================================"
echo "  Preview environment torn down"
echo "  ${PROJECT_NAME}"
echo "========================================"
