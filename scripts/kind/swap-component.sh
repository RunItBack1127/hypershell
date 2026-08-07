#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_commands kubectl kind jq
require_cluster

ACTION="${1:-}"
COMPONENT="${2:-}"
if [[ ! "${ACTION}" =~ ^(up|down)$ ]] || [[ ! "${COMPONENT}" =~ ^(api-server|control-plane|web-console)$ ]]; then
  error "Usage: swap-component.sh up|down api-server|control-plane|web-console"
  exit 1
fi

case "${COMPONENT}" in
  api-server)
    DEPLOYMENT="hypershell-api-server"
    CONTAINERS=(api-server migrate)
    LOCAL_IMAGE="${api_server_local}"
    BASELINE_IMAGE="${api_server_ref}"
    DOCKERFILE="components/api-server/Dockerfile"
    BUILD_CONTEXT="components/api-server"
    ;;
  control-plane)
    DEPLOYMENT="hypershell-controller"
    CONTAINERS=(controller)
    LOCAL_IMAGE="${control_plane_local}"
    BASELINE_IMAGE="${control_plane_ref}"
    DOCKERFILE="components/control-plane/Dockerfile"
    BUILD_CONTEXT="."
    ;;
  web-console)
    DEPLOYMENT="hypershell-web-console"
    CONTAINERS=(web-console)
    LOCAL_IMAGE="${web_console_local}"
    BASELINE_IMAGE="${web_console_ref}"
    DOCKERFILE="components/web-console/Dockerfile"
    BUILD_CONTEXT="."
    ;;
esac

load_local_image() {
  local image="$1"
  ensure_state_dirs
  local archive
  archive="$(mktemp "${NAMESPACE_STATE_DIR}/image.XXXXXX.tar")"
  "${CONTAINER_ENGINE}" save --output "${archive}" "${image}"
  kind load image-archive "${archive}" --name "${KIND_CLUSTER_NAME}"
  rm -f "${archive}"
}

wait_for_new_rollout() {
  local generation
  generation="$(kubectl_kind -n "${KIND_NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.metadata.generation}')"
  wait_for_deployment "${KIND_NAMESPACE}" "${DEPLOYMENT}" 240s
  local observed ready updated unavailable
  observed="$(kubectl_kind -n "${KIND_NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.status.observedGeneration}')"
  ready="$(kubectl_kind -n "${KIND_NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.status.readyReplicas}')"
  updated="$(kubectl_kind -n "${KIND_NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.status.updatedReplicas}')"
  unavailable="$(kubectl_kind -n "${KIND_NAMESPACE}" get deployment "${DEPLOYMENT}" -o jsonpath='{.status.unavailableReplicas}')"
  if (( observed < generation )) || [[ "${ready:-0}" != "1" || "${updated:-0}" != "1" || "${unavailable:-0}" != "0" ]]; then
    error "${DEPLOYMENT} did not complete generation ${generation}"
    print_namespace_diagnostics "${KIND_NAMESPACE}"
    return 1
  fi
}

recorded_baseline_image() {
  kubectl_kind -n "${KIND_NAMESPACE}" get deployment "${DEPLOYMENT}" \
    -o jsonpath='{.spec.template.metadata.annotations.hypershell\.redhat\.io/baseline-image}'
}

set_pull_policy() {
  local policy="$1" patch
  case "${COMPONENT}" in
    api-server)
      patch="{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"api-server\",\"imagePullPolicy\":\"${policy}\"}],\"initContainers\":[{\"name\":\"migrate\",\"imagePullPolicy\":\"${policy}\"}]}}}}"
      ;;
    control-plane)
      patch="{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"controller\",\"imagePullPolicy\":\"${policy}\"}]}}}}"
      ;;
    web-console)
      patch="{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"web-console\",\"imagePullPolicy\":\"${policy}\"}]}}}}"
      ;;
  esac
  kubectl_kind -n "${KIND_NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=strategic --patch "${patch}" >/dev/null
}

swap_web_console_hot_reload() {
  if [[ -z "${CONTAINER_ENGINE}" ]]; then
    error "Hot reload requires Podman or Docker"
    exit 1
  fi

  header "Web console hot reload"
  info "Building the pinned Node.js/pnpm development image..."
  "${CONTAINER_ENGINE}" build \
    --tag "${web_console_dev_local}" \
    --file "${REPO_ROOT}/components/web-console/Dockerfile.dev" \
    "${REPO_ROOT}/components/web-console"

  info "Installing frozen workspace dependencies with the pinned development image..."
  install_args=(
    run --rm
    --security-opt label=disable
    --env HOME=/tmp
    --volume "${KIND_HOST_MOUNT_PATH}:/mnt/host"
    --workdir /mnt/host
  )
  if [[ "$(basename "${CONTAINER_ENGINE}")" == "podman" ]]; then
    install_args+=(--userns=keep-id)
  fi
  install_args+=(
    --user "$(id -u):$(id -g)"
    "${web_console_dev_local}"
    pnpm install --frozen-lockfile --config.confirmModulesPurge=false --config.enableGlobalVirtualStore=false
  )
  "${CONTAINER_ENGINE}" "${install_args[@]}"
  load_local_image "${web_console_dev_local}"

  hot_patch="$(jq -nc \
    --arg image "${web_console_dev_local}" \
    --arg oidc_issuer "http://${KEYCLOAK_HOSTNAME}:${KIND_KEYCLOAK_PORT}/realms/hypershell" \
    --argjson run_as_user "$(id -u)" \
    --argjson run_as_group "$(id -g)" \
    '{spec:{template:{spec:{securityContext:{runAsNonRoot:true,runAsUser:$run_as_user,runAsGroup:$run_as_group,seccompProfile:{type:"RuntimeDefault"}},containers:[{name:"web-console",image:$image,imagePullPolicy:"Never",command:["pnpm","--config.enableGlobalVirtualStore=false","--config.verifyDepsBeforeRun=false","--filter","@openshift-online/hypershell-web-console","dev","--host","0.0.0.0","--port","8080"],workingDir:"/mnt/host",env:[{name:"WEB_CONSOLE_API_ORIGIN",value:"http://hypershell-api-server:8000"},{name:"WEB_CONSOLE_DEV_CLUSTER",value:"true"},{name:"WEB_CONSOLE_CACHE_DIR",value:"/tmp/vite-cache"},{name:"HYPERSHELL_GATEWAY_OIDC_ISSUER",value:$oidc_issuer},{name:"HYPERSHELL_GATEWAY_OIDC_CLIENT_ID",value:"openshell-cli"},{name:"HYPERSHELL_GATEWAY_OIDC_AUDIENCE",value:"openshell-cli"},{name:"HYPERSHELL_GATEWAY_OIDC_SCOPES",value:"openid profile email openshell:all"},{name:"TMPDIR",value:"/tmp"},{name:"NODE_ENV",value:"development"}],ports:[{containerPort:8080,name:"http"}],securityContext:{allowPrivilegeEscalation:false,runAsNonRoot:true,runAsUser:$run_as_user,runAsGroup:$run_as_group,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}},startupProbe:{httpGet:{path:"/",port:8080},periodSeconds:2,failureThreshold:60},livenessProbe:{httpGet:{path:"/",port:8080},periodSeconds:10},readinessProbe:{httpGet:{path:"/",port:8080},periodSeconds:2},resources:{requests:{cpu:"50m",memory:"512Mi"},limits:{cpu:"1",memory:"2Gi"}},volumeMounts:[{name:"host-src",mountPath:"/mnt/host"},{name:"tmp",mountPath:"/tmp"}]}],volumes:[{name:"host-src",hostPath:{path:"/mnt/host",type:"Directory"}},{name:"tmp",emptyDir:{}}]}}}}')"
  kubectl_kind -n "${KIND_NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=strategic --patch "${hot_patch}"
  wait_for_new_rollout
  track_swap "${COMPONENT}"
  success "Web console hot reload is ready; edits under ${KIND_HOST_MOUNT_PATH} are mounted live"
}

swap_up() {
  if [[ -z "$(recorded_baseline_image)" ]]; then
    error "${DEPLOYMENT} does not record a baseline image; run 'make kind-up' to update the local environment"
    exit 1
  fi
  if [[ "${COMPONENT}" == "web-console" && "${KIND_HOT_RELOAD}" == "true" ]]; then
    swap_web_console_hot_reload
    return
  fi
  if [[ "${COMPONENT}" != "web-console" && "${KIND_HOT_RELOAD}" == "true" ]]; then
    info "Hot reload is not supported for ${COMPONENT}; rebuilding and replacing it"
  fi
  if [[ -z "${CONTAINER_ENGINE}" ]]; then
    error "A container engine (Podman or Docker) is required"
    exit 1
  fi

  header "Swap ${COMPONENT} to the working tree"
  build_args=(build --tag "${LOCAL_IMAGE}" --file "${REPO_ROOT}/${DOCKERFILE}")
  if [[ "${COMPONENT}" == "api-server" ]]; then
    build_args+=(--build-arg "GIT_VERSION=${build_version:-dev}" --build-arg "BUILD_TIME=${build_time:-unknown}")
  fi
  build_args+=("${REPO_ROOT}/${BUILD_CONTEXT}")
  "${CONTAINER_ENGINE}" "${build_args[@]}"
  load_local_image "${LOCAL_IMAGE}"

  set_image_args=()
  for container in "${CONTAINERS[@]}"; do
    set_image_args+=("${container}=${LOCAL_IMAGE}")
  done
  kubectl_kind -n "${KIND_NAMESPACE}" set image "deployment/${DEPLOYMENT}" "${set_image_args[@]}"
  set_pull_policy Never
  kubectl_kind -n "${KIND_NAMESPACE}" rollout restart "deployment/${DEPLOYMENT}"
  wait_for_new_rollout
  track_swap "${COMPONENT}"
  success "${COMPONENT} is running the current working tree"
}

reset_hot_reload_fields() {
  kubectl_kind -n "${KIND_NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=strategic --patch \
    '{"spec":{"template":{"spec":{"securityContext":null,"containers":[{"name":"web-console","command":null,"workingDir":null,"env":null,"securityContext":null,"volumeMounts":null}],"volumes":null}}}}' >/dev/null
}

swap_down() {
  header "Restore ${COMPONENT} baseline"
  if ! is_swapped "${COMPONENT}"; then
    warn "${COMPONENT} is already marked as baseline"
    return
  fi

  BASELINE_IMAGE="$(recorded_baseline_image)"
  if [[ -z "${BASELINE_IMAGE}" ]]; then
    error "${DEPLOYMENT} does not record the baseline image to restore"
    exit 1
  fi

  if [[ "${COMPONENT}" == "web-console" ]]; then
    web_console_ref="${BASELINE_IMAGE}"
    reset_hot_reload_fields
    apply_manifest deploy/kind/web-console.yaml
  else
    set_image_args=()
    for container in "${CONTAINERS[@]}"; do
      set_image_args+=("${container}=${BASELINE_IMAGE}")
    done
    kubectl_kind -n "${KIND_NAMESPACE}" set image "deployment/${DEPLOYMENT}" "${set_image_args[@]}"
    set_pull_policy IfNotPresent
  fi
  kubectl_kind -n "${KIND_NAMESPACE}" rollout restart "deployment/${DEPLOYMENT}"
  wait_for_new_rollout
  clear_swap "${COMPONENT}"
  success "${COMPONENT} restored to ${BASELINE_IMAGE}"
}

if [[ "${ACTION}" == "up" ]]; then
  swap_up
else
  swap_down
fi
