#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Spike validation: Docker-in-nspawn
#
# Automates every manual check from docker-in-nspawn.nix.
# Run on the NixOS host after the spike config is available.
#
# Exit 0  → all checks passed (GO)
# Exit 1  → one or more checks failed (NO-GO)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPIKE_CONFIG="$SCRIPT_DIR/docker-in-nspawn.nix"
CONTAINER_NAME="spike-docker"
CONTAINER_IP="10.100.99.2"
COMPOSE_TMP=""

# ---------------------------------------------------------------------------
# Colour helpers (disabled when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  RED=$'\033[1;31m'
  YELLOW=$'\033[1;33m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  GREEN="" RED="" YELLOW="" BOLD="" RESET=""
fi

# ---------------------------------------------------------------------------
# Test bookkeeping
# ---------------------------------------------------------------------------
declare -a TEST_NAMES=()
declare -a TEST_RESULTS=()
CRITICAL_FAILURE=0

pass() { echo "  ${GREEN}PASS${RESET} $1"; }
fail() { echo "  ${RED}FAIL${RESET} $1"; }
skip() { echo "  ${YELLOW}SKIP${RESET} $1"; }

# Run a named test function. Records result for the summary table.
# Usage: run_test "human-readable name" test_function
run_test() {
  local name="$1"
  local func="$2"

  TEST_NAMES+=("$name")

  if (( CRITICAL_FAILURE )); then
    skip "$name (skipped — earlier critical failure)"
    TEST_RESULTS+=("SKIP")
    return
  fi

  if "$func"; then
    pass "$name"
    TEST_RESULTS+=("PASS")
  else
    fail "$name"
    TEST_RESULTS+=("FAIL")
  fi
}

# Mark a critical failure so subsequent tests are skipped.
mark_critical() { CRITICAL_FAILURE=1; }

# ---------------------------------------------------------------------------
# Container helper — run a command inside the nspawn container
# ---------------------------------------------------------------------------
container_run() {
  nixos-container run "$CONTAINER_NAME" -- "$@"
}

# ---------------------------------------------------------------------------
# Cleanup (runs on EXIT regardless of success/failure)
# ---------------------------------------------------------------------------
cleanup() {
  echo ""
  echo "${BOLD}--- cleanup ---${RESET}"

  # Remove nginx-test container inside the spike container (best-effort)
  container_run docker rm -f nginx-test 2>/dev/null || true

  # Tear down compose stack (best-effort)
  if [[ -n "$COMPOSE_TMP" ]]; then
    container_run docker compose -f /tmp/spike-compose.yml down 2>/dev/null || true
  fi

  # Destroy the nspawn container
  if extra-container list 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    echo "  Destroying container ${CONTAINER_NAME}..."
    extra-container destroy "$CONTAINER_NAME" || true
  fi

  # Remove temp files
  if [[ -n "$COMPOSE_TMP" && -f "$COMPOSE_TMP" ]]; then
    rm -f "$COMPOSE_TMP"
  fi

  echo "  Cleanup complete."
}
trap cleanup EXIT

# ===========================================================================
# Test functions
# ===========================================================================

test_prerequisites() {
  command -v extra-container >/dev/null 2>&1
}

test_config_exists() {
  [[ -f "$SPIKE_CONFIG" ]]
}

test_create_container() {
  extra-container create --start "$SPIKE_CONFIG"
}

test_container_running() {
  local retries=30
  local delay=2
  for (( i=1; i<=retries; i++ )); do
    if nixos-container status "$CONTAINER_NAME" 2>/dev/null | grep -qi "running"; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

test_docker_info() {
  local output
  output="$(container_run docker info 2>&1)"
  echo "$output" | grep -qi "overlay2"
}

test_docker_hello_world() {
  container_run docker run --rm hello-world >/dev/null 2>&1
}

test_nginx_workload() {
  # Start nginx inside the container, publishing port 8080→80
  container_run docker run -d --name nginx-test -p 8080:80 nginx:alpine >/dev/null 2>&1

  # Give nginx a moment to bind
  sleep 3

  # Reach it from the HOST over the veth network
  curl -sf "http://${CONTAINER_IP}:8080" >/dev/null 2>&1
}

test_outbound_internet() {
  # Pulling an image proves NAT / outbound connectivity
  container_run docker pull alpine >/dev/null 2>&1
}

test_docker_compose() {
  # Write a minimal compose file on the host, then copy it into the container.
  COMPOSE_TMP="$(mktemp /tmp/spike-compose-XXXXXX.yml)"
  cat > "$COMPOSE_TMP" <<'COMPOSEFILE'
services:
  web:
    image: nginx:alpine
    ports:
      - "8081:80"
  worker:
    image: alpine
    command: ["sleep", "300"]
COMPOSEFILE

  # nixos-container doesn't have a built-in file-copy command, but we can
  # write the file via stdin + shell redirect inside the container.
  container_run sh -c "cat > /tmp/spike-compose.yml" < "$COMPOSE_TMP"

  # Bring the stack up
  container_run docker compose -f /tmp/spike-compose.yml up -d >/dev/null 2>&1

  sleep 3

  # Verify both services are running
  local running
  running="$(container_run docker compose -f /tmp/spike-compose.yml ps --format '{{.State}}' 2>/dev/null)"
  local count
  count="$(echo "$running" | grep -c "running" || true)"
  (( count >= 2 ))
}

# ===========================================================================
# Run tests
# ===========================================================================

echo "${BOLD}=== Docker-in-nspawn spike validation ===${RESET}"
echo ""

# --- prerequisites ---
run_test "extra-container on PATH"          test_prerequisites
run_test "spike config file exists"         test_config_exists

# If prerequisites fail, nothing else can run
if [[ "${TEST_RESULTS[*]}" == *"FAIL"* ]]; then
  mark_critical
fi

# --- container lifecycle ---
run_test "create and start container"       test_create_container
if [[ "${TEST_RESULTS[-1]}" == "FAIL" ]]; then mark_critical; fi

run_test "container reaches running state"  test_container_running
if [[ "${TEST_RESULTS[-1]}" == "FAIL" ]]; then mark_critical; fi

# --- docker basics ---
run_test "docker info (overlay2 driver)"    test_docker_info
if [[ "${TEST_RESULTS[-1]}" == "FAIL" ]]; then mark_critical; fi

run_test "docker run hello-world"           test_docker_hello_world

# --- real workload ---
run_test "nginx reachable from host"        test_nginx_workload
run_test "outbound internet (docker pull)"  test_outbound_internet
run_test "docker compose (2 services)"      test_docker_compose

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo "${BOLD}=== Results ===${RESET}"
echo ""
printf "  %-40s %s\n" "CHECK" "RESULT"
printf "  %-40s %s\n" "$(printf '%0.s-' {1..40})" "------"

pass_count=0
fail_count=0
skip_count=0

for i in "${!TEST_NAMES[@]}"; do
  local_result="${TEST_RESULTS[$i]}"
  case "$local_result" in
    PASS) color="$GREEN"; (( ++pass_count )) ;;
    FAIL) color="$RED";   (( ++fail_count )) ;;
    SKIP) color="$YELLOW"; (( ++skip_count )) ;;
    *)    color="$RESET" ;;
  esac
  printf "  %-40s ${color}%s${RESET}\n" "${TEST_NAMES[$i]}" "$local_result"
done

echo ""
echo "  Passed: $pass_count  Failed: $fail_count  Skipped: $skip_count"
echo ""

if (( fail_count == 0 && skip_count == 0 )); then
  echo "  ${GREEN}${BOLD}>>> VERDICT: GO <<<${RESET}"
  echo ""
  exit 0
else
  echo "  ${RED}${BOLD}>>> VERDICT: NO-GO <<<${RESET}"
  echo ""
  exit 1
fi
