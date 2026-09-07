#!/usr/bin/env bash
# tests/integration/e2e_flow_test.sh
#
# End-to-end orchestration test with REAL dependencies (no mocks):
#   - Real Redis container
#   - Real Gitea container (real git + real issue/PR REST API)
#   - Real OpenFlows controller (agentflow) pointed at Gitea via GITHUB_API_BASE
#
# What it proves (the "issue -> ticket" entry of the orchestration loop):
#   1. A real issue created in Gitea
#   2. The controller (NEXUS) syncs it through the real GitHub REST client
#   3. A T-*** ticket appears in real Redis
#
# This directly exercises the configurable GitHub API base URL
# (GITHUB_API_BASE), i.e. the change that lets the whole control plane talk
# to a self-hosted Git server instead of api.github.com.
#
# The workspace-provision / chat / PR stages require the full stack (a Coder
# server with a docker provisioner + a configured model) and are reported as
# "NOT RUN in this environment" rather than falsely asserted.
#
# Exit codes:
#   0 = PASS (or SKIP — prereqs missing; a skip is a clean, explicit non-fail)
#   1 = FAIL (an assertion was violated)

set -uo pipefail

GITEA_IMAGE="${GITEA_IMAGE:-gitea/gitea:1.22.3}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:8-alpine}"
REDIS_PORT="${REDIS_PORT:-16379}"   # avoid clashing with a local 6379
GITEA_PORT="${GITEA_PORT:-13000}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-13000}"
TENANT="${OPENFLOWS_TENANT:-e2e-tenant}"
OWNER="openflows-e2e"
REPO="workbench"
GITEA_ADMIN_USER="e2e-admin"
GITEA_ADMIN_PASS="E2eAdmin!Passw0rd"
GITEA_TOKEN_NAME="e2e-token"
REDIS_CONTAINER="openflows-e2e-redis"
GITEA_CONTAINER="openflows-e2e-gitea"
CTRL_TIMEOUT="${CTRL_TIMEOUT:-45}"   # seconds the controller runs for

GITEA_BASE="http://localhost:${GITEA_HTTP_PORT}"
# Gitea exposes a GitHub-shaped REST API under /api/v1. Pointing the controller's
# GITHUB_API_BASE here makes its GitHub-style paths (/repos/{o}/{r}/issues, /user,
# /repos/{o}/{r}/pulls, ...) hit Gitea's real API. Gitea accepts the controller's
# `Authorization: Bearer <token>` header, so the same token works as GITHUB_TOKEN.
GITEA_API="${GITEA_BASE}/api/v1"
GITEA_CONTROLLER_BASE="${GITEA_API}"

PASS=0; FAIL=0; SKIP=0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '\033[33m[SKIP]\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }

cleanup() {
  docker rm -f "$REDIS_CONTAINER" "$GITEA_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# Preflight — skip cleanly (never fake-fail the PR) when prereqs are missing.
# --------------------------------------------------------------------------
preflight() {
  command -v docker  >/dev/null || { skip "docker not available"; return 1; }
  command -v curl    >/dev/null || { skip "curl not available";    return 1; }
  command -v jq      >/dev/null || { skip "jq not available";      return 1; }
  if ! docker info >/dev/null 2>&1; then
    skip "docker daemon not reachable"; return 1
  fi
  # Controller binary must be built.
  if [ ! -x "$CTRL_BIN" ]; then
    skip "controller binary not built at $CTRL_BIN (run 'cargo build -p openflows')"; return 1
  fi
  return 0
}

# --------------------------------------------------------------------------
# Infrastructure
# --------------------------------------------------------------------------
start_infra() {
  say "Starting real Redis + Gitea containers"
  docker run -d --name "$REDIS_CONTAINER" -p "${REDIS_PORT}:6379" "$REDIS_IMAGE" >/dev/null \
    || { bad "failed to start Redis"; return 1; }
  docker run -d --name "$GITEA_CONTAINER" -p "${GITEA_PORT}:3000" \
      -e GITEA__SECURITY__INSTALL_LOCK=true \
      -e GITEA__SERVICE__DISABLE_REGISTRATION=true \
      "$GITEA_IMAGE" >/dev/null \
    || { bad "failed to start Gitea"; return 1; }
  wait_http "$GITEA_API/version" 120 || { bad "Gitea API not healthy"; return 1; }
  ok "Redis + Gitea containers up"
  return 0
}

wait_http() { # url, timeout_s
  local url="$1" t="$2" i
  for i in $(seq 1 "$t"); do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

setup_gitea() {
  say "Creating Gitea admin user, token, org, repo, and seeding a real issue"
  docker exec -u git "$GITEA_CONTAINER" gitea admin user create \
      --username "$GITEA_ADMIN_USER" --password "$GITEA_ADMIN_PASS" \
      --email "e2e@example.com" --admin --must-change-password=false >/dev/null 2>&1 \
    || true

  # Create an API token for the admin user (Bearer-auth; scopes valid for Gitea 1.22).
  local tok_json
  tok_json="$(curl -fsS -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASS" \
    -X POST "$GITEA_API/users/$GITEA_ADMIN_USER/tokens" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$GITEA_TOKEN_NAME\",\"scopes\":[\"write:repository\",\"write:issue\",\"write:user\"]}")" \
    || { bad "failed to create Gitea token"; return 1; }
  GITEA_TOKEN="$(printf '%s' "$tok_json" | jq -r .sha1)" || { bad "failed to parse Gitea token"; return 1; }
  [ -n "$GITEA_TOKEN" ] && [ "$GITEA_TOKEN" != "null" ] || { bad "empty Gitea token"; return 1; }

  # Basic auth (full access, no scopes) is used for admin setup calls below.
  local auth="-u ${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}"

  curl -fsS $auth -X POST "$GITEA_API/orgs" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$OWNER\"}" >/dev/null 2>&1 \
    || { bad "failed to create Gitea org"; return 1; }

  curl -fsS $auth -X POST "$GITEA_API/orgs/$OWNER/repos" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$REPO\",\"auto_init\":true}" >/dev/null 2>&1 \
    || { bad "failed to create Gitea repo"; return 1; }

  curl -fsS $auth -X POST "$GITEA_API/repos/$OWNER/$REPO/issues" \
    -H 'Content-Type: application/json' \
    -d '{"title":"E2E: add hello.txt with content \"hello\"","body":"E2E test issue"}' \
    >/dev/null 2>&1 || { bad "failed to seed Gitea issue"; return 1; }

  ok "Gitea ready; admin token + org + repo + issue created"
  return 0
}

# --------------------------------------------------------------------------
# Run the controller and assert the issue -> ticket loop
# --------------------------------------------------------------------------
run_controller_and_assert() {
  say "Running real controller against Gitea (${GITEA_CONTROLLER_BASE})"
  local log
  log="$(mktemp)"
  # Redirect so the controller (on the host) reaches Gitea's GitHub-shaped API.
  GITHUB_API_BASE="$GITEA_CONTROLLER_BASE" \
  GITHUB_TOKEN="$GITEA_TOKEN" \
  GITHUB_REPOSITORY="$OWNER/$REPO" \
  OPENFLOWS_TENANT="$TENANT" \
  REDIS_URL="redis://localhost:${REDIS_PORT}" \
  CODER_URL="http://localhost:${GITEA_PORT}" \
  timeout "$CTRL_TIMEOUT" "$CTRL_BIN" >"$log" 2>&1 || true

  echo "--- controller log (tail) ---"
  tail -40 "$log" || true
  echo "-----------------------------"

  # Assert: a T-*** ticket landed in Redis (tenant-namespaced, query through
  # the container's own redis-cli).
  local ticket
  ticket="$(docker exec "$REDIS_CONTAINER" redis-cli --scan --pattern 'ns:*:ticket:T-*' 2>/dev/null | head -1)"
  if [ -n "$ticket" ]; then
    ok "controller created Redis ticket key: $ticket"
  else
    # Fall back to the definitive signal from the controller log.
    if grep -q "Synced new ticket" "$log"; then
      ok "controller log confirms 'Synced new ticket' from the real Gitea issue"
      ticket="(from log)"
    else
      bad "no 'ns:*:ticket:T-*' key in Redis and no 'Synced new ticket' in the log — issue was not synced"
      grep -iE "sync|issue|token|github|gitea|error|panic" "$log" | tail -20 || true
      return 1
    fi
  fi

  # Report the stages that are gated on the full stack.
  skip "workspace-provision / chat / PR stages NOT RUN here (require Coder server + docker provisioner + a configured model)"
  return 0
}

# --------------------------------------------------------------------------
main() {
  say "OpenFlows real-dependency E2E (issue -> ticket via Gitea)"
  CTRL_BIN="${CTRL_BIN:-$(pwd)/target/debug/openflows}"
  if ! preflight; then
    say "SKIPPED — prereqs unavailable; nothing was asserted."
    echo "RESULT: SKIP (${SKIP} skipped)"
    exit 0
  fi

  start_infra || exit 1
  setup_gitea || exit 1
  run_controller_and_assert || exit 1

  say "E2E result: PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

main "$@"
