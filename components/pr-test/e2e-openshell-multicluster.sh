#!/usr/bin/env bash
# e2e-openshell-multicluster.sh — multi-cluster gateway provisioning test.
#
# Proves: one HyperShell control plane → gateways on two clusters simultaneously.
# Creates a gateway on the hub cluster (local) and a gateway on a remote
# ManagedCluster, then lists both, verifies infrastructure, connects, and
# runs sandboxes across both clusters.
#
# Usage:
#   REMOTE_KUBECONFIG=/path/to/remote.kubeconfig bash e2e-openshell-multicluster.sh
#
# Environment variables:
#   OC                   oc/kubectl binary (default: oc)
#   HYPERSHELL_NAMESPACE hub API namespace (default: hypershell)
#   REMOTE_KUBECONFIG    kubeconfig for oc commands on the remote cluster (required)
#   HUB_CLUSTER_ID       ManagedCluster ID for the hub cluster (auto-detected)
#   REMOTE_CLUSTER_ID    ManagedCluster ID for the remote cluster (auto-detected)
#   HUB_GW_NAMESPACE     namespace for the hub gateway (default: openshell-hub-mc)
#   REMOTE_GW_NAMESPACE  namespace for the remote gateway (default: openshell-remote-mc)
#   GATEWAY_IMAGE        gateway image override (hub cluster)
#   SUPERVISOR_IMAGE     supervisor image override (hub cluster)
#   DB_IMAGE             database image override (hub cluster)
#   REMOTE_GATEWAY_IMAGE   gateway image on the remote registry
#   REMOTE_SUPERVISOR_IMAGE supervisor image on the remote registry
#   REMOTE_DB_IMAGE        database image on the remote registry
#   SANDBOX_TIMEOUT      seconds to wait for sandbox (default: 120)
#   PROVISION_TIMEOUT    seconds to wait for gateway provisioning (default: 300)
#   SKIP_CLEANUP         set to 1 to keep resources after test
#   PAUSE                seconds between commands (default: 1)
set -euo pipefail

CLI="${OC:-oc}"
OPENSHELL="${OPENSHELL_BIN:-openshell}"
HS_NAMESPACE="${HYPERSHELL_NAMESPACE:-hypershell}"
HUB_GW_NS="${HUB_GW_NAMESPACE:-openshell-hub-mc}"
REMOTE_GW_NS="${REMOTE_GW_NAMESPACE:-openshell-remote-mc}"
REMOTE_KUBECONFIG="${REMOTE_KUBECONFIG:-}"
REMOTE_CLUSTER_ID="${REMOTE_CLUSTER_ID:-}"
HUB_CLUSTER_ID="${HUB_CLUSTER_ID:-}"
SANDBOX_TIMEOUT="${SANDBOX_TIMEOUT:-120}"
PROVISION_TIMEOUT="${PROVISION_TIMEOUT:-300}"
SKIP_CLEANUP="${SKIP_CLEANUP:-}"
PAUSE="${PAUSE:-1}"

PASS=0
FAIL=0
TESTS=()
HUB_GW_ID=""
REMOTE_GW_ID=""
FLEET_ID=""
RELEASE_ID=""
HUB_DB_ID=""
REMOTE_DB_ID=""
HUB_ROUTE_HOST=""
REMOTE_ROUTE_HOST=""
HUB_CLI_NAME="hub-mc-openshell"
REMOTE_CLI_NAME="remote-mc-openshell"
HUB_SANDBOX=""
REMOTE_SANDBOX=""
API_HOST=""
REMOTE_API=""
CLUSTER_NAME=""

bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }
cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
orange() { printf '\033[38;5;214m%s\033[0m\n' "$*"; }
sep()    { printf '\033[2m────────────────────────────────────────────────────────────────────\033[0m\n'; }

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

remote_oc() {
  KUBECONFIG="$REMOTE_KUBECONFIG" "$CLI" --insecure-skip-tls-verify=true "$@"
}

register_gateway_cli() {
  local cli_name="$1" endpoint="$2"
  local config_dir="${HOME}/.config/openshell/gateways/${cli_name}"
  "${OPENSHELL}" gateway remove "${cli_name}" 2>/dev/null || true
  mkdir -p "${config_dir}"
  python3 -c "
import json
meta = {
    'name': '${cli_name}',
    'gateway_endpoint': '${endpoint}',
    'is_remote': True,
    'gateway_port': 0,
    'auth_mode': 'none'
}
with open('${config_dir}/metadata.json', 'w') as f:
    json.dump(meta, f, indent=2)
"
}

wait_gateway_running() {
  local gw_id="$1" label="$2"
  dim "  Waiting for ${label} to reach Running (timeout: ${PROVISION_TIMEOUT}s)..."
  local deadline=$(($(date +%s) + PROVISION_TIMEOUT))
  local phase=""
  while [[ $(date +%s) -lt $deadline ]]; do
    phase=$(curl -sk "https://${API_HOST}/api/hypershell/v1/gateways/${gw_id}" 2>/dev/null | \
      python3 -c "import json,sys; print(json.load(sys.stdin).get('phase',''))" 2>/dev/null || true)
    if [[ "$phase" == "Running" ]]; then
      break
    fi
    dim "    ${label}: phase=${phase:-unknown}"
    sleep 5
  done
  if [[ "$phase" == "Running" ]]; then
    pass "${label}: Running"
    return 0
  else
    fail_test "${label}: not running after ${PROVISION_TIMEOUT}s (phase=${phase})"
    return 1
  fi
}

wait_gateway_connected() {
  local cli_name="$1" label="$2" timeout="${3:-90}"
  dim "  Waiting for ${label} connectivity (up to ${timeout}s)..."
  local deadline=$(($(date +%s) + timeout))
  local status_output="" connected=false
  while [[ $(date +%s) -lt $deadline ]]; do
    status_output=$(OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${cli_name}" status 2>&1 || true)
    local clean=$(echo "$status_output" | sed 's/\x1b\[[0-9;]*m//g')
    if echo "$clean" | grep -qi "Connected"; then
      connected=true
      break
    fi
    sleep 5
  done
  if [[ "$connected" == "true" ]]; then
    local version=$(echo "$clean" | grep -oP 'Version:\s*\K\S+' || echo "unknown")
    pass "${label}: connected (version: ${version})"
    echo "$status_output" | while IFS= read -r line; do
      dim "      $line"
    done
    return 0
  else
    fail_test "${label}: not reachable"
    echo "$status_output" | while IFS= read -r line; do
      dim "      $line"
    done
    return 1
  fi
}

cleanup() {
  for pid_var in SB_HUB_PID SB_REMOTE_PID; do
    local pid="${!pid_var:-}"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ "$SKIP_CLEANUP" != "1" ]]; then
    dim "  Cleaning up..."
    if [[ -n "$HUB_SANDBOX" ]]; then
      OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${HUB_CLI_NAME}" sandbox delete "${HUB_SANDBOX}" 2>/dev/null || true
    fi
    if [[ -n "$REMOTE_SANDBOX" ]]; then
      OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${REMOTE_CLI_NAME}" sandbox delete "${REMOTE_SANDBOX}" 2>/dev/null || true
    fi
    if [[ -n "$HUB_GW_ID" ]]; then
      curl -sk -X DELETE "https://${API_HOST}/api/hypershell/v1/gateways/${HUB_GW_ID}" &>/dev/null || true
    fi
    if [[ -n "$REMOTE_GW_ID" ]]; then
      curl -sk -X DELETE "https://${API_HOST}/api/hypershell/v1/gateways/${REMOTE_GW_ID}" &>/dev/null || true
    fi
    sleep 5
    $CLI delete namespace "$HUB_GW_NS" --wait=false 2>/dev/null || true
    if [[ -n "$REMOTE_KUBECONFIG" ]]; then
      remote_oc delete namespace "$REMOTE_GW_NS" --wait=false 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

if [[ -z "$REMOTE_KUBECONFIG" ]]; then
  red "ERROR: REMOTE_KUBECONFIG must be set to the kubeconfig of the remote cluster"
  exit 1
fi

API_HOST=$($CLI get route hypershell-api -n "$HS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -z "$API_HOST" ]]; then
  red "ERROR: HyperShell API route not found in namespace ${HS_NAMESPACE}"
  exit 1
fi

REMOTE_API=$(remote_oc whoami --show-server 2>/dev/null || true)
HUB_API=$($CLI whoami --show-server 2>/dev/null || true)

echo ""
bold "╔══════════════════════════════════════════════════════════════════╗"
bold "║     HyperShell Multi-Cluster Gateway End-to-End Test            ║"
bold "║     One control plane, two clusters, two gateways              ║"
bold "╚══════════════════════════════════════════════════════════════════╝"
echo ""
printf '  %s\n' "1. Hub + remote cluster connectivity"
printf '  %s\n' "2. Provision gateways on BOTH clusters"
printf '  %s\n' "3. List all gateways across the fleet"
printf '  %s\n' "4. Verify infrastructure on both clusters"
printf '  %s\n' "5. Route discovery + CLI registration (both)"
printf '  %s\n' "6. Connect to both gateways"
printf '  %s\n' "7. Sandbox lifecycle on both clusters"
printf '  %s\n' "8. Sandbox interaction across clusters"
echo ""
dim  "  Hub API:              https://${API_HOST}"
dim  "  Hub K8s:              ${HUB_API:-unknown}"
dim  "  Remote K8s:           ${REMOTE_API:-unknown}"
dim  "  Hub gateway ns:       ${HUB_GW_NS}"
dim  "  Remote gateway ns:    ${REMOTE_GW_NS}"
echo ""
sep

# ── 1. Hub + remote cluster connectivity ─────────────────────────────

echo ""
bold "1. Hub + Remote Cluster Connectivity"
echo ""

show_cmd "curl -sk https://${API_HOST}/api/hypershell/v1/fleets"
FLEET_RESP=$(curl -sk "https://${API_HOST}/api/hypershell/v1/fleets" 2>/dev/null || true)
FLEET_COUNT=$(echo "$FLEET_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo 0)
if [[ "$FLEET_COUNT" -gt 0 ]]; then
  pass "Hub API reachable (${FLEET_COUNT} fleet(s))"
else
  fail_test "Hub API not reachable or no fleets"
  exit 1
fi

show_cmd "$CLI whoami"
HUB_USER=$($CLI whoami 2>/dev/null || true)
if [[ -n "$HUB_USER" ]]; then
  pass "Hub cluster reachable (user: ${HUB_USER})"
else
  fail_test "Hub cluster not reachable via oc"
  exit 1
fi

show_cmd "KUBECONFIG=\$REMOTE_KUBECONFIG oc whoami"
REMOTE_USER=$(remote_oc whoami 2>/dev/null || true)
if [[ -n "$REMOTE_USER" ]]; then
  pass "Remote cluster reachable (user: ${REMOTE_USER})"
else
  fail_test "Remote cluster not reachable"
  exit 1
fi

CLUSTERS_RESP=$(curl -sk "https://${API_HOST}/api/hypershell/v1/managed_clusters" 2>/dev/null || true)
if [[ -z "$HUB_CLUSTER_ID" ]]; then
  HUB_CLUSTER_ID=$(echo "$CLUSTERS_RESP" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for c in data.get('items', []):
    ks = c.get('kubeconfig_secret','')
    if ks == 'controller-kubeconfig' or ks == '':
        print(c['id'])
        break
" 2>/dev/null || true)
  if [[ -z "$HUB_CLUSTER_ID" ]]; then
    fail_test "No hub ManagedCluster found (set HUB_CLUSTER_ID)"
    exit 1
  fi
fi
if [[ -z "$REMOTE_CLUSTER_ID" ]]; then
  REMOTE_CLUSTER_ID=$(echo "$CLUSTERS_RESP" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for c in data.get('items', []):
    if c.get('kubeconfig_secret','') != 'controller-kubeconfig' and c.get('kubeconfig_secret','') != '':
        print(c['id'])
        break
" 2>/dev/null || true)
  if [[ -z "$REMOTE_CLUSTER_ID" ]]; then
    fail_test "No remote ManagedCluster found (set REMOTE_CLUSTER_ID)"
    exit 1
  fi
fi

CLUSTER_NAME=$(curl -sk "https://${API_HOST}/api/hypershell/v1/managed_clusters/${REMOTE_CLUSTER_ID}" 2>/dev/null | \
  python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || true)
pass "Hub ManagedCluster: ${HUB_CLUSTER_ID}"
pass "Remote ManagedCluster: ${CLUSTER_NAME} (${REMOTE_CLUSTER_ID})"
sep

# ── 2. Provision gateways on BOTH clusters ───────────────────────────

echo ""
bold "2. Provision Gateways on Both Clusters"
echo ""

FLEET_ID=$(echo "$FLEET_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('items',[])[0]['id'])" 2>/dev/null || true)

RELEASE_RESP=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/gateway_releases" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"mc-release\", \"fleet_id\": \"${FLEET_ID}\", \"image\": \"${GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/gateway:0.0.101}\"}" 2>/dev/null || true)
RELEASE_ID=$(echo "$RELEASE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

HUB_DB_RESP=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/managed_databases" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"mc-hub-db\", \"fleet_id\": \"${FLEET_ID}\", \"provider\": \"in-cluster\", \"engine\": \"postgresql\"}" 2>/dev/null || true)
HUB_DB_ID=$(echo "$HUB_DB_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

REMOTE_DB_RESP=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/managed_databases" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"mc-remote-db\", \"fleet_id\": \"${FLEET_ID}\", \"provider\": \"in-cluster\", \"engine\": \"postgresql\"}" 2>/dev/null || true)
REMOTE_DB_ID=$(echo "$REMOTE_DB_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

if [[ -z "$RELEASE_ID" || -z "$HUB_DB_ID" || -z "$REMOTE_DB_ID" ]]; then
  fail_test "Failed to create shared prerequisites"
  dim "    release=${RELEASE_ID:-FAIL} hub_db=${HUB_DB_ID:-FAIL} remote_db=${REMOTE_DB_ID:-FAIL}"
  exit 1
fi
pass "Shared prerequisites: fleet=${FLEET_ID} release=${RELEASE_ID}"
pass "  Hub DB: ${HUB_DB_ID}  Remote DB: ${REMOTE_DB_ID}"

HUB_DB_CONFIG=""
if [[ -n "${DB_IMAGE:-}" ]]; then
  HUB_DB_CONFIG=", \"database_config\": \"{\\\"image\\\":\\\"${DB_IMAGE}\\\",\\\"storage_size\\\":\\\"5Gi\\\"}\""
fi
HUB_GW_IMAGE_FIELD=""
if [[ -n "${GATEWAY_IMAGE:-}" ]]; then
  HUB_GW_IMAGE_FIELD=", \"image\": \"${GATEWAY_IMAGE}\""
fi
HUB_SUP_IMAGE_FIELD=""
if [[ -n "${SUPERVISOR_IMAGE:-}" ]]; then
  HUB_SUP_IMAGE_FIELD=", \"supervisor_image\": \"${SUPERVISOR_IMAGE}\""
fi

echo ""
cyan "  ┌─ Hub Gateway ────────────────────────────────────────────────"
show_cmd "curl -sk -X POST .../gateways -d '{name: hub-mc-gw, namespace: ${HUB_GW_NS}}'"
HUB_CREATE=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/gateways" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"hub-mc-gw\",
    \"fleet_id\": \"${FLEET_ID}\",
    \"release_id\": \"${RELEASE_ID}\",
    \"database_id\": \"${HUB_DB_ID}\",
    \"cluster_id\": \"${HUB_CLUSTER_ID}\",
    \"namespace\": \"${HUB_GW_NS}\"
    ${HUB_GW_IMAGE_FIELD}
    ${HUB_SUP_IMAGE_FIELD}
    ${HUB_DB_CONFIG}
  }" 2>/dev/null || true)
HUB_GW_KIND=$(echo "$HUB_CREATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('kind',''))" 2>/dev/null || true)
HUB_GW_ID=$(echo "$HUB_CREATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
if [[ "$HUB_GW_KIND" == "Gateway" && -n "$HUB_GW_ID" ]]; then
  pass "Hub gateway created: hub-mc-gw (${HUB_GW_ID})"
else
  fail_test "Failed to create hub gateway"
  dim "    ${HUB_CREATE:0:300}"
fi

REMOTE_DB_CONFIG=""
if [[ -n "${REMOTE_DB_IMAGE:-}" ]]; then
  REMOTE_DB_CONFIG=", \"database_config\": \"{\\\"image\\\":\\\"${REMOTE_DB_IMAGE}\\\",\\\"storage_size\\\":\\\"5Gi\\\"}\""
fi
REMOTE_GW_IMAGE_FIELD=""
if [[ -n "${REMOTE_GATEWAY_IMAGE:-}" ]]; then
  REMOTE_GW_IMAGE_FIELD=", \"image\": \"${REMOTE_GATEWAY_IMAGE}\""
fi
REMOTE_SUP_IMAGE_FIELD=""
if [[ -n "${REMOTE_SUPERVISOR_IMAGE:-}" ]]; then
  REMOTE_SUP_IMAGE_FIELD=", \"supervisor_image\": \"${REMOTE_SUPERVISOR_IMAGE}\""
fi

echo ""
cyan "  ┌─ Remote Gateway ─────────────────────────────────────────────"
show_cmd "curl -sk -X POST .../gateways -d '{name: remote-mc-gw, cluster: ${REMOTE_CLUSTER_ID}, namespace: ${REMOTE_GW_NS}}'"
REMOTE_CREATE=$(curl -sk -X POST "https://${API_HOST}/api/hypershell/v1/gateways" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"remote-mc-gw\",
    \"fleet_id\": \"${FLEET_ID}\",
    \"cluster_id\": \"${REMOTE_CLUSTER_ID}\",
    \"release_id\": \"${RELEASE_ID}\",
    \"database_id\": \"${REMOTE_DB_ID}\",
    \"namespace\": \"${REMOTE_GW_NS}\"
    ${REMOTE_GW_IMAGE_FIELD}
    ${REMOTE_SUP_IMAGE_FIELD}
    ${REMOTE_DB_CONFIG}
  }" 2>/dev/null || true)
REMOTE_GW_KIND=$(echo "$REMOTE_CREATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('kind',''))" 2>/dev/null || true)
REMOTE_GW_ID=$(echo "$REMOTE_CREATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
if [[ "$REMOTE_GW_KIND" == "Gateway" && -n "$REMOTE_GW_ID" ]]; then
  pass "Remote gateway created: remote-mc-gw (${REMOTE_GW_ID}) → cluster ${CLUSTER_NAME}"
else
  fail_test "Failed to create remote gateway"
  dim "    ${REMOTE_CREATE:0:300}"
fi

if [[ -z "$HUB_GW_ID" || -z "$REMOTE_GW_ID" ]]; then
  red "Cannot continue without both gateways"
  exit 1
fi

echo ""
dim "  Waiting for both gateways to provision in parallel..."
HUB_RUNNING=false
REMOTE_RUNNING=false
POLL_COUNT=0
DEADLINE=$(($(date +%s) + PROVISION_TIMEOUT))
while [[ $(date +%s) -lt $DEADLINE ]]; do
  POLL_COUNT=$((POLL_COUNT + 1))
  if [[ "$HUB_RUNNING" != "true" ]]; then
    HUB_RESP=$(curl -sk "https://${API_HOST}/api/hypershell/v1/gateways/${HUB_GW_ID}" 2>/dev/null || true)
    HUB_PHASE=$(echo "$HUB_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('phase',''))" 2>/dev/null || true)
    if [[ "$HUB_PHASE" == "Running" ]]; then
      HUB_RUNNING=true
    elif [[ "$HUB_PHASE" == "Failed" ]]; then
      red "    Hub gateway FAILED — check controller logs"
      break
    fi
  fi
  if [[ "$REMOTE_RUNNING" != "true" ]]; then
    REMOTE_RESP=$(curl -sk "https://${API_HOST}/api/hypershell/v1/gateways/${REMOTE_GW_ID}" 2>/dev/null || true)
    REMOTE_PHASE=$(echo "$REMOTE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('phase',''))" 2>/dev/null || true)
    if [[ "$REMOTE_PHASE" == "Running" ]]; then
      REMOTE_RUNNING=true
    elif [[ "$REMOTE_PHASE" == "Failed" ]]; then
      red "    Remote gateway FAILED — check controller logs"
      break
    fi
  fi
  if [[ "$HUB_RUNNING" == "true" && "$REMOTE_RUNNING" == "true" ]]; then
    break
  fi
  dim "    hub=${HUB_PHASE:-unknown}  remote=${REMOTE_PHASE:-unknown}"
  if [[ $POLL_COUNT -eq 6 && ( -z "${HUB_PHASE:-}" || -z "${REMOTE_PHASE:-}" ) ]]; then
    dim "    DEBUG: phase still empty after 30s — controller may not have processed the event"
    if [[ -z "${HUB_PHASE:-}" ]]; then
      dim "    DEBUG hub gateway response: ${HUB_RESP:0:200}"
    fi
    if [[ -z "${REMOTE_PHASE:-}" ]]; then
      dim "    DEBUG remote gateway response: ${REMOTE_RESP:0:200}"
    fi
    CTRL_POD=$($CLI get pods -n "$HS_NAMESPACE" -l app.kubernetes.io/name=hypershell-controller -o name 2>/dev/null | head -1 || true)
    if [[ -z "$CTRL_POD" ]]; then
      CTRL_POD=$($CLI get pods -n "$HS_NAMESPACE" -o name 2>/dev/null | grep controller | head -1 || true)
    fi
    if [[ -n "$CTRL_POD" ]]; then
      dim "    DEBUG controller last 5 log lines:"
      $CLI logs "$CTRL_POD" -n "$HS_NAMESPACE" --tail=5 2>/dev/null | while read -r line; do dim "      $line"; done
    fi
  fi
  sleep 5
done

if [[ "$HUB_RUNNING" == "true" ]]; then
  pass "Hub gateway: Running"
else
  fail_test "Hub gateway: not running (phase=${HUB_PHASE:-unknown})"
  dim "    DEBUG: ${HUB_RESP:0:300}"
fi
if [[ "$REMOTE_RUNNING" == "true" ]]; then
  pass "Remote gateway: Running"
else
  fail_test "Remote gateway: not running (phase=${REMOTE_PHASE:-unknown})"
  dim "    DEBUG: ${REMOTE_RESP:0:300}"
fi
sep

# ── 3. List all gateways across the fleet ────────────────────────────

echo ""
bold "3. Fleet Gateway Inventory"
echo ""

show_cmd "curl -sk https://${API_HOST}/api/hypershell/v1/gateways"
ALL_GW_RESP=$(curl -sk "https://${API_HOST}/api/hypershell/v1/gateways" 2>/dev/null || true)
python3 -c "
import json,sys
data = json.load(sys.stdin)
items = data.get('items', [])
total = data.get('total', len(items))
print(f'  Total gateways in fleet: {total}')
print()
fmt = '  {:<20s} {:<28s} {:<12s} {:<10s}'
print(fmt.format('NAME', 'NAMESPACE', 'CLUSTER', 'PHASE'))
print(fmt.format('─'*20, '─'*28, '─'*12, '─'*10))
for gw in items:
    name = gw.get('name','')
    ns = gw.get('namespace','')
    cid = gw.get('cluster_id','')
    phase = gw.get('phase','')
    cluster_label = '(hub)' if not cid else cid[:12]+'…'
    print(fmt.format(name, ns, cluster_label, phase))
" <<< "$ALL_GW_RESP" 2>/dev/null || true

GW_TOTAL=$(echo "$ALL_GW_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo 0)
if [[ "$GW_TOTAL" -ge 2 ]]; then
  pass "Fleet has ${GW_TOTAL} gateway(s) across clusters"
else
  fail_test "Expected at least 2 gateways, found ${GW_TOTAL}"
fi
sep

# ── 4. Verify infrastructure on both clusters ────────────────────────

echo ""
bold "4. Gateway Infrastructure (Both Clusters)"
echo ""

cyan "  ┌─ Hub Cluster ────────────────────────────────────────────────"
show_cmd "$CLI get pods -n $HUB_GW_NS"
HUB_PODS=$($CLI get pods -n "$HUB_GW_NS" --no-headers 2>/dev/null || true)
if [[ -n "$HUB_PODS" ]]; then
  HUB_GW_POD=$(echo "$HUB_PODS" | grep "openshell-gateway" | grep -v "db" | grep -v "certgen" | awk '{print $3}' | head -1)
  HUB_DB_POD=$(echo "$HUB_PODS" | grep "openshell-gateway-db" | awk '{print $3}' | head -1)
  pass "Hub pods: gateway=${HUB_GW_POD:-?} db=${HUB_DB_POD:-?}"
  echo "$HUB_PODS" | while IFS= read -r line; do dim "      $line"; done
else
  fail_test "No pods on hub cluster in ${HUB_GW_NS}"
fi

show_cmd "$CLI get route openshell-gateway -n $HUB_GW_NS"
HUB_ROUTE_HOST=$($CLI get route openshell-gateway -n "$HUB_GW_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "$HUB_ROUTE_HOST" ]]; then
  pass "Hub Route: ${HUB_ROUTE_HOST}"
else
  dim "  - No Route on hub (will use port-forward)"
fi

echo ""
cyan "  ┌─ Remote Cluster ─────────────────────────────────────────────"
show_cmd "KUBECONFIG=\$REMOTE_KUBECONFIG oc get pods -n $REMOTE_GW_NS"
REMOTE_PODS=$(remote_oc get pods -n "$REMOTE_GW_NS" --no-headers 2>/dev/null || true)
if [[ -n "$REMOTE_PODS" ]]; then
  REMOTE_GW_POD=$(echo "$REMOTE_PODS" | grep "openshell-gateway" | grep -v "db" | grep -v "certgen" | awk '{print $3}' | head -1)
  REMOTE_DB_POD=$(echo "$REMOTE_PODS" | grep "openshell-gateway-db" | awk '{print $3}' | head -1)
  pass "Remote pods: gateway=${REMOTE_GW_POD:-?} db=${REMOTE_DB_POD:-?}"
  echo "$REMOTE_PODS" | while IFS= read -r line; do dim "      $line"; done
else
  fail_test "No pods on remote cluster in ${REMOTE_GW_NS}"
fi

show_cmd "KUBECONFIG=\$REMOTE_KUBECONFIG oc get route openshell-gateway -n $REMOTE_GW_NS"
REMOTE_ROUTE_HOST=$(remote_oc get route openshell-gateway -n "$REMOTE_GW_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "$REMOTE_ROUTE_HOST" ]]; then
  pass "Remote Route: ${REMOTE_ROUTE_HOST}"
else
  dim "  - No Route on remote cluster"
fi
sep

# ── 5. Route discovery + CLI registration ────────────────────────────

echo ""
bold "5. Route Discovery + CLI Registration (Both Gateways)"
echo ""

PF_PID=""

if [[ -n "$HUB_ROUTE_HOST" ]]; then
  HUB_ENDPOINT="https://${HUB_ROUTE_HOST}:443"
else
  PF_PORT=7443
  show_cmd "$CLI port-forward -n $HUB_GW_NS svc/openshell-gateway ${PF_PORT}:8080 &"
  $CLI port-forward -n "$HUB_GW_NS" svc/openshell-gateway "${PF_PORT}":8080 &>/dev/null &
  PF_PID=$!
  sleep 3
  HUB_ENDPOINT="https://localhost:${PF_PORT}"
fi

register_gateway_cli "$HUB_CLI_NAME" "$HUB_ENDPOINT"
if [[ -f "${HOME}/.config/openshell/gateways/${HUB_CLI_NAME}/metadata.json" ]]; then
  pass "Hub CLI registered: ${HUB_CLI_NAME} → ${HUB_ENDPOINT}"
else
  fail_test "Failed to register hub gateway CLI"
fi

if [[ -n "$REMOTE_ROUTE_HOST" ]]; then
  REMOTE_ENDPOINT="https://${REMOTE_ROUTE_HOST}:443"
  register_gateway_cli "$REMOTE_CLI_NAME" "$REMOTE_ENDPOINT"
  if [[ -f "${HOME}/.config/openshell/gateways/${REMOTE_CLI_NAME}/metadata.json" ]]; then
    pass "Remote CLI registered: ${REMOTE_CLI_NAME} → ${REMOTE_ENDPOINT}"
  else
    fail_test "Failed to register remote gateway CLI"
  fi
else
  fail_test "No remote route — cannot register CLI"
fi
sep

# ── 6. Connect to both gateways ─────────────────────────────────────

echo ""
bold "6. Gateway Connectivity (Both Clusters)"
echo ""

cyan "  ┌─ Hub Gateway ────────────────────────────────────────────────"
show_cmd "OPENSHELL_GATEWAY_INSECURE=true openshell -g ${HUB_CLI_NAME} status"
wait_gateway_connected "$HUB_CLI_NAME" "Hub gateway" 90 || true

echo ""
cyan "  ┌─ Remote Gateway ─────────────────────────────────────────────"
show_cmd "OPENSHELL_GATEWAY_INSECURE=true openshell -g ${REMOTE_CLI_NAME} status"
wait_gateway_connected "$REMOTE_CLI_NAME" "Remote gateway" 90 || true
sep

# ── 7. Sandbox lifecycle on both clusters ────────────────────────────

echo ""
bold "7. Sandbox Lifecycle (Both Clusters)"
echo ""

RUN_ID=$(date +%s | tail -c5)
HUB_SANDBOX="hub-${RUN_ID}"
REMOTE_SANDBOX="remote-${RUN_ID}"

create_sandbox_and_wait() {
  local cli_name="$1" sandbox_name="$2" label="$3" get_pods_cmd="$4"

  show_cmd "OPENSHELL_GATEWAY_INSECURE=true openshell -g ${cli_name} sandbox create --name ${sandbox_name}"
  dim "  Creating sandbox on ${label} (timeout: ${SANDBOX_TIMEOUT}s)..."

  OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${cli_name}" sandbox create --name "${sandbox_name}" &>/dev/null &
  local create_pid=$!

  local deadline=$(($(date +%s) + SANDBOX_TIMEOUT))
  local found=false pod_name="" pod_status=""
  while [[ $(date +%s) -lt $deadline ]]; do
    local pods=$(eval "$get_pods_cmd" 2>/dev/null | grep -i "default--${sandbox_name}" || true)
    if [[ -n "$pods" ]]; then
      pod_status=$(echo "$pods" | awk '{print $3}' | head -1)
      pod_name=$(echo "$pods" | awk '{print $1}' | head -1)
      if [[ "$pod_status" == "Running" ]]; then
        found=true
        break
      fi
      dim "      pod: ${pod_name} (${pod_status})"
    fi
    sleep 5
  done

  kill "$create_pid" 2>/dev/null || true
  wait "$create_pid" 2>/dev/null || true

  if [[ "$found" == "true" ]]; then
    pass "${label} sandbox: ${pod_name} (${pod_status})"
  else
    local pods=$(eval "$get_pods_cmd" 2>/dev/null | grep -i "default--${sandbox_name}" || true)
    if [[ -n "$pods" ]]; then
      pod_status=$(echo "$pods" | awk '{print $3}' | head -1)
      pod_name=$(echo "$pods" | awk '{print $1}' | head -1)
      pass "${label} sandbox: ${pod_name} (${pod_status})"
    else
      fail_test "${label} sandbox not found after ${SANDBOX_TIMEOUT}s"
    fi
  fi
}

cyan "  ┌─ Hub Cluster ────────────────────────────────────────────────"
create_sandbox_and_wait "$HUB_CLI_NAME" "$HUB_SANDBOX" "Hub" \
  "$CLI get pods -n $HUB_GW_NS --no-headers"

echo ""
cyan "  ┌─ Remote Cluster ─────────────────────────────────────────────"
create_sandbox_and_wait "$REMOTE_CLI_NAME" "$REMOTE_SANDBOX" "Remote" \
  "KUBECONFIG=\"$REMOTE_KUBECONFIG\" $CLI --insecure-skip-tls-verify=true get pods -n $REMOTE_GW_NS --no-headers"
sep

# ── 8. Sandbox interaction across clusters ───────────────────────────

echo ""
bold "8. Sandbox Interaction Across Clusters"
echo ""

sandbox_exec() {
  local cli_name="$1" sandbox_name="$2" label="$3"
  shift 3

  show_cmd "OPENSHELL_GATEWAY_INSECURE=true openshell -g ${cli_name} sandbox exec -n ${sandbox_name} -- $*"
  local output
  if output=$(OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${cli_name}" sandbox exec -n "${sandbox_name}" -- "$@" 2>&1); then
    local clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^ *$' | grep -v 'WARN' | tail -3)
    if [[ -n "$clean" ]]; then
      pass "${label}: command executed"
      echo "$clean" | while IFS= read -r line; do
        dim "      $line"
      done
      return 0
    fi
  fi
  fail_test "${label}: command failed"
  return 1
}

cyan "  ┌─ Hub Sandbox ────────────────────────────────────────────────"
sandbox_exec "$HUB_CLI_NAME" "$HUB_SANDBOX" "Hub uname" uname -a || true
sandbox_exec "$HUB_CLI_NAME" "$HUB_SANDBOX" "Hub hostname" hostname || true

echo ""
cyan "  ┌─ Remote Sandbox ─────────────────────────────────────────────"
sandbox_exec "$REMOTE_CLI_NAME" "$REMOTE_SANDBOX" "Remote uname" uname -a || true
sandbox_exec "$REMOTE_CLI_NAME" "$REMOTE_SANDBOX" "Remote hostname" hostname || true

echo ""
cyan "  ┌─ Cross-cluster comparison ───────────────────────────────────"
HUB_UNAME=$(OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${HUB_CLI_NAME}" sandbox exec -n "${HUB_SANDBOX}" -- uname -n 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v 'WARN' | grep -v '^ *$' | tail -1 || true)
REMOTE_UNAME=$(OPENSHELL_GATEWAY_INSECURE=true "${OPENSHELL}" -g "${REMOTE_CLI_NAME}" sandbox exec -n "${REMOTE_SANDBOX}" -- uname -n 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v 'WARN' | grep -v '^ *$' | tail -1 || true)
echo ""
dim "    Hub sandbox hostname:    ${HUB_UNAME:-unknown}"
dim "    Remote sandbox hostname: ${REMOTE_UNAME:-unknown}"
if [[ -n "$HUB_UNAME" && -n "$REMOTE_UNAME" && "$HUB_UNAME" != "$REMOTE_UNAME" ]]; then
  pass "Sandboxes running on different clusters (hostnames differ)"
else
  dim "  - Could not confirm distinct hostnames"
fi

if [[ -n "$PF_PID" ]]; then
  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
  PF_PID=""
fi
sep

# ── results ──────────────────────────────────────────────────────────

echo ""
bold "╔══════════════════════════════════════════════════════════════════╗"
bold "║  Multi-Cluster Results: $PASS passed, $FAIL failed"
bold "║"
bold "║  Hub:     ${HUB_GW_NS} on ${HUB_API:-hub}"
bold "║  Remote:  ${REMOTE_GW_NS} on ${CLUSTER_NAME} (${REMOTE_API:-remote})"
bold "║"
bold "║  Hub gateway:    ${HUB_ROUTE_HOST:-port-forward}"
bold "║  Remote gateway: ${REMOTE_ROUTE_HOST:-unavailable}"
bold "╚══════════════════════════════════════════════════════════════════╝"
echo ""
for t in "${TESTS[@]}"; do
  if [[ "$t" == PASS:* ]]; then
    green "  ✓ ${t#PASS: }"
  else
    red "  ✗ ${t#FAIL: }"
  fi
done
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
