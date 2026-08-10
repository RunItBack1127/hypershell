# ROSA Deployment Specification

Deployment reference for the HyperShell instance on Red Hat OpenShift Service on AWS (ROSA).

## Role in Multi-Cloud Architecture

ROSA is a **managed cluster** — it receives gateway deployments from the IBM Cloud ROKS hub controller. The IBM instance is the primary HyperShell control plane that manages gateways across multiple clouds.

```
┌───────────────────────────────────────────────────────┐
│  IBM Cloud ROKS (Hub)                                 │
│  hypershell namespace                                 │
│  ┌────────────┐  ┌────────────┐  ┌──────────────┐    │
│  │ API Server │  │ Controller │  │ PostgreSQL   │    │
│  └────────────┘  └──────┬─────┘  └──────────────┘    │
│                         │                             │
│                    outbound TCP 443                    │
│                    via Public Gateway                  │
└─────────────────────────┼─────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│  ROSA vteam-stage (Managed Cluster)                     │
│  openshell-rosa namespace                               │
│  ┌──────────────┐  ┌──────────────────┐                 │
│  │ Gateway Pod  │  │ Gateway DB Pod   │                 │
│  │ (Running)    │  │ (Running)        │                 │
│  └──────────────┘  └──────────────────┘                 │
│  Route: openshell-gateway-openshell-rosa.apps.rosa...   │
└─────────────────────────────────────────────────────────┘
```

**Rationale**: IBM Cloud ROKS is the hub because it runs the full HyperShell control plane (API server, controller, PostgreSQL, Keycloak). ROSA serves as a managed cluster target — its strengths (K8s 1.33, external registry access, Gateway API CRDs) make it an excellent gateway deployment target.

## Cluster

| Field | Value |
|-------|-------|
| Platform | ROSA (AWS) |
| API Server | `https://api.vteam-stage.7fpc.p3.openshiftapps.com:443` |
| Apps Domain | `apps.rosa.vteam-stage.7fpc.p3.openshiftapps.com` |
| OpenShift Version | `4.20.32` |
| Kubernetes Version | `v1.33.13` |
| Worker Nodes | 8 (us-east-1) |
| User | `clusteradmin` |
| Auth | Token-based (`oc login --token`) |

## Current State

### Namespace: `hypershell-api`

| Component | Image | Status |
|-----------|-------|--------|
| API Server | `quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main/hypershell-api-server-main:eb34e23` | Running |
| Controller | `quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main/hypershell-control-plane-main:eb34e23` | Running |
| PostgreSQL | `registry.redhat.io/rhel9/postgresql-13:latest` | Running |

API Route: `https://hypershell-api-hypershell-api.apps.rosa.vteam-stage.7fpc.p3.openshiftapps.com`

Auth: **disabled** (dev mode, `run-no-auth`)

### Controller Environment

```
HYPERSHELL_GRPC_SERVER_ADDR=hypershell-api-server:9000
HYPERSHELL_API_SERVER_URL=http://hypershell-api-server:8000
HYPERSHELL_NAMESPACE=hypershell-api
HYPERSHELL_LOG_LEVEL=info
GATEWAY_API_BASE_DOMAIN=apps.rosa.vteam-stage.7fpc.p3.openshiftapps.com
```

Not yet set: `HYPERSHELL_DEFAULT_GATEWAY_IMAGE`, `HYPERSHELL_DEFAULT_SUPERVISOR_IMAGE`, `HYPERSHELL_DEFAULT_SANDBOX_IMAGE`.

### Existing API Resources

| Kind | Name | Notes |
|------|------|-------|
| Fleet | `test-fleet` | Primary fleet |
| ManagedCluster | `vteam-stage` | Self-registration (this ROSA cluster), provider=rosa, region=us-east-1 |
| ManagedDatabase | `openshell-gateway-test-db` | in-cluster PostgreSQL 16 |
| GatewayRelease | `gateway-test-release` | `ghcr.io/nvidia/openshell/gateway:0.0.92` |
| Gateway | `e2e-gw` | In `openshell-e2e` ns, phase=Running, has Route |
| Gateway | `openshell-gateway` | In `openshell-gateway-test` ns, phase=Running but pods failing |

### Namespace: `openshell-e2e` (working gateway)

| Pod | Status | Notes |
|-----|--------|-------|
| `openshell-gateway-0` | Running | StatefulSet, healthy |
| `default--e2e-0761` | Running | Sandbox pod |
| `default--e2e-2550` | Running | Sandbox pod |

Route: `openshell-gateway-openshell-e2e.apps.rosa.vteam-stage.7fpc.p3.openshiftapps.com` (passthrough TLS)

### Namespace: `openshell-gateway-test` (broken gateway)

| Pod | Status | Issue |
|-----|--------|-------|
| `openshell-gateway-*` | Init:CreateContainerError | Gateway image 0.0.92 init failure |
| `openshell-gateway-db-*` | InvalidImageName | DB image = `DB_ghcr.io/nvidia/openshell/gateway:0.0.92` (placeholder bug) |

Root cause: The `DB_IMAGE_PLACEHOLDER` substitution was broken — it prefixed `DB_` to the gateway image instead of substituting the database image. This was fixed in the current branch's `manifests.go` (`defaultDBImage()` function).

### Available CRDs

| CRD | Available | Notes |
|-----|-----------|-------|
| `agents.x-k8s.io/Sandbox` | Yes (v1beta1) | Agent sandbox controller installed |
| `gateway.networking.k8s.io` | Yes (v1) | Gateway API (GatewayClass, Gateway, GRPCRoute, HTTPRoute) |
| cert-manager | **No** | Not installed; certgen job handles TLS |

### Keycloak

**Not yet deployed** on ROSA. The `ambient-keycloak` namespace is gone. The `openshell-gateway` in `openshell-gateway-test` references an old ACP Keycloak issuer URL that no longer exists.

## ROSA vs IBM Cloud Differences

| Concern | ROSA | IBM Cloud (ROKS) |
|---------|------|------------------|
| Image registry | External access (ghcr.io, quay.io) works | Restricted — must mirror to internal registry |
| HyperShell images | Quay.io (Konflux CI) | Internal registry (manual mirror) |
| Namespace | `hypershell-api` | `hypershell` |
| K8s version | 1.33 | 1.30 |
| Supervisor sideload | `image` volume (K8s 1.31+) | `init-container` (K8s <1.31) |
| Agent sandbox CRD | Pre-installed | Manual install + image mirror |
| Gateway API | Pre-installed | Not available |
| cert-manager | Not installed | Not installed |
| Auth | `clusteradmin` token | `ibmcloud oc cluster config --admin` |
| VPC egress | AWS default (internet access) | Blocked by default (needs Public Gateway) |

## Managed Cluster Setup

ROSA receives gateway deployments from the IBM Cloud hub. The hub controller connects to ROSA using a kubeconfig stored as a K8s Secret.

### Service Account

The `acp-provisioner` SA in namespace `ambient-code` has a ClusterRole with permissions for namespaces, secrets, SAs, services, configmaps, pods, PVCs, deployments, statefulsets, jobs, roles, rolebindings, routes, networkpolicies, sandbox CRDs, and tokenreviews.

### Image Mirroring from IBM

Gateway images were mirrored from IBM's internal registry to ROSA's internal registry for consistency:

```bash
IBM_REG=$(oc --context=ibm get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
ROSA_REG="default-route-openshift-image-registry.apps.rosa.vteam-stage.7fpc.p3.openshiftapps.com"

IMAGES=(
  "hypershell/openshell-gateway:0.0.101"
  "hypershell/openshell-supervisor:0.0.101"
  "hypershell/openshell-sandbox-base:latest"
  "hypershell/postgres:16"
)

for img in "${IMAGES[@]}"; do
  podman pull "$IBM_REG/$img" --tls-verify=false
  podman tag "$IBM_REG/$img" "$ROSA_REG/$img"
  podman push "$ROSA_REG/$img" --tls-verify=false
done
```

Image pull access for dynamically-created namespaces:

```bash
oc policy add-role-to-group system:image-puller system:authenticated -n hypershell
```

### Standalone E2E Test (ROSA as Hub)

If ROSA is ever configured as its own hub:

```bash
HYPERSHELL_NAMESPACE=hypershell-api \
GATEWAY_NAMESPACE=openshell-e2e \
GATEWAY_NAME=openshell-gateway \
SKIP_CLEANUP=1 \
PAUSE=0 \
bash components/pr-test/e2e-openshell.sh
```

## Current Managed State

ROSA is registered as ManagedCluster `rosa-vteam-stage` (ID: `3HhnggQKv9ejXefylkzLjppgbFH`) in the IBM hub API. The hub controller provisions gateways remotely using the `rosa-kubeconfig` secret.

### Active Remote Gateway

| Field | Value |
|-------|-------|
| Gateway | `rosa-gateway` |
| Namespace | `openshell-rosa` |
| Phase | Running |
| Route | `openshell-gateway-openshell-rosa.apps.rosa.vteam-stage.7fpc.p3.openshiftapps.com` |
| Gateway Image | `image-registry.openshift-image-registry.svc:5000/hypershell/openshell-gateway:0.0.101` |
| DB Image | `image-registry.openshift-image-registry.svc:5000/hypershell/postgres:16` |

### Known Issues

- **Gateway API RBAC**: The `acp-provisioner` SA lacks permissions for `grpcroutes` and `backendtlspolicies`. Non-blocking — OpenShift Routes are used instead.
- **Kubeconfig CA rotation**: ROSA rotates certificates periodically. Regenerate from SA secret's `ca.crt` field when `x509: certificate signed by unknown authority` errors appear.

## Teardown

```bash
oc delete ns openshell-e2e openshell-gateway-test
oc delete project hypershell-api
```
