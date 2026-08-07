#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_commands kind
header "Tearing down Kind cluster '${KIND_CLUSTER_NAME}'"

if cluster_exists; then
  info "Deleting cluster..."
  kind delete cluster --name "${KIND_CLUSTER_NAME}"
  success "Cluster deleted"
else
  warn "Cluster '${KIND_CLUSTER_NAME}' does not exist"
fi

release_cloud_provider_kind
if [[ -d "${CLUSTER_STATE_DIR}" ]]; then
  rm -rf "${CLUSTER_STATE_DIR}"
fi
success "Local cluster state removed"
