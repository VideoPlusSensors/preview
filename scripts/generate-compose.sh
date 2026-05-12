#!/usr/bin/env bash
set -euo pipefail

# Usage: ./generate-compose.sh \
#   --project-id <id> \
#   --pr-number <n> \
#   --domain <domain> \
#   --services '<json-array>' \
#   --output <path>
#
# Generates a docker-compose.yml with Traefik labels for a PR preview environment.

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

PROJECT_ID=""
PR_NUMBER=""
DOMAIN=""
SERVICES_JSON=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="$2"; shift 2 ;;
    --pr-number)  PR_NUMBER="$2";  shift 2 ;;
    --domain)     DOMAIN="$2";     shift 2 ;;
    --services)   SERVICES_JSON="$2"; shift 2 ;;
    --output)     OUTPUT="$2";     shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${PROJECT_ID:?--project-id is required}"
: "${PR_NUMBER:?--pr-number is required}"
: "${DOMAIN:?--domain is required}"
: "${SERVICES_JSON:?--services is required}"
: "${OUTPUT:?--output is required}"

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------

HOSTNAME="${PROJECT_ID}_${PR_NUMBER}.${DOMAIN}"
SERVICE_COUNT=$(echo "$SERVICES_JSON" | jq 'length')

# ---------------------------------------------------------------------------
# Write YAML header
# ---------------------------------------------------------------------------

cat > "$OUTPUT" <<HEADER
# PR #${PR_NUMBER} preview — project: ${PROJECT_ID}, host: ${HOSTNAME}
services:
HEADER

# ---------------------------------------------------------------------------
# Write each service block
# ---------------------------------------------------------------------------

for i in $(seq 0 $(( SERVICE_COUNT - 1 ))); do
  NAME=$(echo        "$SERVICES_JSON" | jq -r ".[$i].name")
  IMAGE=$(echo       "$SERVICES_JSON" | jq -r ".[$i].image")
  PORT=$(echo        "$SERVICES_JSON" | jq -r ".[$i].port")
  PATH_PREFIX=$(echo "$SERVICES_JSON" | jq -r ".[$i].path_prefix // empty")
  HEALTH_CHECK=$(echo "$SERVICES_JSON" | jq -r ".[$i].health_check // empty")
  ENV_JSON=$(echo    "$SERVICES_JSON" | jq -c ".[$i].environment // {}")

  ROUTER="${PROJECT_ID}-${PR_NUMBER}-${NAME}"

  if [[ -n "$PATH_PREFIX" ]]; then
    TRAEFIK_RULE="Host(\`${HOSTNAME}\`) && PathPrefix(\`${PATH_PREFIX}\`)"
  else
    TRAEFIK_RULE="Host(\`${HOSTNAME}\`)"
  fi

  # --- base service block ---
  cat >> "$OUTPUT" <<SERVICE
  ${NAME}:
    image: ${IMAGE}
    restart: unless-stopped
SERVICE

  # --- environment section (only if non-empty object) ---
  if [[ "$ENV_JSON" != "{}" ]]; then
    echo "    environment:" >> "$OUTPUT"
    while IFS= read -r pair; do
      KEY=$(echo "$pair" | jq -r '.key')
      VAL=$(echo "$pair" | jq -r '.value')
      echo "      ${KEY}: \"${VAL}\"" >> "$OUTPUT"
    done < <(echo "$ENV_JSON" | jq -c 'to_entries[]')
  fi

  # --- Traefik labels ---
  cat >> "$OUTPUT" <<LABELS
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${ROUTER}.rule=${TRAEFIK_RULE}"
      - "traefik.http.routers.${ROUTER}.entrypoints=websecure"
      - "traefik.http.routers.${ROUTER}.tls=true"
      - "traefik.http.routers.${ROUTER}.tls.certresolver=letsencrypt"
      - "traefik.http.services.${ROUTER}.loadbalancer.server.port=${PORT}"
LABELS

  # --- optional healthcheck ---
  if [[ -n "$HEALTH_CHECK" ]]; then
    cat >> "$OUTPUT" <<HEALTHCHECK
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:${PORT}${HEALTH_CHECK}"]
      interval: 15s
      timeout: 5s
      retries: 4
      start_period: 30s
HEALTHCHECK
  fi

  # --- networks ---
  cat >> "$OUTPUT" <<NETWORKS
    networks:
      - traefik
NETWORKS

done

# ---------------------------------------------------------------------------
# Write networks section
# ---------------------------------------------------------------------------

cat >> "$OUTPUT" <<FOOTER

networks:
  traefik:
    external: true
FOOTER

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "Generated ${OUTPUT}"
echo "  project : ${PROJECT_ID}"
echo "  PR      : #${PR_NUMBER}"
echo "  hostname: ${HOSTNAME}"
echo "  services: ${SERVICE_COUNT}"
for i in $(seq 0 $(( SERVICE_COUNT - 1 ))); do
  NAME=$(echo "$SERVICES_JSON" | jq -r ".[$i].name")
  echo "    - ${NAME}"
done
