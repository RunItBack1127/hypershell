#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_commands kind kubectl helm curl jq sed awk git
if [[ "${KIND_NAMESPACE}" != "hypershell-system" ]]; then
  error "make kind-up owns the default hypershell-system deployment; use make kind-deploy for additional namespaces"
  exit 1
fi

header "HyperShell Local Development Environment"
echo ""

render_kind_config() {
  local destination="$1"
  sed "s|__KIND_HOST_MOUNT_PATH__|$(sed_replacement "${KIND_HOST_MOUNT_PATH}")|g" \
    "${REPO_ROOT}/${KIND_CONFIG:-deploy/kind/kind-config.yaml}" >"${destination}"
}

header "Cluster"
if cluster_exists; then
  warn "Cluster '${KIND_CLUSTER_NAME}' already exists; reusing it"
else
  ensure_state_dirs
  rendered_config="$(mktemp "${CLUSTER_STATE_DIR}/kind-config.XXXXXX.yaml")"
  trap 'rm -f "${rendered_config}"' EXIT
  render_kind_config "${rendered_config}"
  info "Creating Kind cluster '${KIND_CLUSTER_NAME}' with ${KIND_NODE_IMAGE}..."
  kind create cluster --name "${KIND_CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" --config "${rendered_config}"
  rm -f "${rendered_config}"
  trap - EXIT
  success "Cluster created"
fi

info "Waiting for Kubernetes API server..."
api_ready=false
for attempt in $(seq 1 30); do
  if kubectl_kind get nodes >/dev/null 2>&1; then
    api_ready=true
    break
  fi
  info "API server not ready (${attempt}/30)"
  sleep 2
done
if [[ "${api_ready}" != "true" ]]; then
  error "Kubernetes API server did not become ready"
  exit 1
fi
echo ""

header "cloud-provider-kind and Gateway API CRDs"
ensure_cloud_provider_kind
wait_for_gateway_api
success "LoadBalancer provider and Gateway API CRDs ready"
echo ""

header "Envoy Gateway"
info "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION} from digest-pinned charts..."
kubectl_kind create namespace envoy-gateway-system --dry-run=client -o yaml | kubectl_kind apply -f -
helm template eg-crds "${ENVOY_GATEWAY_CRDS_CHART}" \
  --namespace envoy-gateway-system \
  --set crds.envoyGateway.enabled=true \
  | kubectl_kind apply --server-side --force-conflicts -f -
helm upgrade --install eg "${ENVOY_GATEWAY_CHART}" \
  --kube-context "$(kctx)" \
  --namespace envoy-gateway-system \
  --create-namespace \
  --set crds.enabled=false \
  --set-string "global.images.envoyGateway.image=${ENVOY_GATEWAY_IMAGE}" \
  --set-string "global.images.envoyProxy.image=${ENVOY_PROXY_IMAGE}" \
  --set-string "global.images.ratelimit.image=${ENVOY_RATELIMIT_IMAGE}" \
  --wait \
  --timeout 5m
wait_for_deployment envoy-gateway-system envoy-gateway 300s
kubectl_kind apply -f "${REPO_ROOT}/deploy/kind/prerequisites/envoy-gateway-class.yaml"
gateway_class_ready=false
for _ in $(seq 1 90); do
  if [[ "$(kubectl_kind get gatewayclass envoy-gateway -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == "True" ]]; then
    gateway_class_ready=true
    break
  fi
  sleep 2
done
if [[ "${gateway_class_ready}" != "true" ]]; then
  error "Envoy GatewayClass did not become accepted"
  kubectl_kind describe gatewayclass envoy-gateway >&2 || true
  kubectl_kind -n envoy-gateway-system logs deployment/envoy-gateway --tail=120 >&2 || true
  exit 1
fi
success "Envoy Gateway controller ready"
echo ""

header "cert-manager"
info "Applying cert-manager ${CERT_MANAGER_VERSION}..."
kubectl_kind apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
  wait_for_deployment cert-manager "${deployment}" 240s
done
success "cert-manager ready"
echo ""

if [[ "${LOCAL_IMAGES:-}" == "true" ]]; then
  header "Local baseline images"
  if [[ -z "${CONTAINER_ENGINE}" ]]; then
    error "LOCAL_IMAGES=true requires Podman or Docker"
    exit 1
  fi
  "${SCRIPT_DIR}/build-images.sh"
  echo ""
else
  header "Registry baseline images"
  if [[ -z "${CONTAINER_ENGINE}" ]]; then
    error "Pulling baseline images requires Podman or Docker"
    exit 1
  fi
  ensure_state_dirs
  for image in "${api_server_ref}" "${control_plane_ref}" "${web_console_ref}"; do
    info "Pulling ${image}..."
    "${CONTAINER_ENGINE}" pull "${image}"
    baseline_archive="$(mktemp "${CLUSTER_STATE_DIR}/baseline-image.XXXXXX.tar")"
    "${CONTAINER_ENGINE}" save --output "${baseline_archive}" "${image}"
    kind load image-archive "${baseline_archive}" --name "${KIND_CLUSTER_NAME}"
    rm -f "${baseline_archive}"
  done
  success "Latest baseline images loaded into ${KIND_CLUSTER_NAME}"
  echo ""
fi

header "Cluster prerequisites"
apply_manifest deploy/kind/namespace.yaml

info "Deploying in-cluster Keycloak..."
if [[ -z "${CONTAINER_ENGINE}" ]]; then
  error "Building the pinned local Keycloak prerequisite requires Podman or Docker"
  exit 1
fi
"${CONTAINER_ENGINE}" build --tag "${keycloak_local}" \
  --file "${REPO_ROOT}/deploy/kind/prerequisites/Dockerfile.keycloak" \
  "${REPO_ROOT}/deploy/kind/prerequisites"
keycloak_archive="$(mktemp "${CLUSTER_STATE_DIR}/keycloak-image.XXXXXX.tar")"
"${CONTAINER_ENGINE}" save --output "${keycloak_archive}" "${keycloak_local}"
kind load image-archive "${keycloak_archive}" --name "${KIND_CLUSTER_NAME}"
rm -f "${keycloak_archive}"
kubectl_kind create namespace keycloak --dry-run=client -o yaml | kubectl_kind apply -f -
apply_manifest deploy/kind/prerequisites/keycloak.yaml
wait_for_deployment keycloak keycloak 300s
success "Keycloak workload ready; external access will use the shared Gateway"
configure_cluster_dns

info "Issuing local routing certificates..."
apply_manifest deploy/kind/prerequisites/certificates.yaml
for certificate in hypershell-ca hypershell-https-tls hypershell-gw-tls; do
  kubectl_kind -n hypershell-system wait --for=condition=Ready "certificate/${certificate}" --timeout=180s
done
kubectl_kind -n hypershell-system get secret hypershell-ca-secret \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode >"${LOCAL_CA_FILE}"
chmod 0644 "${LOCAL_CA_FILE}"
success "Local CA exported to ${LOCAL_CA_FILE}"

info "Creating shared networking Gateway..."
existing_gateway_class="$(kubectl_kind -n hypershell-system get gateway hypershell-gw -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null || true)"
if [[ -n "${existing_gateway_class}" && "${existing_gateway_class}" != "envoy-gateway" ]]; then
  info "Replacing the shared Gateway to migrate from GatewayClass ${existing_gateway_class}..."
  kubectl_kind -n hypershell-system delete gateway hypershell-gw --wait=true
fi
apply_manifest deploy/kind/prerequisites/networking-gateway.yaml
gateway_ready=false
for attempt in $(seq 1 90); do
  accepted="$(kubectl_kind -n hypershell-system get gateway hypershell-gw -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  programmed="$(kubectl_kind -n hypershell-system get gateway hypershell-gw -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  address="$(kubectl_kind -n hypershell-system get gateway hypershell-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [[ "${accepted}" == "True" && "${programmed}" == "True" && -n "${address}" ]]; then
    gateway_ready=true
    break
  fi
  if (( attempt % 10 == 0 )); then
    info "Networking Gateway not ready (${attempt}/90)"
  fi
  sleep 2
done
if [[ "${gateway_ready}" != "true" ]]; then
  error "Networking Gateway did not become Programmed"
  kubectl_kind -n hypershell-system describe gateway hypershell-gw >&2 || true
  kubectl_kind -n envoy-gateway-system logs deployment/envoy-gateway --tail=120 >&2 || true
  tail -120 "${PROVIDER_LOG_FILE}" >&2 || true
  exit 1
fi
success "Shared networking Gateway ready at ${address}"
echo ""

"${SCRIPT_DIR}/deploy-namespace.sh" internal

echo ""
header "HyperShell is running"
info "HTTP API:     https://${API_HOSTNAME}"
info "Web Console:  https://${CONSOLE_HOSTNAME}"
info "Health:       https://${HEALTH_HOSTNAME}"
info "Gateway gRPC: https://${GATEWAY_HOSTNAME}"
info "Keycloak:     http://${KEYCLOAK_HOSTNAME}:${KIND_KEYCLOAK_PORT} (admin/admin)"
info "OIDC issuer:  http://${KEYCLOAK_HOSTNAME}:${KIND_KEYCLOAK_PORT}/realms/hypershell"
info "CLI trust:    export SSL_CERT_FILE=${LOCAL_CA_FILE}"
