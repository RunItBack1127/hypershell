#!/usr/bin/env bash
set -euo pipefail

# Shared Kind lifecycle helpers. Every kubectl invocation goes through
# kubectl_kind so a developer's current context is never used implicitly.

if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  BOLD='\033[1m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  NC='\033[0m'
else
  BOLD='' BLUE='' CYAN='' GREEN='' YELLOW='' RED='' NC=''
fi

header()  { printf "${BOLD}${BLUE}==> %s${NC}\n" "$*"; }
info()    { printf "${CYAN}    %s${NC}\n" "$*"; }
success() { printf "${GREEN}    %s${NC}\n" "$*"; }
warn()    { printf "${YELLOW}    %s${NC}\n" "$*"; }
error()   { printf "${RED}ERROR: %s${NC}\n" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"

: "${KIND_CLUSTER_NAME:=hypershell-dev}"
: "${KIND_NAMESPACE:=hypershell-system}"
: "${KIND_HOT_RELOAD:=true}"
: "${KIND_HOST_MOUNT_PATH:=${REPO_ROOT}}"
: "${KIND_KEYCLOAK_PORT:=18080}"
: "${CLOUD_PROVIDER_KIND_VERSION:=v0.11.1}"
: "${ENVOY_GATEWAY_VERSION:=v1.8.3}"
: "${ENVOY_GATEWAY_CHART:=oci://docker.io/envoyproxy/gateway-helm@sha256:cfb34ff4266c87a394cd6be5c13607a2dd47083aef771368302eaeaa99c4a0a9}"
: "${ENVOY_GATEWAY_CRDS_CHART:=oci://docker.io/envoyproxy/gateway-crds-helm@sha256:99b14db0bc57c8f413023d66145a2c53e8ed47f85fe0163b675c04165ff242d4}"
: "${ENVOY_GATEWAY_IMAGE:=docker.io/envoyproxy/gateway:v1.8.3@sha256:e7a8c70537628bf996e5dec5c4c835704b4b9f4f715a74cf361bea30608c49ac}"
: "${ENVOY_PROXY_IMAGE:=docker.io/envoyproxy/envoy:distroless-v1.38.3@sha256:574348fada8eb1130b448132287d76626dfb07525b16668075382f8e154a45a8}"
: "${ENVOY_RATELIMIT_IMAGE:=docker.io/envoyproxy/ratelimit:1e50889b@sha256:5bb3741fd6709bab1d498eae1a5807faa2113b712dfb236fb76c04a00871ffc9}"
: "${CERT_MANAGER_VERSION:=v1.21.1}"
: "${KIND_NODE_IMAGE:=docker.io/kindest/node:v1.35.0@sha256:4613778f3cfcd10e615029370f5786704559103cf27bef934597ba562b269661}"
: "${KIND_POSTGRES_IMAGE:=docker.io/library/postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b}"
: "${KIND_DB_IMAGE:=${KIND_POSTGRES_IMAGE}}"
: "${KIND_GATEWAY_IMAGE:=ghcr.io/nvidia/openshell/gateway:0.0.92@sha256:6a789b7cba7a121245687653a3f7e7781fd569f495b3bf7f2a43ea1387d20d22}"
: "${CONTAINER_ENGINE:=$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}"

: "${api_server_ref:=quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main/hypershell-api-server-main:latest}"
: "${control_plane_ref:=quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main/hypershell-control-plane-main:latest}"
: "${web_console_ref:=quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main/hypershell-web-console-main:latest}"
: "${api_server_local:=localhost/hypershell-api-server:dev}"
: "${control_plane_local:=localhost/hypershell-control-plane:dev}"
: "${web_console_local:=localhost/hypershell-web-console:dev}"
: "${api_server_baseline_local:=localhost/hypershell-api-server:baseline}"
: "${control_plane_baseline_local:=localhost/hypershell-control-plane:baseline}"
: "${web_console_baseline_local:=localhost/hypershell-web-console:baseline}"
: "${web_console_dev_local:=localhost/hypershell-web-console-dev:dev}"
: "${keycloak_local:=localhost/hypershell-keycloak:26.0}"

if [[ "${LOCAL_IMAGES:-}" == "true" ]]; then
  api_server_ref="${api_server_baseline_local}"
  control_plane_ref="${control_plane_baseline_local}"
  web_console_ref="${web_console_baseline_local}"
fi

if [[ -n "${LOCAL_IMAGES:-}" && ! "${LOCAL_IMAGES}" =~ ^(true|false)$ ]]; then
  error "LOCAL_IMAGES must be true or false"
  exit 1
fi
if [[ ! "${KIND_HOT_RELOAD}" =~ ^(true|false)$ ]]; then
  error "KIND_HOT_RELOAD must be true or false"
  exit 1
fi
if [[ ! "${KIND_CLUSTER_NAME}" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
  error "KIND_CLUSTER_NAME must contain only lowercase letters, digits, dots, and hyphens"
  exit 1
fi
if [[ ! "${KIND_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || (( ${#KIND_NAMESPACE} > 63 )); then
  error "KIND_NAMESPACE is not a valid Kubernetes namespace: ${KIND_NAMESPACE}"
  exit 1
fi
for port_value in "${KIND_KEYCLOAK_PORT}"; do
  if [[ ! "${port_value}" =~ ^[1-9][0-9]*$ ]] || (( port_value > 65535 )); then
    error "KIND_KEYCLOAK_PORT must be an integer between 1 and 65535: ${port_value}"
    exit 1
  fi
done

STATE_ROOT="${KIND_STATE_ROOT:-${TMPDIR:-/tmp}/hypershell-kind-${UID}}"
CLUSTER_STATE_DIR="${STATE_ROOT}/clusters/${KIND_CLUSTER_NAME}"
LOCAL_CA_FILE="${CLUSTER_STATE_DIR}/hypershell-ca.crt"
NAMESPACE_STATE_DIR="${CLUSTER_STATE_DIR}/namespaces/${KIND_NAMESPACE}"
PROVIDER_STATE_DIR="${STATE_ROOT}/cloud-provider-kind"
PROVIDER_PID_FILE="${PROVIDER_STATE_DIR}/pid"
PROVIDER_VERSION_FILE="${PROVIDER_STATE_DIR}/version"
PROVIDER_LOG_FILE="${PROVIDER_STATE_DIR}/cloud-provider-kind.log"
PROVIDER_OWNERS_DIR="${PROVIDER_STATE_DIR}/owners"
SWAP_FILE="${NAMESPACE_STATE_DIR}/swaps"

namespace_suffix() {
  if [[ "${KIND_NAMESPACE}" == "hypershell-system" ]]; then
    printf '%s' ""
  else
    printf '%s' "${KIND_NAMESPACE#hypershell-}"
  fi
}

NAMESPACE_SUFFIX="$(namespace_suffix)"
if [[ -z "${NAMESPACE_SUFFIX}" ]]; then
  : "${API_HOSTNAME:=api.hypershell.localhost}"
  : "${CONSOLE_HOSTNAME:=console.hypershell.localhost}"
  : "${HEALTH_HOSTNAME:=health.hypershell.localhost}"
  : "${GATEWAY_NAMESPACE:=openshell-gateway}"
  : "${GATEWAY_HOSTNAME:=openshell-gateway.gw.localhost}"
else
  : "${API_HOSTNAME:=api.${NAMESPACE_SUFFIX}.hypershell.localhost}"
  : "${CONSOLE_HOSTNAME:=console.${NAMESPACE_SUFFIX}.hypershell.localhost}"
  : "${HEALTH_HOSTNAME:=health.${NAMESPACE_SUFFIX}.hypershell.localhost}"
  gateway_suffix="$(printf '%s' "${NAMESPACE_SUFFIX}" | cut -c1-45)"
  : "${GATEWAY_NAMESPACE:=openshell-gateway-${gateway_suffix}}"
  : "${GATEWAY_HOSTNAME:=openshell-gateway-${gateway_suffix}.gw.localhost}"
fi
: "${KEYCLOAK_HOSTNAME:=keycloak.hypershell.localhost}"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER_NAME}"
}

require_cluster() {
  if ! cluster_exists; then
    error "No Kind cluster '${KIND_CLUSTER_NAME}' is running. Run 'make kind-up' first."
    exit 1
  fi
}

kctx() {
  printf 'kind-%s\n' "${KIND_CLUSTER_NAME}"
}

kubectl_kind() {
  kubectl --context "$(kctx)" "$@"
}

require_commands() {
  local missing=()
  local command_name
  for command_name in "$@"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing+=("${command_name}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    error "Missing required commands: ${missing[*]}"
    exit 1
  fi
}

ensure_state_dirs() {
  mkdir -p "${NAMESPACE_STATE_DIR}" "${PROVIDER_OWNERS_DIR}"
}

sed_replacement() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

image_revision() {
  local image="$1" revision=""
  if [[ -n "${CONTAINER_ENGINE}" ]]; then
    revision="$(${CONTAINER_ENGINE} image inspect --format '{{.Id}}' "${image}" 2>/dev/null || true)"
  fi
  printf '%s' "${revision:-${image}}"
}

render_manifest() {
  local manifest="$1"
  local image_pull_policy="IfNotPresent"
  local rendered
  if [[ "${api_server_ref}" == localhost/* ]] || [[ "${api_server_ref}" == *:dev ]]; then
    image_pull_policy="Never"
  fi

  rendered="$(sed \
    -e "s|GATEWAY_NAMESPACE_PLACEHOLDER|$(sed_replacement "${GATEWAY_NAMESPACE}")|g" \
    -e "s|NAMESPACE_PLACEHOLDER|$(sed_replacement "${KIND_NAMESPACE}")|g" \
    -e "s|API_IMAGE_PLACEHOLDER|$(sed_replacement "${api_server_ref}")|g" \
    -e "s|CONTROL_PLANE_IMAGE_PLACEHOLDER|$(sed_replacement "${control_plane_ref}")|g" \
    -e "s|WEB_CONSOLE_IMAGE_PLACEHOLDER|$(sed_replacement "${web_console_ref}")|g" \
    -e "s|API_IMAGE_REVISION_PLACEHOLDER|$(sed_replacement "$(image_revision "${api_server_ref}")")|g" \
    -e "s|CONTROL_PLANE_IMAGE_REVISION_PLACEHOLDER|$(sed_replacement "$(image_revision "${control_plane_ref}")")|g" \
    -e "s|WEB_CONSOLE_IMAGE_REVISION_PLACEHOLDER|$(sed_replacement "$(image_revision "${web_console_ref}")")|g" \
    -e "s|KEYCLOAK_IMAGE_PLACEHOLDER|$(sed_replacement "${keycloak_local}")|g" \
    -e "s|KEYCLOAK_IMAGE_REVISION_PLACEHOLDER|$(sed_replacement "$(image_revision "${keycloak_local}")")|g" \
    -e "s|KEYCLOAK_CONFIG_REVISION_PLACEHOLDER|$(sed_replacement "$(git -C "${REPO_ROOT}" hash-object deploy/kind/prerequisites/keycloak.yaml)")|g" \
    -e "s|POSTGRES_IMAGE_PLACEHOLDER|$(sed_replacement "${KIND_POSTGRES_IMAGE}")|g" \
    -e "s|GATEWAY_DATABASE_IMAGE_PLACEHOLDER|$(sed_replacement "${KIND_DB_IMAGE}")|g" \
    -e "s|IMAGE_PULL_POLICY_PLACEHOLDER|${image_pull_policy}|g" \
    -e "s|API_HOSTNAME_PLACEHOLDER|$(sed_replacement "${API_HOSTNAME}")|g" \
    -e "s|CONSOLE_HOSTNAME_PLACEHOLDER|$(sed_replacement "${CONSOLE_HOSTNAME}")|g" \
    -e "s|HEALTH_HOSTNAME_PLACEHOLDER|$(sed_replacement "${HEALTH_HOSTNAME}")|g" \
    -e "s|KEYCLOAK_HOSTNAME_PLACEHOLDER|$(sed_replacement "${KEYCLOAK_HOSTNAME}")|g" \
    -e "s|KEYCLOAK_PORT_PLACEHOLDER|$(sed_replacement "${KIND_KEYCLOAK_PORT}")|g" \
    "${REPO_ROOT}/${manifest}")"

  if grep -Eq '[A-Z][A-Z0-9_]*_PLACEHOLDER' <<<"${rendered}"; then
    error "Manifest ${manifest} contains an unresolved template placeholder"
    grep -Eo '[A-Z][A-Z0-9_]*_PLACEHOLDER' <<<"${rendered}" | sort -u >&2
    return 1
  fi
  printf '%s\n' "${rendered}"
}

apply_manifest() {
  render_manifest "$1" | kubectl_kind apply -f -
}

delete_manifest() {
  render_manifest "$1" | kubectl_kind delete --ignore-not-found -f -
}

track_swap() {
  local component="$1"
  ensure_state_dirs
  grep -Fxq "${component}" "${SWAP_FILE}" 2>/dev/null || printf '%s\n' "${component}" >>"${SWAP_FILE}"
}

clear_swap() {
  local component="$1"
  if [[ -f "${SWAP_FILE}" ]]; then
    local temporary="${SWAP_FILE}.new"
    grep -Fxv "${component}" "${SWAP_FILE}" >"${temporary}" || true
    mv "${temporary}" "${SWAP_FILE}"
  fi
}

is_swapped() {
  local component="$1"
  grep -Fxq "${component}" "${SWAP_FILE}" 2>/dev/null
}

wait_for_deployment() {
  local namespace="$1" deployment="$2" timeout="${3:-180s}"
  kubectl_kind -n "${namespace}" rollout status "deployment/${deployment}" --timeout="${timeout}"
}

print_namespace_diagnostics() {
  local namespace="$1"
  warn "Diagnostics for namespace ${namespace}:"
  kubectl_kind -n "${namespace}" get pods,deployments,services 2>/dev/null || true
  kubectl_kind -n "${namespace}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
}

cloud_provider_kind_installed_version() {
  local binary
  binary="$(command -v cloud-provider-kind 2>/dev/null || true)"
  if [[ -z "${binary}" ]]; then
    return 1
  fi
  local reported
  reported="$(cloud-provider-kind version 2>/dev/null | awk 'NF >= 2 {print $2; exit}')"
  if [[ -n "${reported}" ]]; then
    printf '%s\n' "${reported}"
    return 0
  fi
  go version -m "${binary}" 2>/dev/null | awk '$1 == "mod" && $2 == "sigs.k8s.io/cloud-provider-kind" {print $3; exit}'
}

provider_is_owned_and_running() {
  [[ -s "${PROVIDER_PID_FILE}" && -s "${PROVIDER_VERSION_FILE}" ]] || return 1
  local pid
  pid="$(<"${PROVIDER_PID_FILE}")"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  [[ "$(<"${PROVIDER_VERSION_FILE}")" == "${CLOUD_PROVIDER_KIND_VERSION}" ]] || return 1
  ps -p "${pid}" -o command= 2>/dev/null | grep -q '[c]loud-provider-kind' || return 1
}

ensure_cloud_provider_kind() {
  require_commands cloud-provider-kind go
  local installed_version
  installed_version="$(cloud_provider_kind_installed_version || true)"
  if [[ "${installed_version}" != "${CLOUD_PROVIDER_KIND_VERSION}" ]]; then
    error "cloud-provider-kind ${CLOUD_PROVIDER_KIND_VERSION} is required; found '${installed_version:-none}'"
    info "Install exactly: go install sigs.k8s.io/cloud-provider-kind@${CLOUD_PROVIDER_KIND_VERSION}"
    exit 1
  fi

  ensure_state_dirs
  if provider_is_owned_and_running; then
    info "Reusing owned cloud-provider-kind process (PID $(<"${PROVIDER_PID_FILE}"))"
  else
    if [[ -f "${PROVIDER_PID_FILE}" ]]; then
      warn "Removing stale cloud-provider-kind ownership state"
      rm -f "${PROVIDER_PID_FILE}" "${PROVIDER_VERSION_FILE}"
    fi
    if pgrep -f '(^|/)cloud-provider-kind([[:space:]]|$)' >/dev/null 2>&1; then
      error "An unmanaged cloud-provider-kind process is already running. Stop it explicitly before continuing."
      exit 1
    fi
    info "Starting cloud-provider-kind ${CLOUD_PROVIDER_KIND_VERSION}..."
    local -a provider_command=(cloud-provider-kind --gateway-channel experimental --enable-lb-port-mapping --enable-default-ingress=false)
    if [[ "$(uname -s)" == "Darwin" ]]; then
      sudo -v
      provider_command=(sudo "${provider_command[@]}")
    fi
    if command -v setsid >/dev/null 2>&1; then
      nohup setsid "${provider_command[@]}" </dev/null >"${PROVIDER_LOG_FILE}" 2>&1 &
    else
      nohup "${provider_command[@]}" </dev/null >"${PROVIDER_LOG_FILE}" 2>&1 &
    fi
    local provider_pid=$!
    printf '%s\n' "${provider_pid}" >"${PROVIDER_PID_FILE}"
    printf '%s\n' "${CLOUD_PROVIDER_KIND_VERSION}" >"${PROVIDER_VERSION_FILE}"
    sleep 2
    if ! provider_is_owned_and_running; then
      error "cloud-provider-kind exited during startup"
      tail -80 "${PROVIDER_LOG_FILE}" >&2 || true
      exit 1
    fi
  fi
  : >"${PROVIDER_OWNERS_DIR}/${KIND_CLUSTER_NAME}"
}

release_cloud_provider_kind() {
  rm -f "${PROVIDER_OWNERS_DIR}/${KIND_CLUSTER_NAME}"
  if [[ -d "${PROVIDER_OWNERS_DIR}" ]] && find "${PROVIDER_OWNERS_DIR}" -mindepth 1 -maxdepth 1 -type f -print -quit | grep -q .; then
    info "cloud-provider-kind remains active for another registered cluster"
    return
  fi
  if provider_is_owned_and_running; then
    local pid
    pid="$(<"${PROVIDER_PID_FILE}")"
    info "Stopping owned cloud-provider-kind process ${pid}..."
    kill "${pid}"
    for _ in $(seq 1 20); do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "${pid}" 2>/dev/null; then
      warn "cloud-provider-kind did not stop after SIGTERM; leaving it untouched"
      return 1
    fi
  fi
  rm -f "${PROVIDER_PID_FILE}" "${PROVIDER_VERSION_FILE}"
}

wait_for_gateway_api() {
  info "Waiting for cloud-provider-kind Gateway API installation..."
  local crd
  for crd in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io grpcroutes.gateway.networking.k8s.io backendtlspolicies.gateway.networking.k8s.io; do
    kubectl_kind wait --for=condition=Established "crd/${crd}" --timeout=180s
  done
}

configure_cluster_dns() {
  local service_hostname="keycloak-service.keycloak.svc.cluster.local"
  local rewrite_line="rewrite name exact ${KEYCLOAK_HOSTNAME} ${service_hostname}"
  local corefile updated patch service_ip resolved_ip

  corefile="$(kubectl_kind -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
  if ! grep -Fq "${rewrite_line}" <<<"${corefile}"; then
    info "Configuring in-cluster resolution for ${KEYCLOAK_HOSTNAME}..."
    if ! updated="$(awk -v rewrite="${rewrite_line}" '
      BEGIN { inserted = 0 }
      /^\.:53[[:space:]]*\{/ && inserted == 0 {
        print
        print "        " rewrite
        inserted = 1
        next
      }
      { print }
      END { if (inserted == 0) exit 1 }
    ' <<<"${corefile}")"; then
      error "CoreDNS Corefile does not contain the expected root server block"
      return 1
    fi
    patch="$(jq -nc --arg corefile "${updated}" '{data:{Corefile:$corefile}}')"
    kubectl_kind -n kube-system patch configmap coredns --type=merge --patch "${patch}" >/dev/null
    kubectl_kind -n kube-system rollout restart deployment/coredns >/dev/null
  fi

  kubectl_kind -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null
  service_ip="$(kubectl_kind -n keycloak get service keycloak-service -o jsonpath='{.spec.clusterIP}')"
  resolved_ip="$(kubectl_kind -n keycloak exec deployment/keycloak -- getent hosts "${KEYCLOAK_HOSTNAME}" | awk 'NR == 1 { print $1 }')"
  if [[ "${resolved_ip}" != "${service_ip}" ]]; then
    error "${KEYCLOAK_HOSTNAME} resolved to ${resolved_ip:-nothing} in-cluster; expected ${service_ip}"
    return 1
  fi
  success "In-cluster Keycloak hostname resolves through CoreDNS"
}
