#!/usr/bin/env bash
set -euo pipefail

# Builds the OpenShell dashboard image (the per-gateway console) from the
# upstream project and loads it into the Kind cluster, alongside the oauth2-proxy
# sidecar image. The upstream project publishes no registry image, so the
# platform builds it from source and loads it locally (see the console spec
# Prerequisites). The control plane deploys openshell-dashboard:latest with
# imagePullPolicy IfNotPresent, so the loaded image is used without a registry
# pull.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Pinned upstream ref for deterministic builds. Bump deliberately when adopting
# a new dashboard contract.
: "${OPENSHELL_DASHBOARD_REPO:=https://github.com/Gkrumbach07/openshell-dashboard.git}"
: "${OPENSHELL_DASHBOARD_REF:=07f1b13ebd9e1826afe943b831b092be8bf92498}"
: "${OPENSHELL_DASHBOARD_IMAGE:=openshell-dashboard:latest}"
: "${OAUTH2_PROXY_IMAGE:=quay.io/oauth2-proxy/oauth2-proxy:v7.7.1}"

header "Building OpenShell Console (dashboard) Image"

CLONE_DIR=""
cleanup_clone() {
  if [[ -n "${CLONE_DIR}" ]] && [[ -d "${CLONE_DIR}" ]]; then
    rm -rf "${CLONE_DIR}"
  fi
}
trap cleanup_clone EXIT

CLONE_DIR=$(mktemp -d /tmp/openshell-dashboard-XXXXXX)
rm -rf "${CLONE_DIR}"
info "Cloning ${OPENSHELL_DASHBOARD_REPO} at ${OPENSHELL_DASHBOARD_REF}..."
git clone --quiet "${OPENSHELL_DASHBOARD_REPO}" "${CLONE_DIR}"
git -C "${CLONE_DIR}" checkout --quiet "${OPENSHELL_DASHBOARD_REF}"

info "Building ${OPENSHELL_DASHBOARD_IMAGE}..."
${CONTAINER_ENGINE} build -t "${OPENSHELL_DASHBOARD_IMAGE}" \
  -f "${CLONE_DIR}/deploy/Dockerfile" "${CLONE_DIR}"

info "Pulling ${OAUTH2_PROXY_IMAGE}..."
${CONTAINER_ENGINE} pull "${OAUTH2_PROXY_IMAGE}"

success "Console images built"

if cluster_exists; then
  info "Loading console images into Kind cluster ${KIND_CLUSTER_NAME}..."
  kind load docker-image "${OPENSHELL_DASHBOARD_IMAGE}" --name "${KIND_CLUSTER_NAME}"
  kind load docker-image "${OAUTH2_PROXY_IMAGE}" --name "${KIND_CLUSTER_NAME}"
  success "Console images loaded into Kind"
else
  info "No Kind cluster '${KIND_CLUSTER_NAME}' running; skipping image load"
fi
