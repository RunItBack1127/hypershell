# Local Development Environment

HyperShell provides a single-command local development environment using
[Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker) clusters. The
environment deploys all platform components -- API server, control plane, and
web console -- so developers can test gateway provisioning and connectivity
end-to-end without external infrastructure. The separate Agent Sandbox
provider/controller is not installed; sandbox lifecycle is outside this local
platform workflow.

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| [Docker](https://docs.docker.com/get-docker/) or [Podman](https://podman.io/docs/installation) | Container engine | OS package manager |
| [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | Local Kubernetes clusters | `brew install kind` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Kubernetes CLI | `brew install kubectl` |
| [Helm](https://helm.sh/docs/intro/install/) | Installs digest-pinned Envoy Gateway charts | `brew install helm` |
| [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) `v0.11.1` | LoadBalancer port mapping and compatible Gateway API CRDs | `go install sigs.k8s.io/cloud-provider-kind@v0.11.1` |
| `curl`, `jq`, and Git | Setup verification and resource reconciliation | OS package manager |

The container engine is auto-detected (Podman preferred). Override with
`CONTAINER_ENGINE=docker` or `CONTAINER_ENGINE=podman`.

## Quickstart

```bash
make kind-up
```

This creates a Kind cluster and deploys:

1. cloud-provider-kind plus its compatible Gateway API CRDs
2. Envoy Gateway (HTTPRoute, GRPCRoute, and BackendTLSPolicy controller/data plane)
3. cert-manager (TLS certificate lifecycle)
4. Keycloak (OIDC identity provider)
5. Networking Gateway with wildcard TLS certificates
6. HTTPRoutes for platform services
7. API server (with DB migration init container)
8. Control plane (gRPC watcher + reconciler)
9. Web console (Node.js BFF + React SPA)
10. A local API resource graph and control-plane-provisioned OpenShell gateway with PostgreSQL

### Expected Output

```
==> HyperShell is running

  HTTP API:     https://api.hypershell.localhost
  Web Console:  https://console.hypershell.localhost
  Health:       https://health.hypershell.localhost
  gRPC:         https://openshell-gateway.gw.localhost
  Keycloak:     http://keycloak.hypershell.localhost:18080 (admin/admin)
  OIDC issuer:  http://keycloak.hypershell.localhost:18080/realms/hypershell
  CLI trust:    export SSL_CERT_FILE=/tmp/hypershell-kind-<uid>/clusters/hypershell-dev/hypershell-ca.crt
```

Services are accessed via `.localhost` hostnames routed through the networking
Gateway without workstation host-file changes. The TLS certificate is
self-signed. Run the printed `export SSL_CERT_FILE=...` command before using the
OpenShell CLI, trust it in your browser, or use `curl --cacert`.

Completion means the API and console proxy respond, the Gateway API resources
are accepted, the OpenShell health RPC succeeds through the re-encrypted
GRPCRoute, and a token from the local Keycloak succeeds on an authenticated
OpenShell RPC. A success banner is not printed before those checks pass.

## Per-Component Swap

Baseline images are pulled from the container registry. To test local changes,
swap individual components:

```bash
# Build and deploy API server from working tree
make kind-api-server-up

# Build and deploy control plane from working tree
make kind-control-plane-up

# Start web console with hot reload (default)
make kind-web-console-up

# Start web console with full image rebuild
KIND_HOT_RELOAD=false make kind-web-console-up
```

Each invocation rebuilds from the current working tree and replaces the running
deployment. Re-run after making changes to pick them up.

### Revert to Baseline

```bash
make kind-api-server-down
make kind-control-plane-down
make kind-web-console-down
```

Reverts the component to the registry baseline image. No-op if the component
is already running the baseline.

### Swap Status

```bash
make kind-status
```

Shows which components are running local builds versus baseline images. Swap
state is isolated by cluster and namespace under the temporary Kind state
directory, so parallel local deployments do not overwrite each other.

## Hot Reload

The web console supports hot reload by default. When you run
`make kind-web-console-up`, the host source directory is mounted into the
container and the repository-pinned pnpm development server runs. The target
first installs frozen workspace dependencies with the pinned Node 24 image, so
the workstation does not need a matching Node.js installation and stale
workspace links are repaired before rollout. File changes on the host are
reflected immediately without rebuilding.

To disable hot reload and use a full image rebuild instead:

```bash
KIND_HOT_RELOAD=false make kind-web-console-up
```

Hot reload is only supported for the web console. The API server and control
plane are Go services that require a full rebuild (`make kind-api-server-up` /
`make kind-control-plane-up`).

## Keycloak

The local Keycloak instance mirrors the downstream Keycloak topology used in
production.

| Setting | Value |
|---------|-------|
| Realm | `hypershell` |
| Issuer | `http://keycloak.hypershell.localhost:18080/realms/hypershell` |
| CLI client | `openshell-cli` (public, PKCE + direct access grants) |
| CLI scope | `openshell:all` |
| Provisioner client | `hypershell-provisioner` (confidential, service account) |
| Admin user | `admin` / `admin` (role: `hypershell-admins`) |
| Developer user | `developer` / `developer` (role: `hypershell-users`) |

The issuer hostname intentionally matches inside and outside the cluster.
The shared networking Gateway exposes Keycloak on port `18080`; workstation
`.localhost` resolution sends requests through that listener. An exact CoreDNS
rewrite sends in-cluster requests for the same hostname to the ClusterIP
Service. This avoids tokens whose issuer differs from the URL configured in the
gateway.

## Multiple Namespace Deployments

Deploy the platform into additional namespaces within the same Kind cluster.
Each namespace gets its own set of components with isolated hostnames.

```bash
# Deploy into a namespace derived from the current branch name
make kind-deploy

# Tear down a specific namespace deployment
make kind-undeploy KIND_NAMESPACE=hypershell-feature-add-auth
```

### Hostname Pattern

| Deployment | API | Console | Health |
|------------|-----|---------|--------|
| Default | `api.hypershell.localhost` | `console.hypershell.localhost` | `health.hypershell.localhost` |
| Branch `feature/add-auth` | `api.feature-add-auth.hypershell.localhost` | `console.feature-add-auth.hypershell.localhost` | `health.feature-add-auth.hypershell.localhost` |

Per-component swap targets respect `KIND_NAMESPACE`:

```bash
KIND_NAMESPACE=hypershell-feature-add-auth make kind-api-server-up
```

## Private Registry Pull Secret

Baseline images are pulled by the workstation container engine and loaded into
Kind. Authenticate that engine to a private baseline registry first, for
example with `podman login` or `docker login`.

To make registry credentials available to workloads that pull additional
images in-cluster, provide a pull-secret manifest:

```bash
KIND_PULL_SECRET=/path/to/pull-secret.yaml make kind-up
```

The YAML file is applied into the target namespace with `kubectl apply`. It
should contain a `kubernetes.io/dockerconfigjson` Secret. This does not log the
workstation container engine in to the baseline registry.

## Offline Development

Build all component images from the local working tree instead of pulling from
the container registry:

```bash
LOCAL_IMAGES=true make kind-up
```

This builds API server, control-plane, and web-console images from the current
working tree and loads them into Kind. It avoids the HyperShell platform image
registry; pinned third-party prerequisite images must still be cached or
downloadable.

## Cluster Lifecycle

```bash
make kind-up        # Create cluster + deploy everything
make kind-down      # Delete cluster (stops cloud-provider-kind)
make kind-status    # Show cluster info, pods, services, swap state
```

`make kind-up` is idempotent -- running it again on an existing cluster
reapplies manifests and waits for readiness. Swapped components are preserved.

## Environment Variable Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `KIND_CLUSTER_NAME` | `hypershell-dev` | Kind cluster name |
| `KIND_NAMESPACE` | `hypershell-system` | Target namespace for swap/teardown |
| `KIND_HOT_RELOAD` | `true` | Hot reload for web console |
| `KIND_HOST_MOUNT_PATH` | Repository root | Host directory mounted into Kind nodes |
| `KIND_KEYCLOAK_PORT` | `18080` | Canonical Keycloak Service and shared-Gateway listener port |
| `KIND_PULL_SECRET` | (unset) | Path to pull secret YAML for private registries |
| `KIND_NODE_IMAGE` | Immutable Kind node reference | Kind node image override |
| `KIND_POSTGRES_IMAGE` | Immutable PostgreSQL 16 reference | API database image override |
| `KIND_DB_IMAGE` | `KIND_POSTGRES_IMAGE` | reconciled gateway database image override |
| `KIND_GATEWAY_IMAGE` | Immutable OpenShell gateway reference | image stored in the local GatewayRelease |
| `IMAGE_REGISTRY` | `quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main` | Container registry |
| `IMAGE_TAG` | `latest` | Image tag for baseline images |
| `LOCAL_IMAGES` | (unset) | Build baseline component images from the current working tree |
| `CONTAINER_ENGINE` | Auto-detected | `podman` or `docker` |
| `CLOUD_PROVIDER_KIND_VERSION` | `v0.11.1` | required cloud-provider-kind version |
| `ENVOY_GATEWAY_VERSION` | `v1.8.3` | Envoy Gateway release |
| `CERT_MANAGER_VERSION` | `v1.21.1` | cert-manager version |

The Envoy Helm charts and controller/data-plane images are independently
digest-pinned in the `Makefile`; advanced validation can override
`ENVOY_GATEWAY_CHART`, `ENVOY_GATEWAY_CRDS_CHART`, `ENVOY_GATEWAY_IMAGE`,
`ENVOY_PROXY_IMAGE`, and `ENVOY_RATELIMIT_IMAGE`.

## Make Targets

| Target | Description |
|--------|-------------|
| `make kind-up` | Create cluster + prerequisites + deploy + wait |
| `make kind-down` | Delete cluster + stop cloud-provider-kind |
| `make kind-status` | Show cluster info, pods, services, swap state |
| `make kind-api-server-up` | Build + swap API server from working tree |
| `make kind-api-server-down` | Revert API server to baseline image |
| `make kind-control-plane-up` | Build + swap control plane from working tree |
| `make kind-control-plane-down` | Revert control plane to baseline image |
| `make kind-web-console-up` | Hot reload (default) or build + swap web console |
| `make kind-web-console-down` | Revert web console to baseline image |
| `make kind-deploy` | Deploy into new namespace (from branch name) |
| `make kind-undeploy` | Delete namespace deployment |

## Troubleshooting

### Container engine not running

```
Cannot connect to the Docker daemon
```

Start Docker Desktop or Podman:
```bash
# Docker
open -a Docker
# Podman
podman machine start
```

### Image pull failures

If the container registry is unreachable, use offline mode:
```bash
LOCAL_IMAGES=true make kind-up
```

### cloud-provider-kind not found

```bash
go install sigs.k8s.io/cloud-provider-kind@v0.11.1
```

The setup rejects a different version because its embedded Gateway API CRDs
and LoadBalancer behavior are part of the tested local stack.

### Port already in use

The canonical Keycloak Gateway listener port is configurable. For example:

```bash
KIND_KEYCLOAK_PORT=28080 make kind-up
```

### Pods stuck in ImagePullBackOff

The baseline images require access to `quay.io`. If behind a firewall, build
them locally or authenticate the workstation container engine:
```bash
# Offline: build from local working tree
LOCAL_IMAGES=true make kind-up

# Or: authenticate before setup
podman login quay.io  # use `docker login quay.io` with Docker
make kind-up
```
