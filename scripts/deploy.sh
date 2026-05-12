#!/usr/bin/env bash
set -euo pipefail

# Usage: ./deploy.sh \
#   --project-id <id> \
#   --pr-number <n> \
#   --domain <domain> \
#   --services '<json-array>' \
#   --host <tailscale-ip> \
#   --user <ssh-user> \
#   [--ecr-registry <registry-url>] \
#   [--aws-region <region>]
#
# Deploys a PR preview environment to the home server via SSH.

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

PROJECT_ID=""
PR_NUMBER=""
DOMAIN="changelapse.com"
SERVICES_JSON=""
PREVIEW_HOST=""
PREVIEW_USER=""
ECR_REGISTRY=""
AWS_REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)   PROJECT_ID="$2";    shift 2 ;;
    --pr-number)    PR_NUMBER="$2";     shift 2 ;;
    --domain)       DOMAIN="$2";        shift 2 ;;
    --services)     SERVICES_JSON="$2"; shift 2 ;;
    --host)         PREVIEW_HOST="$2";  shift 2 ;;
    --user)         PREVIEW_USER="$2";  shift 2 ;;
    --ecr-registry) ECR_REGISTRY="$2";  shift 2 ;;
    --aws-region)   AWS_REGION="$2";    shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${PROJECT_ID:?--project-id is required}"
: "${PR_NUMBER:?--pr-number is required}"
: "${SERVICES_JSON:?--services is required}"
: "${PREVIEW_HOST:?--host is required}"
: "${PREVIEW_USER:?--user is required}"

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="preview-${PROJECT_ID}-${PR_NUMBER}"
REMOTE_DIR="/opt/previews/${PROJECT_NAME}"
COMPOSE_FILE="/tmp/${PROJECT_NAME}-docker-compose.yml"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

echo "========================================"
echo "  Deploying preview environment"
echo "  Project : ${PROJECT_ID}"
echo "  PR      : #${PR_NUMBER}"
echo "  URL     : https://${PROJECT_ID}_${PR_NUMBER}.${DOMAIN}"
echo "========================================"

# ---------------------------------------------------------------------------
# Generate compose file locally
# ---------------------------------------------------------------------------

"${SCRIPT_DIR}/generate-compose.sh" \
  --project-id "$PROJECT_ID" \
  --pr-number  "$PR_NUMBER" \
  --domain     "$DOMAIN" \
  --services   "$SERVICES_JSON" \
  --output     "$COMPOSE_FILE"

# ---------------------------------------------------------------------------
# Copy compose file to remote
# ---------------------------------------------------------------------------

# shellcheck disable=SC2029
ssh "${PREVIEW_USER}@${PREVIEW_HOST}" "mkdir -p ${REMOTE_DIR}"
scp "$COMPOSE_FILE" "${PREVIEW_USER}@${PREVIEW_HOST}:${REMOTE_DIR}/docker-compose.yml"

# ---------------------------------------------------------------------------
# Deploy on remote
# ---------------------------------------------------------------------------

# shellcheck disable=SC2029
if [[ -n "$ECR_REGISTRY" ]]; then
  ssh "${PREVIEW_USER}@${PREVIEW_HOST}" \
    "aws ecr get-login-password --region ${AWS_REGION} \
       | docker login --username AWS --password-stdin ${ECR_REGISTRY} \
     && cd ${REMOTE_DIR} \
     && docker compose -p ${PROJECT_NAME} up -d --pull always"
else
  ssh "${PREVIEW_USER}@${PREVIEW_HOST}" \
    "cd ${REMOTE_DIR} && docker compose -p ${PROJECT_NAME} up -d --pull always"
fi

# ---------------------------------------------------------------------------
# Cleanup local temp file
# ---------------------------------------------------------------------------

rm -f "$COMPOSE_FILE"

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------

echo "========================================"
echo "  Preview deployed successfully"
echo "  URL: https://${PROJECT_ID}_${PR_NUMBER}.${DOMAIN}"
echo "========================================"
