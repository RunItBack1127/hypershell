#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

header "Cluster"
if ! cluster_exists; then
  warn "Cluster '${KIND_CLUSTER_NAME}' is not running"
  exit 0
fi
kubectl_kind cluster-info
if provider_is_owned_and_running; then
  info "cloud-provider-kind: ${CLOUD_PROVIDER_KIND_VERSION} (PID $(<"${PROVIDER_PID_FILE}"))"
else
  warn "cloud-provider-kind is not owned and running"
fi
echo ""

header "Networking"
kubectl_kind get gatewayclass envoy-gateway 2>/dev/null || warn "Envoy GatewayClass not found"
kubectl_kind -n envoy-gateway-system get deployments 2>/dev/null || warn "Envoy Gateway controller/data plane not found"
kubectl_kind -n hypershell-system get gateway hypershell-gw 2>/dev/null || warn "Shared Gateway not found"
kubectl_kind get httproutes,grpcroutes,backendtlspolicies -A 2>/dev/null || warn "No routes or backend TLS policies found"
kubectl_kind -n keycloak get deployment/keycloak service/keycloak-service 2>/dev/null || warn "Local Keycloak not found"
echo ""

namespaces="$(kubectl_kind get namespaces -l hypershell.redhat.io/local-development=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)"
if [[ -z "${namespaces}" ]]; then
  warn "No HyperShell deployment namespaces found"
  exit 0
fi

while IFS= read -r namespace; do
  [[ -n "${namespace}" ]] || continue
  header "Deployment ${namespace}"
  kubectl_kind -n "${namespace}" get deployments,pods,services
  swaps="${CLUSTER_STATE_DIR}/namespaces/${namespace}/swaps"
  if [[ -s "${swaps}" ]]; then
    info "Local swaps: $(paste -sd, "${swaps}")"
  else
    info "Local swaps: none"
  fi

  if [[ "${namespace}" == "hypershell-system" ]]; then
    suffix=""
  else
    suffix="${namespace#hypershell-}"
  fi
  if [[ -z "${suffix}" ]]; then
    info "API:     https://api.hypershell.localhost"
    info "Console: https://console.hypershell.localhost"
    info "Health:  https://health.hypershell.localhost"
    info "gRPC:    https://openshell-gateway.gw.localhost"
  else
    info "API:     https://api.${suffix}.hypershell.localhost"
    info "Console: https://console.${suffix}.hypershell.localhost"
    info "Health:  https://health.${suffix}.hypershell.localhost"
    info "gRPC:    https://openshell-gateway-${suffix}.gw.localhost"
  fi
  echo ""
done <<<"${namespaces}"
