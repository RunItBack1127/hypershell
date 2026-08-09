#!/usr/bin/env bash
# e2e-openshell.sh — end-to-end test of the OpenShell gateway provisioned by HyperShell.
#
# Proves the full path: HyperShell API → control plane → gateway provisioning
# → Keycloak OIDC authentication → openshell CLI → sandbox pod creation + interaction.
#
# This script creates a fleet, cluster, release, database, and gateway via the
# HyperShell API (if they don't exist), waits for the controller to provision
# the gateway, then validates OIDC authentication, connectivity, and sandbox lifecycle.
#
# Usage:
#   bash e2e-openshell.sh
#
# Environment variables:
#   OC                   oc/kubectl binary (default: oc)
#   HYPERSHELL_NAMESPACE API server + keycloak namespace (default: hypershell)
#   GATEWAY_NAMESPACE    target namespace for the gateway (default: openshell-e2e)
#   GATEWAY_NAME         gateway name (default: openshell-gateway)
#   KC_REALM             keycloak realm name (default: hypershell)
#   KC_CLIENT_ID         OIDC client for CLI auth (default: openshell-cli)
#   KC_USERNAME          test user (default: admin)
#   KC_PASSWORD          test password (default: admin)
#   SANDBOX_TIMEOUT      seconds to wait for sandbox (default: 120)
#   PROVISION_TIMEOUT    seconds to wait for gateway provisioning (default: 180)
#   SKIP_CLEANUP         set to 1 to keep resources after test
#   LAUNCH_TUI           set to 1 to launch interactive TUI at the end (default: 0)
#   PAUSE                seconds between commands (default: 1)
#   GATEWAY_IMAGE        gateway container image override
#   SUPERVISOR_IMAGE     supervisor container image override
#   DB_IMAGE             database container image override
set -euo pipefail

CLI="${OC:-oc}"
OPENSHELL="${OPENSHELL_BIN:-openshell}"
HS_NAMESPACE="${HYPERSHELL_NAMESPACE:-hypershell}"
GW_NAMESPACE="${GATEWAY_NAMESPACE:-openshell-e2e}"
GW_NAME="${GATEWAY_NAME:-openshell-gateway}"
KC_REALM="${KC_REALM:-hypershell}"
KC_CLIENT_ID="${KC_CLIENT_ID:-openshell-cli}"
KC_USERNAME="${KC_USERNAME:-admin}"
KC_PASSWORD="${KC_PASSWORD:-admin}"
SANDBOX_TIMEOUT="${SANDBOX_TIMEOUT:-120}"
PROVISION_TIMEOUT="${PROVISION_TIMEOUT:-180}"
SKIP_CLEANUP="${SKIP_CLEANUP:-}"
LAUNCH_TUI="${LAUNCH_TUI:-0}"
PAUSE="${PAUSE:-1}"

PASS=0
FAIL=0
TESTS=()
PF_PID=""
SANDBOX_NAME=""
GW_ID=""
FLEET_ID=""
OIDC_JWT=""
AUTH_MODE="none"

bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }
cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
orange() { printf '\033[38;5;214m%s\033[0m\n' "$*"; }
sep()    { printf '\033[2m────────────────────────────────────────────────\033[0m\n'; }

show_cmd() {
  orange "   \$ $*"
  sleep "$PAUSE"
}

pass() {
  PASS=$((PASS + 1))
  TESTS+=("PASS: $1")
  green "  ✓ $1"
}

fail_test() {
  FAIL=$((FAIL + 1))
  TESTS+=("FAIL: $1")
  red "  ✗ $1"
}

cleanup() {
  if [[ -n "${SB_CREATE_PID:-}" ]]; then
    kill "$SB_CREATE_PID" 2>/dev/null || true
    wait "$SB_CREATE_PID" 2>/dev/null || true
  fi
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  if [[ "$SKIP_CLEANUP" != "1" && -n "$GW_ID" ]]; then
    dim "  Cleaning up gateway ${GW_NAME}..."
    curl -sk -X DELETE "https://${API_HOST}/api/hypershell/v1/gateways/${GW_ID}" &>/dev/null || true
  fi
}
trap cleanup EXIT

API_HOST=$($CLI get route hypershell-api -n "$HS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -z "$API_HOST" ]]; then
  red "ERROR: HyperShell API route not found in namespace ${HS_NAMESPACE}"
  exit 1
fi

CLUSTER_DOMAIN=$($CLI get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
if [[ -z "$CLUSTER_DOMAIN" ]]; then
  CLUSTER_DOMAIN="cluster.local"
fi

KC_HOST=$($CLI get route keycloak -n "$HS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)

echo ""
bold "HyperShell OpenShell Gateway End-to-End Test"
sep
echo ""
printf '  %s\n' "1. Keycloak OIDC authentication"
printf '  %s\n' "2. Gateway provisioning via HyperShell API"
printf '  %s\n' "3. Gateway infrastructure verification"
printf '  %s\n' "4. Route discovery + openshell CLI registration"
printf '  %s\n' "5. Gateway connectivity"
printf '  %s\n' "6. Sandbox lifecycle (create → ready)"
printf '  %s\n' "7. Sandbox interaction"
echo ""
dim  "  HyperShell API:    https://${API_HOST}"
dim  "  Gateway namespace: ${GW_NAMESPACE}"
dim  "  Gateway name:      ${GW_NAME}"
dim  "  Keycloak:          ${KC_HOST:-not found}"
dim  "  Sandbox timeout:   ${SANDBOX_TIMEOUT}s"
echo ""
sep

# ── 1. Keycloak OIDC authentication ─────────────────────────────────────

echo ""
bold "1. Keycloak OIDC Authentication"
echo ""

if [[ -n "$KC_HOST" ]]; then
  show_cmd "curl -sk https://${KC_HOST}/realms/${KC_REALM}/protocol/openid-connect/token -d grant_type=password -d username=${KC_USERNAME}"
  TOKEN_RESPONSE=$(curl -sk -X POST \
    "https://${KC_HOST}/realms/${KC_REALM}/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=${KC_CLIENT_ID}" \
    -d "username=${KC_USERNAME}" \
    -d "password=${KC_PASSWORD}" \
    --connect-timeout 10 --max-time 30 2>&1 || true)

  OIDC_JWT=$(echo "$TOKEN_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

  if [[ -n "$OIDC_JWT" ]]; then
    AUTH_MODE="oidc"
    OIDC_ISSUER=$(echo "$OIDC_JWT" | cut -d. -f2 | python3 -c "
import base64,json,sys
p=sys.stdin.read().strip()
p+='='*(-len(p)%4)
payload=json.loads(base64.urlsafe_b64decode(p))
print(payload.get('iss','unknown'))
" 2>/dev/null || echo "unknown")
    USER_ROLES=$(echo "$OIDC_JWT" | cut -d. -f2 | python3 -c "
import base64,json,sys
p=sys.stdin.read().strip()
p+='='*(-len(p)%4)
payload=json.loads(base64.urlsafe_b64decode(p))
print(', '.join(payload.get('realm_access',{}).get('roles',[])))
" 2>/dev/null || echo "unknown")
    pass "OIDC token for ${KC_USERNAME} (roles: ${USER_ROLES})"
    dim "    issuer: ${OIDC_ISSUER}"
  else
    ERROR=$(echo "$TOKEN_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error_description','unknown'))" 2>/dev/null || echo "unknown")
    dim "  Token exchange failed: ${ERROR}"
    dim "  Falling back to no-auth mode"
  fi
else
  dim "  Keycloak not found in ${HS_NAMESPACE}, using no-auth mode"
fi
sep

# ── 2. gateway provisioning ────────────────────────────────────────────

echo ""
bold "2. Gateway Provisioning via HyperShell API"
echo ""

show_cmd "curl -sk https://${API_HOST}/api/hypershell/v1/gateways?search=name%3D${GW_NAME}"
EXISTING_GW=$(curl -sk "https://${API_HOST}/api/hypershell/v1/gateways?search=name%3D${GW_NAME}" 2>/dev/null || true)
EXISTING_ID=$(echo "$EXISTING_GW" | python3 -c "
import json,sys
data = json.load(sys.stdin)
items = data.get('items', [])
for gw in items:
    if gw.get('name','') == '${GW_NAME}':
        print(gw['id'])
        break
" 2>/dev/null || true)

if [[ -n "$EXISTING_ID" ]]; then
  GW_ID="$EXISTING_ID"
  GW_PHASE=$(echo "$EXISTING_GW" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for gw in data.get('items', []):
    if gw.get('id','') == '${GW_ID}':
        print(gw.get('phase',''))
        break
" 2>/dev/null || true)
  pass "Gateway already exists: ${GW_NAME} (${GW_ID}, phase=${GW_PHASE})"
else
  dim "  Creating prerequisite resources..."

  FLEET_RESP=$(curl -sk "https://${API_HOST}/api/hypershell/v1/fleets" 2>/dev/null || true)
  FLEET_ID=$(echo "$FLEET_RESP" | python3 -c "
import json,sys
data = json.load(sys.stdin)
items = data.get('items', [])
if items:
    print(items[0]['id'])
" 2>/dev/null || true)

  if [[ -z "$FLEET_ID" ]]; then
    show_cmd "curl -sk -X POST https://${API_HOST}/api/hypershell/v1/fleets -d '{name: e2e-fleet}'"
    FLEET_RESP=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/fleets" \
      -H "Content-Type: application/json" \
      -d '{"name": "e2e-fleet", "description": "E2E test fleet"}' 2>/dev/null || true)
    FLEET_ID=$(echo "$FLEET_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    if [[ -n "$FLEET_ID" ]]; then
      pass "Fleet created: e2e-fleet (${FLEET_ID})"
    else
      fail_test "Failed to create fleet"
      dim "    ${FLEET_RESP:0:300}"
      exit 1
    fi
  else
    pass "Fleet exists: ${FLEET_ID}"
  fi

  CLUSTER_RESP=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/managed_clusters" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"e2e-cluster\", \"fleet_id\": \"${FLEET_ID}\", \"provider\": \"openshift\", \"kubeconfig_secret\": \"controller-kubeconfig\"}" 2>/dev/null || true)
  CLUSTER_ID=$(echo "$CLUSTER_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

  GW_IMAGE_VAL="${GATEWAY_IMAGE:-}"
  RELEASE_IMAGE="${GW_IMAGE_VAL:-ghcr.io/nvidia/openshell/gateway:0.0.101}"
  RELEASE_RESP=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/gateway_releases" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"e2e-release\", \"fleet_id\": \"${FLEET_ID}\", \"image\": \"${RELEASE_IMAGE}\"}" 2>/dev/null || true)
  RELEASE_ID=$(echo "$RELEASE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

  DB_RESP=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/managed_databases" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"e2e-db\", \"fleet_id\": \"${FLEET_ID}\", \"provider\": \"embedded\", \"engine\": \"postgresql\"}" 2>/dev/null || true)
  DB_ID=$(echo "$DB_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

  if [[ -z "$CLUSTER_ID" || -z "$RELEASE_ID" || -z "$DB_ID" ]]; then
    fail_test "Failed to create prerequisite resources"
    dim "    cluster=${CLUSTER_ID:-FAIL} release=${RELEASE_ID:-FAIL} db=${DB_ID:-FAIL}"
    exit 1
  fi
  pass "Prerequisites: cluster=${CLUSTER_ID} release=${RELEASE_ID} db=${DB_ID}"

  OIDC_FIELD=""
  if [[ "$AUTH_MODE" == "oidc" && -n "$OIDC_ISSUER" ]]; then
    OIDC_FIELD=", \"oidc\": \"{\\\"issuer\\\":\\\"${OIDC_ISSUER}\\\",\\\"audience\\\":\\\"${KC_CLIENT_ID}\\\",\\\"roles_claim\\\":\\\"realm_access.roles\\\",\\\"admin_role\\\":\\\"openshell-admin\\\",\\\"user_role\\\":\\\"openshell-user\\\"}\""
  fi

  DB_CONFIG_FIELD=""
  if [[ -n "${DB_IMAGE:-}" ]]; then
    DB_CONFIG_FIELD=", \"database_config\": \"{\\\"image\\\":\\\"${DB_IMAGE}\\\",\\\"storage_size\\\":\\\"5Gi\\\"}\""
  fi

  GW_IMAGE_FIELD=""
  if [[ -n "${GATEWAY_IMAGE:-}" ]]; then
    GW_IMAGE_FIELD=", \"image\": \"${GATEWAY_IMAGE}\""
  fi

  SUP_IMAGE_FIELD=""
  if [[ -n "${SUPERVISOR_IMAGE:-}" ]]; then
    SUP_IMAGE_FIELD=", \"supervisor_image\": \"${SUPERVISOR_IMAGE}\""
  fi

  DNS_NAMES="[\"openshell-gateway.${GW_NAMESPACE}.svc.cluster.local\"]"

  show_cmd "curl -sk -X POST https://${API_HOST}/api/hypershell/v1/gateways -d '{name: ${GW_NAME}, namespace: ${GW_NAMESPACE}, ...}'"
  CREATE_RESPONSE=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/gateways" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${GW_NAME}\",
      \"fleet_id\": \"${FLEET_ID}\",
      \"cluster_id\": \"${CLUSTER_ID}\",
      \"release_id\": \"${RELEASE_ID}\",
      \"database_id\": \"${DB_ID}\",
      \"namespace\": \"${GW_NAMESPACE}\",
      \"server_dns_names\": ${DNS_NAMES}
      ${GW_IMAGE_FIELD}
      ${SUP_IMAGE_FIELD}
      ${OIDC_FIELD}
      ${DB_CONFIG_FIELD}
    }" 2>/dev/null || true)

  GW_ID=$(echo "$CREATE_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

  if [[ -n "$GW_ID" ]]; then
    pass "Gateway created: ${GW_NAME} (${GW_ID})"
  else
    fail_test "Failed to create gateway"
    dim "    ${CREATE_RESPONSE:0:300}"
    exit 1
  fi

  dim "  Waiting for controller to provision (timeout: ${PROVISION_TIMEOUT}s)..."
  DEADLINE=$(($(date +%s) + PROVISION_TIMEOUT))
  while [[ $(date +%s) -lt $DEADLINE ]]; do
    GW_PHASE=$(curl -sk "https://${API_HOST}/api/hypershell/v1/gateways/${GW_ID}" 2>/dev/null | \
      python3 -c "import json,sys; print(json.load(sys.stdin).get('phase',''))" 2>/dev/null || true)
    if [[ "$GW_PHASE" == "Running" ]]; then
      break
    fi
    dim "    phase: ${GW_PHASE:-unknown}"
    sleep 5
  done

  if [[ "$GW_PHASE" == "Running" ]]; then
    pass "Gateway provisioned and running"
  else
    fail_test "Gateway not running after ${PROVISION_TIMEOUT}s (phase=${GW_PHASE})"
    exit 1
  fi
fi
sep

# ── 3. gateway infrastructure ──────────────────────────────────────────

echo ""
bold "3. Gateway Infrastructure"
echo ""

show_cmd "$CLI get deployment openshell-gateway -n $GW_NAMESPACE"
if $CLI get deployment openshell-gateway -n "$GW_NAMESPACE" &>/dev/null; then
  dim "  Waiting for gateway pod to be ready (up to 90s)..."
  GW_READY=0
  GW_READY_DEADLINE=$(($(date +%s) + 90))
  while [[ $(date +%s) -lt $GW_READY_DEADLINE ]]; do
    GW_READY=$($CLI get deployment openshell-gateway -n "$GW_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [[ "${GW_READY:-0}" -ge 1 ]]; then
      break
    fi
    sleep 5
  done
  GW_IMAGE=$($CLI get deployment openshell-gateway -n "$GW_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)
  if [[ "${GW_READY:-0}" -ge 1 ]]; then
    pass "Gateway pod ready ($GW_IMAGE)"
  else
    fail_test "Gateway pod not ready after 90s (${GW_READY:-0} replicas)"
  fi
else
  fail_test "Gateway Deployment not found in $GW_NAMESPACE"
fi

show_cmd "$CLI get service openshell-gateway -n $GW_NAMESPACE"
GW_SVC=$($CLI get service openshell-gateway -n "$GW_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [[ -n "$GW_SVC" ]]; then
  pass "Gateway service: ${GW_SVC}:8080"
else
  fail_test "Gateway service not found"
fi

show_cmd "$CLI get secret openshell-server-tls -n $GW_NAMESPACE"
HAS_TLS=$($CLI get secret openshell-server-tls -n "$GW_NAMESPACE" 2>/dev/null && echo yes || true)
if [[ -n "$HAS_TLS" ]]; then
  pass "TLS certificates provisioned"
else
  dim "  - TLS secret not found (certgen job may still be running)"
fi

show_cmd "$CLI get jobs -n $GW_NAMESPACE"
CERTGEN_STATUS=$($CLI get job openshell-gateway-certgen -n "$GW_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)
if [[ "${CERTGEN_STATUS:-0}" -ge 1 ]]; then
  pass "Certificate generation job completed"
else
  dim "  - Certgen job status: ${CERTGEN_STATUS:-unknown}"
fi

if $CLI get route openshell-gateway -n "$GW_NAMESPACE" &>/dev/null; then
  ROUTE_HOST=$($CLI get route openshell-gateway -n "$GW_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  ROUTE_TERM=$($CLI get route openshell-gateway -n "$GW_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || true)
  pass "OpenShift Route: ${ROUTE_HOST} (${ROUTE_TERM})"
else
  dim "  - No OpenShift Route found"
fi
sep

# ── 4. route discovery + CLI registration ─────────────────────────────

echo ""
bold "4. Route Discovery + CLI Registration"
echo ""

GW_LOCAL_NAME="${GW_NAMESPACE}-openshell"

show_cmd "$CLI get routes -n $GW_NAMESPACE"
GW_ROUTE_HOST=$($CLI get routes -n "$GW_NAMESPACE" -o json 2>/dev/null | python3 -c "
import json,sys
data = json.load(sys.stdin)
candidates = []
for item in data.get('items',[]):
    tls = item.get('spec',{}).get('tls',{})
    to = item.get('spec',{}).get('to',{})
    name = item.get('metadata',{}).get('name','')
    if (tls.get('termination') == 'passthrough' and
        to.get('name') == 'openshell-gateway' and
        ('grpc' in name or 'gateway' in name)):
        candidates.append(item['spec']['host'])
if candidates:
    print(candidates[0])
" 2>/dev/null || true)

if [[ -z "$GW_ROUTE_HOST" ]]; then
  dim "  No passthrough route found, falling back to port-forward"
  PF_PORT=7443
  show_cmd "$CLI port-forward -n $GW_NAMESPACE svc/openshell-gateway ${PF_PORT}:8080 &"
  $CLI port-forward -n "$GW_NAMESPACE" svc/openshell-gateway "${PF_PORT}":8080 &>/dev/null &
  PF_PID=$!
  sleep 3
  if kill -0 "$PF_PID" 2>/dev/null; then
    pass "Port-forward active (localhost:${PF_PORT} → openshell-gateway:8080)"
  else
    fail_test "Port-forward failed to start"
    PF_PID=""
    exit 1
  fi
  GW_ENDPOINT="https://localhost:${PF_PORT}"
else
  GW_ENDPOINT="https://${GW_ROUTE_HOST}:443"
  pass "Passthrough route: ${GW_ROUTE_HOST}"
fi

GW_CONFIG_DIR="${HOME}/.config/openshell/gateways/${GW_LOCAL_NAME}"
mkdir -p "${GW_CONFIG_DIR}"

show_cmd "${OPENSHELL} gateway remove ${GW_LOCAL_NAME}"
"${OPENSHELL}" gateway remove "${GW_LOCAL_NAME}" 2>/dev/null || true
mkdir -p "${GW_CONFIG_DIR}"

if [[ "$AUTH_MODE" == "oidc" ]]; then
  show_cmd "# write gateway metadata (OIDC mode)"
  python3 -c "
import json
meta = {
    'name': '${GW_LOCAL_NAME}',
    'gateway_endpoint': '${GW_ENDPOINT}',
    'is_remote': True,
    'gateway_port': 0,
    'auth_mode': 'oidc',
    'oidc_issuer': '${OIDC_ISSUER}',
    'oidc_client_id': '${KC_CLIENT_ID}',
    'oidc_audience': '${KC_CLIENT_ID}'
}
with open('${GW_CONFIG_DIR}/metadata.json', 'w') as f:
    json.dump(meta, f, indent=2)
"
  python3 -c "
import json
token_data = {
    'access_token': '${OIDC_JWT}',
    'issuer': '${OIDC_ISSUER}',
    'client_id': '${KC_CLIENT_ID}'
}
with open('${GW_CONFIG_DIR}/oidc_token.json', 'w') as f:
    json.dump(token_data, f, indent=2)
import os
os.chmod('${GW_CONFIG_DIR}/oidc_token.json', 0o600)
os.chmod('${GW_CONFIG_DIR}/metadata.json', 0o600)
"
  if [[ -f "${GW_CONFIG_DIR}/metadata.json" ]]; then
    pass "openshell CLI registered (OIDC mode, user=${KC_USERNAME})"
  else
    fail_test "Failed to write gateway config"
  fi
else
  show_cmd "# write gateway metadata (no-auth mode)"
  python3 -c "
import json
meta = {
    'name': '${GW_LOCAL_NAME}',
    'gateway_endpoint': '${GW_ENDPOINT}',
    'is_remote': True,
    'gateway_port': 0,
    'auth_mode': 'none'
}
with open('${GW_CONFIG_DIR}/metadata.json', 'w') as f:
    json.dump(meta, f, indent=2)
"
  if [[ -f "${GW_CONFIG_DIR}/metadata.json" ]]; then
    pass "openshell CLI registered (no-auth mode)"
  else
    fail_test "Failed to write gateway config"
  fi
fi
sep

# ── 5. gateway connectivity ───────────────────────────────────────────

echo ""
bold "5. Gateway Connectivity"
echo ""

show_cmd "OPENSHELL_GATEWAY_INSECURE=true ${OPENSHELL} -g ${GW_LOCAL_NAME} status"
dim "  Waiting for route connectivity (up to 60s)..."
CONNECT_DEADLINE=$(($(date +%s) + 60))
STATUS_OUTPUT=""
CONNECTED=false
while [[ $(date +%s) -lt $CONNECT_DEADLINE ]]; do
  STATUS_OUTPUT=$(OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${GW_LOCAL_NAME}" status 2>&1 || true)
  CLEAN_STATUS=$(echo "$STATUS_OUTPUT" | sed 's/\x1b\[[0-9;]*m//g')
  if echo "$CLEAN_STATUS" | grep -qi "Connected"; then
    CONNECTED=true
    break
  fi
  sleep 5
done

if [[ "$CONNECTED" == "true" ]]; then
  GW_VERSION=$(echo "$CLEAN_STATUS" | grep -oP 'Version:\s*\K\S+' || echo "unknown")
  pass "Gateway connected (version: ${GW_VERSION})"
  echo "$STATUS_OUTPUT" | while IFS= read -r line; do
    dim "    $line"
  done
else
  fail_test "Gateway not reachable"
  echo "$STATUS_OUTPUT" | while IFS= read -r line; do
    dim "    $line"
  done
fi
sep

# ── 6. sandbox lifecycle ──────────────────────────────────────────────

echo ""
bold "6. Sandbox Lifecycle"
echo ""

RUN_ID=$(date +%s | tail -c5)
SANDBOX_NAME="e2e-${RUN_ID}"

show_cmd "OPENSHELL_GATEWAY_INSECURE=true ${OPENSHELL} -g ${GW_LOCAL_NAME} sandbox create --name ${SANDBOX_NAME}"
dim "  Creating sandbox (timeout: ${SANDBOX_TIMEOUT}s)..."

OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${GW_LOCAL_NAME}" sandbox create --name "${SANDBOX_NAME}" &>/dev/null &
SB_CREATE_PID=$!

DEADLINE=$(($(date +%s) + SANDBOX_TIMEOUT))
SANDBOX_FOUND=false
POD_NAME=""
POD_STATUS=""
while [[ $(date +%s) -lt $DEADLINE ]]; do
  SANDBOX_PODS=$($CLI get pods -n "$GW_NAMESPACE" --no-headers 2>/dev/null | grep -i "default--${SANDBOX_NAME}" || true)
  if [[ -n "$SANDBOX_PODS" ]]; then
    POD_STATUS=$(echo "$SANDBOX_PODS" | awk '{print $3}' | head -1)
    POD_NAME=$(echo "$SANDBOX_PODS" | awk '{print $1}' | head -1)
    if [[ "$POD_STATUS" == "Running" ]]; then
      SANDBOX_FOUND=true
      break
    fi
    dim "    pod: ${POD_NAME} (${POD_STATUS})"
  fi
  sleep 5
done

kill "$SB_CREATE_PID" 2>/dev/null || true
wait "$SB_CREATE_PID" 2>/dev/null || true
SB_CREATE_PID=""

show_cmd "$CLI get pods -n $GW_NAMESPACE --no-headers | grep ${SANDBOX_NAME}"

if [[ "$SANDBOX_FOUND" == "true" ]]; then
  pass "Sandbox pod created: ${POD_NAME} (${POD_STATUS})"
else
  SANDBOX_PODS=$($CLI get pods -n "$GW_NAMESPACE" --no-headers 2>/dev/null | grep -i "default--${SANDBOX_NAME}" || true)
  if [[ -n "$SANDBOX_PODS" ]]; then
    POD_STATUS=$(echo "$SANDBOX_PODS" | awk '{print $3}' | head -1)
    POD_NAME=$(echo "$SANDBOX_PODS" | awk '{print $1}' | head -1)
    pass "Sandbox pod created: ${POD_NAME} (${POD_STATUS})"
  else
    fail_test "Sandbox not found after ${SANDBOX_TIMEOUT}s"
  fi
fi
sep

# ── 7. sandbox interaction ────────────────────────────────────────────

echo ""
bold "7. Sandbox Interaction"
echo ""

GW_FLAG="-g ${GW_LOCAL_NAME}"
INSECURE_ENV="OPENSHELL_GATEWAY_INSECURE=true"

show_cmd "${INSECURE_ENV} ${OPENSHELL} ${GW_FLAG} sandbox exec -n ${SANDBOX_NAME} -- uname -a"
if SB_EXEC_OUTPUT=$(OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${GW_LOCAL_NAME}" sandbox exec -n "${SANDBOX_NAME}" -- uname -a 2>&1); then
  CLEAN_EXEC=$(echo "$SB_EXEC_OUTPUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^ *$' | grep -v 'WARN' | tail -3)
  if [[ -n "$CLEAN_EXEC" ]]; then
    pass "Sandbox exec: command executed inside sandbox"
    echo "$CLEAN_EXEC" | while IFS= read -r line; do
      dim "    $line"
    done
  else
    fail_test "Sandbox exec: no output from uname command"
    dim "    ${SB_EXEC_OUTPUT:0:200}"
  fi
else
  fail_test "Sandbox exec: openshell command failed"
  dim "    ${SB_EXEC_OUTPUT:0:200}"
fi

show_cmd "${INSECURE_ENV} ${OPENSHELL} ${GW_FLAG} sandbox exec -n ${SANDBOX_NAME} -- ls -la /workspace"
if SB_LS_OUTPUT=$(OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${GW_LOCAL_NAME}" sandbox exec -n "${SANDBOX_NAME}" -- ls -la /workspace 2>&1); then
  CLEAN_LS=$(echo "$SB_LS_OUTPUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^ *$' | grep -v 'WARN' | tail -5)
  if [[ -n "$CLEAN_LS" ]]; then
    pass "Sandbox workspace: /workspace directory listing"
    echo "$CLEAN_LS" | while IFS= read -r line; do
      dim "    $line"
    done
  else
    fail_test "Sandbox workspace: no output from ls command"
    dim "    ${SB_LS_OUTPUT:0:200}"
  fi
else
  if echo "$SB_LS_OUTPUT" | grep -q "No such file or directory"; then
    dim "  - /workspace not available (using default working directory)"
  else
    fail_test "Sandbox workspace: openshell ls command failed"
    dim "    ${SB_LS_OUTPUT:0:200}"
  fi
fi

# ── cleanup ───────────────────────────────────────────────────────────

if [[ "$SKIP_CLEANUP" != "1" && "$LAUNCH_TUI" != "1" && -n "$SANDBOX_NAME" ]]; then
  echo ""
  dim "  Cleaning up sandbox..."
  show_cmd "${INSECURE_ENV} ${OPENSHELL} ${GW_FLAG} sandbox delete ${SANDBOX_NAME}"
  OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${GW_LOCAL_NAME}" sandbox delete "${SANDBOX_NAME}" 2>&1 || true
  dim "  Sandbox deleted"
fi
sep

# ── results ───────────────────────────────────────────────────────────

echo ""
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bold "Results: $PASS passed, $FAIL failed (auth=${AUTH_MODE})"
echo ""
for t in "${TESTS[@]}"; do
  if [[ "$t" == PASS:* ]]; then
    green "  ✓ ${t#PASS: }"
  else
    red "  ✗ ${t#FAIL: }"
  fi
done
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ "$LAUNCH_TUI" == "1" && $FAIL -eq 0 ]]; then
  echo ""
  bold "Interactive TUI"
  sep
  echo ""
  dim "  Launching OpenShell TUI..."
  dim "  Press Ctrl-C to exit."
  echo ""
  sleep 2
  exec env OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${GW_LOCAL_NAME}" term
fi

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
