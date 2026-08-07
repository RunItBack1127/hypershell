#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_commands kind
if [[ -z "${CONTAINER_ENGINE}" ]]; then
  error "Building local images requires Podman or Docker"
  exit 1
fi

header "Building platform images from the working tree"
local_git_version="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
if ! git -C "${REPO_ROOT}" diff --quiet; then
  local_git_version="${local_git_version}-modified"
fi
local_build_time="$(git -C "${REPO_ROOT}" show -s --format=%cI HEAD)"

info "Building API server..."
"${CONTAINER_ENGINE}" build --tag "${api_server_local}" \
  --file "${REPO_ROOT}/components/api-server/Dockerfile" \
  --build-arg "GIT_VERSION=${local_git_version}" \
  --build-arg "BUILD_TIME=${local_build_time}" \
  "${REPO_ROOT}/components/api-server"

info "Building control plane..."
"${CONTAINER_ENGINE}" build --tag "${control_plane_local}" \
  --file "${REPO_ROOT}/components/control-plane/Dockerfile" "${REPO_ROOT}"

info "Building web console..."
"${CONTAINER_ENGINE}" build --tag "${web_console_local}" \
  --file "${REPO_ROOT}/components/web-console/Dockerfile" "${REPO_ROOT}"

if [[ "${api_server_local}" != "${api_server_ref}" ]]; then
  "${CONTAINER_ENGINE}" tag "${api_server_local}" "${api_server_ref}"
fi
if [[ "${control_plane_local}" != "${control_plane_ref}" ]]; then
  "${CONTAINER_ENGINE}" tag "${control_plane_local}" "${control_plane_ref}"
fi
if [[ "${web_console_local}" != "${web_console_ref}" ]]; then
  "${CONTAINER_ENGINE}" tag "${web_console_local}" "${web_console_ref}"
fi

if cluster_exists; then
  ensure_state_dirs
  for image in "${api_server_ref}" "${control_plane_ref}" "${web_console_ref}"; do
    archive="$(mktemp "${CLUSTER_STATE_DIR}/baseline-image.XXXXXX.tar")"
    "${CONTAINER_ENGINE}" save --output "${archive}" "${image}"
    kind load image-archive "${archive}" --name "${KIND_CLUSTER_NAME}"
    rm -f "${archive}"
  done
  success "Platform images loaded into ${KIND_CLUSTER_NAME}"
else
  success "Platform images built; no Kind cluster is running, so they were not loaded"
fi
