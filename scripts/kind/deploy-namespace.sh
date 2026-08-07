#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
ACTION="${1:-deploy}"

if [[ "${ACTION}" == "deploy" ]]; then
  branch="$(git -C "${REPO_ROOT}" branch --show-current)"
  sanitized="$(printf '%s' "${branch}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//; s/--*/-/g' | cut -c1-50)"
  if [[ -z "${sanitized}" ]]; then
    printf 'ERROR: current branch does not produce a valid namespace name\n' >&2
    exit 1
  fi
  export KIND_NAMESPACE="hypershell-${sanitized}"
fi

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_commands kubectl curl jq base64 grep sed tr wc
require_cluster

if [[ "${ACTION}" == "undeploy" ]]; then
  if [[ "${KIND_NAMESPACE}" == "hypershell-system" ]]; then
    error "Cannot undeploy the default namespace. Use 'make kind-down' instead."
    exit 1
  fi
  header "Removing ${KIND_NAMESPACE}"
  kubectl_kind delete clusterrolebinding "hypershell-controller-${KIND_NAMESPACE}" --ignore-not-found
  kubectl_kind delete namespace "${GATEWAY_NAMESPACE}" --ignore-not-found --wait=true
  kubectl_kind delete namespace "${KIND_NAMESPACE}" --ignore-not-found --wait=true
  rm -rf "${NAMESPACE_STATE_DIR}"
  success "Namespace deployment removed"
  exit 0
fi

if [[ "${ACTION}" != "deploy" && "${ACTION}" != "internal" ]]; then
  error "Usage: deploy-namespace.sh [deploy|internal|undeploy]"
  exit 1
fi

ensure_state_dirs

header "Deploying HyperShell in ${KIND_NAMESPACE}"
apply_manifest deploy/kind/namespace.yaml

if [[ -n "${KIND_PULL_SECRET:-}" ]]; then
  info "Applying registry credentials in ${KIND_NAMESPACE}..."
  kubectl_kind -n "${KIND_NAMESPACE}" apply -f "${KIND_PULL_SECRET}"
fi

info "Deploying API database..."
apply_manifest deploy/kind/postgres.yaml
wait_for_deployment "${KIND_NAMESPACE}" hypershell-postgres 180s

info "Applying control-plane RBAC..."
apply_manifest deploy/kind/controller-rbac.yaml

if is_swapped api-server; then
  warn "API server is swapped; retaining its current deployment"
else
  apply_manifest deploy/kind/api-server.yaml
fi

if ! wait_for_deployment "${KIND_NAMESPACE}" hypershell-api-server 240s; then
  print_namespace_diagnostics "${KIND_NAMESPACE}"
  exit 1
fi

# The controller's watches only observe events published after they connect.
# Start it after the API gRPC endpoint is ready so initial resource creation
# cannot race the watch subscriptions.
if is_swapped control-plane; then
  warn "Control plane is swapped; retaining its current deployment"
else
  apply_manifest deploy/kind/controller.yaml
fi
if ! wait_for_deployment "${KIND_NAMESPACE}" hypershell-controller 240s; then
  print_namespace_diagnostics "${KIND_NAMESPACE}"
  exit 1
fi

if is_swapped web-console; then
  warn "Web console is swapped; retaining its current deployment"
else
  apply_manifest deploy/kind/web-console.yaml
fi

info "Applying component routes..."
apply_manifest deploy/kind/prerequisites/httproutes.yaml

for deployment in hypershell-web-console; do
  if ! wait_for_deployment "${KIND_NAMESPACE}" "${deployment}" 240s; then
    print_namespace_diagnostics "${KIND_NAMESPACE}"
    exit 1
  fi
done

wait_for_http_route() {
  local namespace="$1" route="$2"
  local route_json generation
  for _ in $(seq 1 90); do
    route_json="$(kubectl_kind -n "${namespace}" get httproute "${route}" -o json 2>/dev/null || true)"
    generation="$(jq '.metadata.generation // 0' <<<"${route_json}" 2>/dev/null || printf '0')"
    if jq -e --argjson generation "${generation}" '
      [.status.parents[]?.conditions[]? | select(
        (.type == "Accepted" or .type == "ResolvedRefs") and
        .status == "True" and .observedGeneration == $generation
      ) | .type] | unique | length == 2
    ' <<<"${route_json}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  error "HTTPRoute ${namespace}/${route} was not accepted with resolved references"
  kubectl_kind -n "${namespace}" describe httproute "${route}" >&2 || true
  return 1
}

info "Waiting for component HTTPRoutes..."
for route in api-server web-console health; do
  wait_for_http_route "${KIND_NAMESPACE}" "${route}"
done
wait_for_http_route keycloak keycloak

route_ca="$(mktemp "${NAMESPACE_STATE_DIR}/route-ca.XXXXXX.crt")"
trap 'rm -f "${route_ca}"' EXIT
kubectl_kind -n hypershell-system get secret hypershell-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 --decode >"${route_ca}"
API_URL="https://${API_HOSTNAME}"

api_request() {
  local method="$1" path="$2" data="${3:-}"
  local body_file http_code
  body_file="$(mktemp "${NAMESPACE_STATE_DIR}/api-response.XXXXXX.json")"
  local -a args=(--silent --show-error --resolve "${API_HOSTNAME}:443:127.0.0.1" --cacert "${route_ca}" --output "${body_file}" --write-out '%{http_code}' --request "${method}" "${API_URL}/api/hypershell/v1${path}")
  if [[ -n "${data}" ]]; then
    args+=(--header 'Content-Type: application/json' --data "${data}")
  fi
  if ! http_code="$(curl "${args[@]}")"; then
    error "${method} ${path} could not reach the API through its HTTPRoute"
    rm -f "${body_file}"
    return 1
  fi
  API_RESPONSE="$(<"${body_file}")"
  rm -f "${body_file}"
  if [[ ! "${http_code}" =~ ^2 ]]; then
    error "${method} ${path} returned HTTP ${http_code}: ${API_RESPONSE}"
    return 1
  fi
}

reconcile_api_resource() {
  local endpoint="$1" name="$2" create_body="$3" patch_body="$4"
  api_request GET "/${endpoint}?size=100"
  local matches count resource_id
  matches="$(jq -c --arg name "${name}" '[.items[]? | select(.name == $name)]' <<<"${API_RESPONSE}")"
  count="$(jq 'length' <<<"${matches}")"
  if (( count > 1 )); then
    error "Found ${count} ${endpoint} resources named ${name}; refusing an ambiguous reconciliation"
    return 1
  fi
  if (( count == 1 )); then
    resource_id="$(jq -r '.[0].id' <<<"${matches}")"
    api_request PATCH "/${endpoint}/${resource_id}" "${patch_body}"
  else
    api_request POST "/${endpoint}" "${create_body}"
    resource_id="$(jq -r '.id // empty' <<<"${API_RESPONSE}")"
  fi
  if [[ -z "${resource_id}" || "${resource_id}" == "null" ]]; then
    error "The API did not return an id for ${endpoint}/${name}"
    return 1
  fi
  RECONCILED_ID="${resource_id}"
}

header "Reconciling local API resource graph"

fleet_body="$(jq -nc --arg name local-development '{name:$name, description:"Kind local development", status:"Ready"}')"
reconcile_api_resource fleets local-development "${fleet_body}" "${fleet_body}"
fleet_id="${RECONCILED_ID}"

cluster_body="$(jq -nc --arg name local-kind --arg fleet "${fleet_id}" '{name:$name, fleet_id:$fleet, provider:"kind", kubeconfig_secret:"local-kind", region:"local", status:"Ready"}')"
reconcile_api_resource managed_clusters local-kind "${cluster_body}" "${cluster_body}"
cluster_id="${RECONCILED_ID}"

release_body="$(jq -nc --arg name local-development --arg fleet "${fleet_id}" --arg image "${KIND_GATEWAY_IMAGE}" '{name:$name, fleet_id:$fleet, image:$image, rollout_strategy:"immediate", status:"Ready"}')"
reconcile_api_resource gateway_releases local-development "${release_body}" "${release_body}"
release_id="${RECONCILED_ID}"

database_body="$(jq -nc --arg name local-postgres --arg fleet "${fleet_id}" '{name:$name, fleet_id:$fleet, provider:"local", engine:"postgresql", engine_version:"16", region:"local", status:"Ready"}')"
reconcile_api_resource managed_databases local-postgres "${database_body}" "${database_body}"
database_id="${RECONCILED_ID}"

gateway_body="$(jq -nc \
  --arg name openshell-gateway \
  --arg fleet "${fleet_id}" \
  --arg cluster "${cluster_id}" \
  --arg release "${release_id}" \
  --arg database "${database_id}" \
  --arg namespace "${GATEWAY_NAMESPACE}" \
  --arg external_dns "${GATEWAY_HOSTNAME}" \
  '{name:$name, fleet_id:$fleet, cluster_id:$cluster, release_id:$release, database_id:$database, namespace:$namespace, external_dns:$external_dns, tls_mode:"tls", service_type:"ClusterIP", status:"Ready"}')"
gateway_patch="$(jq -c '. + {phase:""}' <<<"${gateway_body}")"
reconcile_api_resource gateways openshell-gateway "${gateway_body}" "${gateway_patch}"
gateway_id="${RECONCILED_ID}"

info "Waiting for Gateway ${gateway_id} to reach Running..."
gateway_running=false
for attempt in $(seq 1 180); do
  api_request GET "/gateways/${gateway_id}"
  phase="$(jq -r '.phase // ""' <<<"${API_RESPONSE}")"
  if [[ "${phase}" == "Running" ]]; then
    gateway_running=true
    break
  fi
  if [[ "${phase}" == "Failed" ]]; then
    error "Gateway reconciliation entered Failed phase"
    kubectl_kind -n "${KIND_NAMESPACE}" logs deployment/hypershell-controller --tail=160 >&2 || true
    break
  fi
  if (( attempt % 15 == 0 )); then
    info "Gateway phase is ${phase:-pending} (${attempt}/180)"
  fi
  sleep 2
done
if [[ "${gateway_running}" != "true" ]]; then
  print_namespace_diagnostics "${GATEWAY_NAMESPACE}"
  exit 1
fi

for deployment in openshell-gateway-db openshell-gateway; do
  wait_for_deployment "${GATEWAY_NAMESPACE}" "${deployment}" 180s
done

route_accepted=false
for _ in $(seq 1 90); do
  route_json="$(kubectl_kind -n "${GATEWAY_NAMESPACE}" get grpcroute openshell-gateway -o json 2>/dev/null || true)"
  if jq -e --argjson generation "$(jq '.metadata.generation' <<<"${route_json}")" '
    [.status.parents[]?.conditions[]? | select(
      (.type == "Accepted" or .type == "ResolvedRefs") and
      .status == "True" and .observedGeneration == $generation
    ) | .type] | unique | length == 2
  ' <<<"${route_json}" >/dev/null 2>&1; then
    route_accepted=true
    break
  fi
  sleep 2
done
if [[ "${route_accepted}" != "true" ]]; then
  error "OpenShell GRPCRoute was not accepted"
  kubectl_kind -n "${GATEWAY_NAMESPACE}" describe grpcroute openshell-gateway >&2 || true
  exit 1
fi

backend_tls_accepted=false
for _ in $(seq 1 90); do
  backend_tls_json="$(kubectl_kind -n "${GATEWAY_NAMESPACE}" get backendtlspolicy openshell-gateway -o json 2>/dev/null || true)"
  if jq -e --argjson generation "$(jq '.metadata.generation' <<<"${backend_tls_json}")" '
    [.status.ancestors[]?.conditions[]? | select(
      (.type == "Accepted" or .type == "ResolvedRefs") and
      .status == "True" and .observedGeneration == $generation
    ) | .type] | unique | length == 2
  ' <<<"${backend_tls_json}" >/dev/null 2>&1; then
    backend_tls_accepted=true
    break
  fi
  sleep 2
done
if [[ "${backend_tls_accepted}" != "true" ]]; then
  error "OpenShell BackendTLSPolicy was not accepted"
  kubectl_kind -n "${GATEWAY_NAMESPACE}" describe backendtlspolicy openshell-gateway >&2 || true
  exit 1
fi

verify_http() {
  local label="$1"
  shift
  if ! curl --fail --silent --show-error "$@" >/dev/null; then
    error "${label} verification failed"
    return 1
  fi
  success "${label} is reachable"
}

verify_grpc_call() {
  local label="$1" hostname="$2" port="$3" ca_file="$4" method="$5" bearer_token="${6:-}"
  local headers response curl_error attempt
  local -a auth_args=()
  if [[ -n "${bearer_token}" ]]; then
    auth_args=(--header "Authorization: Bearer ${bearer_token}")
  fi
  headers="$(mktemp "${NAMESPACE_STATE_DIR}/grpc-headers.XXXXXX")"
  response="$(mktemp "${NAMESPACE_STATE_DIR}/grpc-response.XXXXXX")"
  curl_error="$(mktemp "${NAMESPACE_STATE_DIR}/grpc-error.XXXXXX")"

  for attempt in $(seq 1 30); do
    : >"${headers}"
    : >"${response}"
    : >"${curl_error}"
    if printf '\x00\x00\x00\x00\x00' | curl \
      --http2 \
      --silent \
      --show-error \
      --resolve "${hostname}:${port}:127.0.0.1" \
      --cacert "${ca_file}" \
      --header 'Content-Type: application/grpc' \
      --header 'TE: trailers' \
      "${auth_args[@]}" \
      --data-binary @- \
      --dump-header "${headers}" \
      --output "${response}" \
      "https://${hostname}:${port}/${method}" 2>"${curl_error}" \
      && tr -d '\r' <"${headers}" | grep -Fqx 'grpc-status: 0' \
      && (( $(wc -c <"${response}") >= 5 )); then
      rm -f "${headers}" "${response}" "${curl_error}"
      success "${label} completed with grpc-status 0"
      return 0
    fi
    if (( attempt < 30 )); then
      sleep 1
    fi
  done

  error "${label} did not complete successfully after 30 attempts"
  if [[ -s "${curl_error}" ]]; then
    sed -n '1,80p' "${curl_error}" >&2
  elif ! tr -d '\r' <"${headers}" | grep -Fqx 'grpc-status: 0'; then
    sed -n '1,80p' "${headers}" >&2
  else
    error "${label} did not return a complete gRPC response frame"
  fi
  rm -f "${headers}" "${response}" "${curl_error}"
  return 1
}

verify_grpc_health() {
  verify_grpc_call "$1" "$2" "$3" "$4" openshell.v1.OpenShell/Health
}

header "End-to-end verification"
verify_http "Routed API" --resolve "${API_HOSTNAME}:443:127.0.0.1" --cacert "${route_ca}" "https://${API_HOSTNAME}/api/hypershell/v1/gateways"
verify_http "Routed health endpoint" --resolve "${HEALTH_HOSTNAME}:443:127.0.0.1" --cacert "${route_ca}" "https://${HEALTH_HOSTNAME}/healthcheck"
verify_http "Routed web console API proxy" --resolve "${CONSOLE_HOSTNAME}:443:127.0.0.1" --cacert "${route_ca}" "https://${CONSOLE_HOSTNAME}/api/hypershell/v1/gateways"
verify_grpc_health "Gateway GRPCRoute with backend TLS" "${GATEWAY_HOSTNAME}" 443 "${route_ca}"

oidc_issuer="http://${KEYCLOAK_HOSTNAME}:${KIND_KEYCLOAK_PORT}/realms/hypershell"
oidc_discovery="$(mktemp "${NAMESPACE_STATE_DIR}/oidc-discovery.XXXXXX.json")"
if ! curl --fail-with-body --silent --show-error \
  --output "${oidc_discovery}" \
  "${oidc_issuer}/.well-known/openid-configuration"; then
  error "Keycloak OIDC discovery failed"
  rm -f "${oidc_discovery}"
  exit 1
fi
if ! jq -e --arg issuer "${oidc_issuer}" '.issuer == $issuer' "${oidc_discovery}" >/dev/null; then
  error "Keycloak discovery document did not publish the configured canonical issuer"
  jq '{issuer}' "${oidc_discovery}" >&2 || true
  rm -f "${oidc_discovery}"
  exit 1
fi
rm -f "${oidc_discovery}"
success "In-cluster Keycloak publishes the canonical issuer"

oidc_token_response="$(mktemp "${NAMESPACE_STATE_DIR}/oidc-token.XXXXXX.json")"
if ! curl --fail-with-body --silent --show-error \
  --data-urlencode grant_type=password \
  --data-urlencode client_id=openshell-cli \
  --data-urlencode username=developer \
  --data-urlencode password=developer \
  --data-urlencode 'scope=openid profile email openshell:all' \
  --output "${oidc_token_response}" \
  "${oidc_issuer}/protocol/openid-connect/token"; then
  error "Keycloak did not issue a token for the documented developer credentials"
  jq '{error, error_description}' "${oidc_token_response}" >&2 || true
  rm -f "${oidc_token_response}"
  exit 1
fi
if ! access_token="$(jq -er '.access_token | select(type == "string" and length > 0)' "${oidc_token_response}")"; then
  error "Keycloak token response did not include an access token"
  rm -f "${oidc_token_response}"
  exit 1
fi
rm -f "${oidc_token_response}"
success "In-cluster Keycloak issued a developer access token"
verify_grpc_call \
  "Authenticated Gateway API" \
  "${GATEWAY_HOSTNAME}" \
  443 \
  "${route_ca}" \
  openshell.v1.OpenShell/ListProviders \
  "${access_token}"
rm -f "${route_ca}"
trap - EXIT

success "${KIND_NAMESPACE} is ready end to end"
