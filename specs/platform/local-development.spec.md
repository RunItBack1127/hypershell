# Local Development Environment

**Date:** 2026-08-04
**Status:** Draft
**Jira:** ENGPROD-10281

## Purpose

HyperShell provides a single-command local development environment using Kind (Kubernetes in Docker) clusters. The environment deploys all platform components — API server, control plane, and web console — so developers can test gateway provisioning and connectivity end-to-end without external infrastructure. The database is provisioned by the control plane reconciler, not by `kind-up` directly. The tooling is idempotent: running it repeatedly converges to the desired state without errors. `LOCAL_IMAGES=true` builds all baseline images from the current working tree instead of pulling from the registry.

The Agent Sandbox provider/controller and sandbox lifecycle are outside this specification. The local environment proves the HyperShell resource graph, gateway provisioning, routing, TLS, and OIDC authentication; it does not claim that a gateway can provision sandboxes unless a developer separately installs an Agent Sandbox provider.

Developers selectively swap individual components with local builds using per-component targets. The baseline cluster runs pre-built images pulled from the container registry; individual components are "swapped in" from local source as needed. Selective swapping converges to the current working tree state.

## Components Deployed

| Component | Kind | Image | Purpose |
|-----------|------|-------|---------|
| API Server | Deployment | Registry: `quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main/hypershell-api-server-main:latest` | REST + gRPC API, with init container for DB migrations |
| Control Plane | Deployment | Registry: `quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main/hypershell-control-plane-main:latest` | gRPC watcher + reconciler for gateway lifecycle; provisions the database |
| Web Console | Deployment | Registry: `quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main/hypershell-web-console-main:latest` | Browser-based management UI (Node.js); supports hot reload |

### Cluster Prerequisites

`make kind-up` SHALL install the following cluster-level prerequisites before deploying HyperShell components:

| Prerequisite | Purpose |
|--------------|---------|
| Gateway API CRDs | Gateway, HTTPRoute, GRPCRoute, BackendTLSPolicy, and related CRDs installed by cloud-provider-kind's pinned experimental channel |
| cloud-provider-kind | LoadBalancer implementation for Kind; exposes Envoy Gateway's data-plane Service to the host |
| Envoy Gateway | Gateway API controller and data plane for HTTPRoute, GRPCRoute, and BackendTLSPolicy |
| cert-manager | TLS certificate lifecycle for gateway certificates (issuance, renewal, rotation) |
| Keycloak | In-cluster OIDC identity provider for local gateway authentication testing |

[cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) SHALL be started as a background process after the Kind cluster is created and SHALL provide LoadBalancer address allocation and host port mapping for the shared Gateway data plane. It SHALL be started with the experimental Gateway API channel so its embedded v1 CRDs include GRPCRoute and BackendTLSPolicy. `kind-up` SHALL wait for those CRDs before installing the Gateway API controller. cloud-provider-kind's own GatewayClass SHALL NOT be used because v0.11.1 does not process GRPCRoute or BackendTLSPolicy.

[Envoy Gateway](https://gateway.envoyproxy.io/) SHALL implement the local GatewayClass and data plane. Its controller chart, CRD chart, controller image, proxy image, and optional rate-limit image SHALL all be pinned immutably. `kind-up` SHALL install only Envoy Gateway's extension CRDs because the compatible Gateway API v1 CRDs are already managed by the pinned cloud-provider-kind installation. It SHALL wait for the Envoy Gateway deployment and accepted `envoy-gateway` GatewayClass before applying the shared networking Gateway.

One cloud-provider-kind process watches all local Kind clusters. The tooling SHALL therefore maintain one owned process with per-cluster owner registrations. `kind-up` SHALL reuse that process only after validating both its PID ownership and exact version. `kind-down` SHALL unregister its cluster and stop the owned process only after the last owner is removed; it SHALL never terminate an unrelated cloud-provider-kind process. The version SHALL be pinned via `CLOUD_PROVIDER_KIND_VERSION`; `make kind-up` SHALL verify the installed binary is that version and print an exact installation command when it is missing or incompatible.

cert-manager SHALL be installed by applying the release manifest from `https://github.com/cert-manager/cert-manager/releases/download/<version>/cert-manager.yaml`, skipping if the pinned installation already exists (idempotent), and waiting for the `cert-manager`, `cert-manager-webhook`, and `cert-manager-cainjector` deployments to reach ready state before proceeding. The version SHALL be pinned via a `CERT_MANAGER_VERSION` variable (default: `v1.21.1`).

Keycloak SHALL be deployed into the Kind cluster. Local development SHALL use this in-cluster instance as the Gateway OIDC issuer; configuring an external Keycloak is outside this specification.

### Gateway Provisioning

`make kind-up` SHALL reconcile the API resource graph needed to provision one local OpenShell gateway: a Fleet, ManagedCluster, GatewayRelease, ManagedDatabase, and Gateway. Reconciliation SHALL find resources by their stable local-development names and update or reuse them rather than creating duplicates. The Gateway SHALL use a dedicated `openshell-gateway` namespace and advertise `openshell-gateway.gw.localhost` as its external DNS name.

```json
{
  "name": "openshell-gateway",
  "namespace": "openshell-gateway",
  "external_dns": "openshell-gateway.gw.localhost",
  "fleet_id": "<default fleet id>",
  "cluster_id": "<local-kind cluster id>",
  "release_id": "<dev-release id>",
  "database_id": "<local-postgres id>"
}
```

The control plane SHALL resolve the referenced GatewayRelease and use its image when reconciling the gateway. The local control-plane deployment SHALL supply configurable defaults for the gateway database image, OIDC issuer and audience, role claims, and Gateway API parent reference. The resulting gateway configuration SHALL use the canonical issuer `http://keycloak.hypershell.localhost:18080/realms/hypershell`, audience `openshell-cli`, roles claim `groups`, admin role `hypershell-admins`, and user role `hypershell-users`. The Keycloak Service SHALL remain `ClusterIP`. The shared Gateway SHALL expose its canonical host and port through a dedicated HTTP listener and HTTPRoute. Workstation `.localhost` resolution SHALL direct the hostname to the shared Gateway, while an exact CoreDNS rewrite SHALL direct the same hostname to the Keycloak Service for in-cluster consumers. This preserves one issuer string for browser/CLI discovery, tokens, and gateway validation without exposing Keycloak through a separate LoadBalancer or requiring workstation host-file changes.

The local environment SHALL NOT deploy the gateway's PostgreSQL directly — the control plane reconciler provisions a production-style PostgreSQL database via the GatewayReconciler (see `specs/platform/openshell-gateway-database.spec.md`, implemented in [#14](https://github.com/openshift-online/hypershell/pull/14)). This ensures the local environment exercises the same database provisioning path used in production. The API server's own database (`deploy/kind/postgres.yaml`) is a separate concern — it stores platform resources (fleets, gateways, etc.) and is always deployed directly by `kind-up`.

TLS SHALL NOT be disabled. The gateway serves TLS using certificates issued by cert-manager (self-signed CA). The OIDC issuer uses HTTP because the local Keycloak instance runs in dev mode without TLS; the TLS requirement applies to the gateway's own serving certificate, not to the OIDC issuer endpoint. Authentication SHALL use OIDC only — mTLS client authentication is not supported.

### Keycloak Configuration

The Kind cluster Keycloak instance serves as the local equivalent of the downstream Keycloak — a downstream Keycloak that brokers authentication to Red Hat SSO and manages per-gateway OIDC clients. In production, the downstream Keycloak brokers authentication to Red Hat SSO (upstream) and manages per-gateway OIDC clients. The local instance mirrors this topology without the upstream broker, providing the same realm structure and client model.

| Setting | Value |
|---------|-------|
| Realm | `hypershell` |
| CLI client | `openshell-cli` (public, standard flow + direct access grants) |
| CLI authorization scope | `openshell:all` (optional client scope requested by the OpenShell CLI) |
| Provisioner client | `hypershell-provisioner` (confidential, service account with `manage-clients` and `manage-users` roles) |
| Admin role | `hypershell-admins` |
| User role | `hypershell-users` |
| Users | `admin` / `admin` (admin role), `developer` / `developer` (user role) — password matches username (local dev only) |

The OIDC issuer SHALL be reachable inside the cluster by the gateway and from the developer workstation at its canonical URL. The imported users SHALL have complete profiles and no pending required actions so the documented local credentials can obtain tokens. End-to-end setup SHALL obtain a developer token and invoke an authenticated gateway RPC with it; pod readiness and an unauthenticated health RPC alone are insufficient proof of OIDC functionality.

### Gateway API Routing

The local cluster SHALL use the Kubernetes Gateway API for every workstation-facing endpoint. A single shared networking Gateway SHALL expose component services and Keycloak through HTTPRoute resources and OpenShell gateway traffic through GRPCRoute resources. The tooling SHALL NOT create NodePort access services, use `kubectl port-forward`, or modify workstation host files for bootstrap, verification, or service access. All workstation-facing hostnames SHALL end in `.localhost` so local name resolution requires no privileged setup.

#### Networking Gateway (Cluster-Level)

`make kind-up` SHALL create a networking `Gateway` resource that acts as the shared ingress point for all component HTTPRoutes and gateway GRPCRoutes. This is cluster-level infrastructure — not managed by the control plane reconciler.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: hypershell-gw
  namespace: hypershell-system
spec:
  gatewayClassName: envoy-gateway
  listeners:
  - name: https
    hostname: "*.hypershell.localhost"
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: hypershell-https-tls
        kind: Secret
    allowedRoutes:
      namespaces:
        from: All
  - name: grpc
    hostname: "*.gw.localhost"
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: hypershell-gw-tls
        kind: Secret
    allowedRoutes:
      namespaces:
        from: All
```

cert-manager SHALL issue two wildcard certificates (self-signed CA): `hypershell-https-tls` for `*.hypershell.localhost` (component services) and `hypershell-gw-tls` for `*.gw.localhost` (gateway gRPC). The `allowedRoutes.namespaces.from: All` permits routes from any namespace, supporting multi-namespace deployments. `make kind-up` SHALL export the local CA certificate to the cluster state directory and print an `SSL_CERT_FILE` command so host CLIs can verify the routed certificate without disabling TLS or modifying system trust.

`make kind-up` SHALL configure an exact CoreDNS rewrite from `keycloak.hypershell.localhost` to `keycloak-service.keycloak.svc.cluster.local`. The setup SHALL wait for the updated CoreDNS deployment and prove both in-cluster resolution and workstation discovery of the canonical issuer.

#### Component Service Routes (kind-up Managed)

`make kind-up` SHALL create HTTPRoute resources for each component service:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-server
  namespace: hypershell-system
spec:
  parentRefs:
  - name: hypershell-gw
    namespace: hypershell-system
  hostnames:
  - api.hypershell.localhost
  rules:
  - backendRefs:
    - name: hypershell-api-server
      port: 8000
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-console
  namespace: hypershell-system
spec:
  parentRefs:
  - name: hypershell-gw
    namespace: hypershell-system
  hostnames:
  - console.hypershell.localhost
  rules:
  - backendRefs:
    - name: hypershell-web-console
      port: 3000
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: health
  namespace: hypershell-system
spec:
  parentRefs:
  - name: hypershell-gw
    namespace: hypershell-system
  hostnames:
  - health.hypershell.localhost
  rules:
  - backendRefs:
    - name: hypershell-api-server
      port: 8434
```

| Service | Hostname | Purpose |
|---------|----------|---------|
| HTTP API | `api.hypershell.localhost` | REST API access |
| Web Console | `console.hypershell.localhost` | Browser UI |
| Health | `health.hypershell.localhost` | Health check endpoint |
| gRPC | `<gateway-name>.gw.localhost` | gRPC streaming (control plane, CLI) |
| OIDC | `http://keycloak.hypershell.localhost:18080` | Canonical in-cluster and workstation Keycloak issuer |

For multi-namespace deployments, component hostnames include the namespace: `api.<namespace>.hypershell.localhost` (e.g. `api.feature-add-auth.hypershell.localhost`). `make kind-deploy` creates namespace-scoped HTTPRoutes; the `.localhost` suffix resolves them without additional workstation configuration.

#### Per-Gateway Route Resources (Control Plane Reconciled)

For each HyperShell Gateway resource, the control plane reconciler creates three Kubernetes resources:

1. **GRPCRoute** — Routes gRPC traffic from the networking Gateway to the gateway pod's Service:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: GRPCRoute
   metadata:
     name: openshell-gateway
     namespace: openshell-gateway
   spec:
     parentRefs:
     - name: hypershell-gw
       namespace: hypershell-system
     hostnames:
     - openshell-gateway.gw.localhost
     rules:
     - backendRefs:
       - name: openshell-gateway
         port: 8080
   ```

2. **BackendTLSPolicy** — Instructs the networking Gateway to establish a TLS connection to the backend pod and verify its certificate against the CA ConfigMap (TLS re-encrypt):
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: BackendTLSPolicy
   metadata:
     name: openshell-gateway
     namespace: openshell-gateway
   spec:
     targetRefs:
     - group: ""
       kind: Service
       name: openshell-gateway
     validation:
       caCertificateRefs:
       - group: ""
         kind: ConfigMap
         name: openshell-backend-ca
       hostname: openshell-gateway.openshell-gateway.svc.cluster.local
   ```

3. **CA ConfigMap** — Contains the gateway pod's CA certificate so the networking Gateway can verify the pod's TLS cert:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: openshell-backend-ca
     namespace: openshell-gateway
   data:
     ca.crt: |
       <contents of openshell-server-tls Secret ca.crt>
   ```

#### TLS Re-Encrypt Flow

```
Client                   Networking Gateway              Gateway Pod
  |                            |                              |
  |--- HTTPS (external) ------>|                              |
  |    wildcard cert           |--- TLS (internal) ---------->|
  |    *.gw.localhost          |    BackendTLSPolicy verifies  |
  |                            |    pod cert via CA ConfigMap  |
  |                            |                              |
```

1. **Client to networking Gateway:** The client connects via HTTPS. The networking Gateway terminates external TLS using the wildcard certificate (`*.gw.localhost`) issued by cert-manager. HTTP/2 is negotiated through ALPN during the TLS handshake.
2. **Networking Gateway to pod:** BackendTLSPolicy instructs the networking Gateway to re-encrypt traffic to the backend pod. The Gateway verifies the pod's certificate against the CA in the `openshell-backend-ca` ConfigMap. The pod's cert is issued by cert-manager from the same self-signed CA.

#### Kind vs Production Differences

| Aspect | Kind (local) | Production (OpenShift) |
|--------|-------------|----------------------|
| GatewayClass | `envoy-gateway` | `openshift-default` (controller: `openshift.io/gateway-controller/v1`) |
| Gateway controller | Envoy Gateway | OpenShift Service Mesh Operator (Istio/Envoy) |
| External TLS cert | cert-manager self-signed CA | Public CA (e.g. Let's Encrypt, corporate PKI) |
| Internal TLS cert | cert-manager self-signed CA | cert-manager with internal CA |
| LoadBalancer | cloud-provider-kind port mapping | Cloud provider LB or MetalLB |
| Service base domain | `hypershell.localhost` | `<cluster-domain>` (e.g. `apps.cluster.example.com`) |
| Service hostname pattern | `<service>.hypershell.localhost` | Route-based (OpenShift Routes or Gateway API HTTPRoute) |
| gRPC base domain | `gw.localhost` | `gw.<cluster-domain>` |
| gRPC hostname pattern | `<gateway-name>.gw.localhost` | `<gateway-name>-<namespace>.gw.<base-domain>` |
| DNS resolution | `.localhost` loopback plus exact CoreDNS rewrite for Keycloak | Cluster DNS / external DNS |

## Requirements

### Requirement: Single-Command Environment Setup

The system SHALL provide a `make kind-up` target at the repository root that creates a local HyperShell environment capable of end-to-end gateway provisioning and connectivity. Baseline images SHALL be pulled from the container registry unless `LOCAL_IMAGES=true` requests builds from the current working tree.

#### Scenario: First Run — Clean State
- GIVEN no Kind cluster exists
- WHEN a developer runs `make kind-up`
- THEN a Kind cluster SHALL be created
- AND all component images SHALL be pulled from the container registry
- AND images SHALL be loaded into the Kind cluster
- AND all Kubernetes resources SHALL be applied (namespace, API server, control plane)
- AND the system SHALL wait for all components to become ready
- AND connection information SHALL be printed to stdout

#### Scenario: Subsequent Run — Idempotent
- GIVEN a Kind cluster is already running from a previous `make kind-up`
- WHEN a developer runs `make kind-up` again
- THEN the cluster creation step SHALL be skipped (idempotent)
- AND Kubernetes manifests SHALL be reapplied
- AND the local Fleet, ManagedCluster, GatewayRelease, ManagedDatabase, and Gateway SHALL be updated or reused without creating duplicates
- AND the system SHALL wait for all components to become ready

#### Scenario: Completion Means End-to-End Ready
- GIVEN `make kind-up` is provisioning the environment
- WHEN any platform deployment, networking Gateway, HTTPRoute, GRPCRoute, or OpenShell gateway workload fails to become ready
- THEN `make kind-up` SHALL exit non-zero with diagnostic resource status
- AND it SHALL NOT print the success banner
- WHEN all required resources are ready
- THEN the command SHALL verify the API through the routed endpoint
- AND verify the web console can proxy a Gateway list request to the API
- AND verify the OpenShell gateway GRPCRoute has `Accepted=True` and `ResolvedRefs=True`
- AND verify the OpenShell gateway BackendTLSPolicy has `Accepted=True` and `ResolvedRefs=True`
- AND invoke `openshell.v1.OpenShell/Health` through the external GRPCRoute and require `grpc-status: 0` with a non-empty response
- AND obtain an access token from the in-cluster Keycloak using the documented developer credentials
- AND invoke the authenticated `openshell.v1.OpenShell/ListProviders` RPC through the external GRPCRoute with that token and require `grpc-status: 0` with a complete gRPC response frame

### Requirement: Per-Component Local Swap

The system SHALL provide per-component Make targets that build a single component from the current working tree, load it into the running cluster, and replace that component's deployment. Each invocation SHALL rebuild the image and replace the running state, even if the component is already swapped. This ensures developers can iterate by running the same target repeatedly after making changes.

#### Scenario: Swap API Server
- GIVEN a Kind cluster is running
- WHEN a developer runs `make kind-api-server-up`
- THEN the API server image SHALL be built from the current working tree
- AND the image SHALL be loaded into the Kind cluster
- AND the API server deployment SHALL be replaced with the newly built image
- AND the system SHALL wait for the API server to become ready

#### Scenario: Swap Control Plane
- GIVEN a Kind cluster is running
- WHEN a developer runs `make kind-control-plane-up`
- THEN the control plane image SHALL be built from the current working tree
- AND the image SHALL be loaded into the Kind cluster
- AND the control plane deployment SHALL be replaced with the newly built image
- AND the system SHALL wait for the control plane to become ready

#### Scenario: Swap Web Console
- GIVEN a Kind cluster is running
- WHEN a developer runs `make kind-web-console-up`
- THEN by default (hot reload enabled), the web console source SHALL be mounted from the host and the repository-pinned development server SHALL be started in a non-root container
- IF `KIND_HOT_RELOAD=false`, the web console image SHALL be built from the current working tree, loaded, and the deployment replaced
- AND the system SHALL wait for the web console to become ready

#### Scenario: Re-Swap Already Swapped Component
- GIVEN the API server is already running a local build
- WHEN a developer runs `make kind-api-server-up` again
- THEN the API server image SHALL be rebuilt from the current working tree
- AND the new image SHALL replace the previously swapped image
- AND the system SHALL wait for the API server to become ready

#### Scenario: No Cluster Running
- GIVEN no Kind cluster exists
- WHEN a developer runs any per-component swap target
- THEN the command SHALL exit with an error
- AND print a message directing the developer to run `make kind-up` first

#### Scenario: Revert API Server Swap
- GIVEN the API server is running a local build
- WHEN a developer runs `make kind-api-server-down`
- THEN the API server image SHALL be reverted to the baseline image
- AND the API server deployment SHALL be restarted
- AND the system SHALL wait for the API server to become ready
- AND swap tracking SHALL be cleared for the API server

#### Scenario: Revert Control Plane Swap
- GIVEN the control plane is running a local build
- WHEN a developer runs `make kind-control-plane-down`
- THEN the control plane image SHALL be reverted to the baseline image
- AND the control plane deployment SHALL be restarted
- AND the system SHALL wait for the control plane to become ready
- AND swap tracking SHALL be cleared for the control plane

#### Scenario: Revert Web Console Swap
- GIVEN the web console is running a local build or hot reload
- WHEN a developer runs `make kind-web-console-down`
- THEN the web console image SHALL be reverted to the baseline image
- AND the web console deployment SHALL be restarted
- AND the system SHALL wait for the web console to become ready
- AND swap tracking SHALL be cleared for the web console

#### Scenario: Revert When Not Swapped
- GIVEN a component is already running the baseline image
- WHEN a developer runs the corresponding `-down` target
- THEN the command SHALL print an info message indicating the component is already running the baseline image
- AND exit without error (no-op)

### Requirement: Cluster Teardown

The system SHALL provide a `make kind-down` target that completely removes the local development cluster.

#### Scenario: Teardown Running Cluster
- GIVEN a Kind cluster is running
- WHEN a developer runs `make kind-down`
- THEN the Kind cluster and all associated resources SHALL be deleted
- AND its cloud-provider-kind owner registration SHALL be removed
- AND the owned cloud-provider-kind process SHALL be stopped only when no other registered cluster remains

#### Scenario: Teardown When No Cluster Exists
- GIVEN no Kind cluster exists
- WHEN a developer runs `make kind-down`
- THEN the command SHALL exit without error

### Requirement: Cluster Status

The system SHALL provide a `make kind-status` target that reports the current state of the local development environment.

#### Scenario: Status of Running Cluster
- GIVEN a Kind cluster is running with deployed components
- WHEN a developer runs `make kind-status`
- THEN cluster connectivity information SHALL be displayed
- AND pod status for all components SHALL be displayed
- AND service hostnames SHALL be displayed
- AND the output SHALL indicate which components have active local swaps versus baseline images
- AND the networking Gateway, OpenShell Gateway, and route readiness SHALL be displayed

#### Scenario: Status When No Cluster Exists
- GIVEN no Kind cluster is running
- WHEN a developer runs `make kind-status`
- THEN the output SHALL indicate the cluster is not running

### Requirement: Configurable Cluster Name

The system SHALL accept a `KIND_CLUSTER_NAME` environment variable to control the Kind cluster name. If unset, the default SHALL be `hypershell-dev`.

#### Scenario: Custom Cluster Name
- GIVEN `KIND_CLUSTER_NAME` is set to `my-cluster`
- WHEN a developer runs `make kind-up`
- THEN a Kind cluster named `my-cluster` SHALL be created
- AND `make kind-down`, `make kind-status`, and per-component targets SHALL operate on `my-cluster`

#### Scenario: Default Cluster Name
- GIVEN `KIND_CLUSTER_NAME` is not set
- WHEN a developer runs `make kind-up`
- THEN a Kind cluster named `hypershell-dev` SHALL be created

### Requirement: Cluster-Isolated and Safe Operations

Every lifecycle command SHALL target the configured Kind context explicitly and SHALL keep runtime state in a cluster-specific directory. Local setup SHALL NOT kill processes it did not start or send provisioning requests before the intended Gateway API route reports accepted and resolved references.

#### Scenario: Another Kubernetes Context Is Current
- GIVEN the developer's current kubectl context targets another cluster
- AND the configured Kind cluster exists
- WHEN the developer runs any `kind-*` target
- THEN every Kubernetes operation SHALL target `kind-<KIND_CLUSTER_NAME>` explicitly
- AND the other cluster SHALL remain unchanged

#### Scenario: API Bootstrap Uses the Shared Gateway
- GIVEN the API workload and its HTTPRoute have been created
- WHEN `make kind-up` provisions API resources
- THEN it SHALL wait for the HTTPRoute to report accepted and resolved references
- AND it SHALL send provisioning requests to the routed API hostname through the shared Gateway
- AND it SHALL NOT create a temporary direct connection to the API workload

#### Scenario: Multiple Kind Clusters Use cloud-provider-kind
- GIVEN two local HyperShell Kind clusters exist
- WHEN one cluster is removed
- THEN the shared owned provider process SHALL remain running
- AND the other cluster's owner registration SHALL remain intact

### Requirement: Hostname-Based Service Access

All workstation-facing services SHALL be accessible only through hostnames and ports owned by the shared networking Gateway (see Gateway API Routing). The system SHALL NOT create NodePort access Services or use `kubectl port-forward`.

| Service | Hostname | Purpose |
|---------|----------|---------|
| HTTP API | `https://api.hypershell.localhost` | REST API access |
| Web Console | `https://console.hypershell.localhost` | Browser UI |
| Health | `https://health.hypershell.localhost` | Health check endpoint |
| gRPC | `https://<gateway-name>.gw.localhost` | gRPC streaming (control plane, CLI) |

All service hostnames SHALL use the `.localhost` suffix and resolve to loopback without workstation configuration. The self-signed TLS certificate issued by cert-manager must be trusted by the developer's browser or CLI tool (e.g. `curl --cacert` or the `SSL_CERT_FILE` command printed by `make kind-up`). The setup SHALL NOT instruct developers to disable gateway certificate verification as its default workflow.

For multi-namespace deployments, hostnames include the namespace: `api.<namespace>.hypershell.localhost`. No host-file or port management is required — each namespace is differentiated by hostname, not port number.

#### Scenario: Default Access
- GIVEN no special configuration
- WHEN `make kind-up` completes
- THEN the HTTP API SHALL be accessible at `https://api.hypershell.localhost`
- AND the web console SHALL be accessible at `https://console.hypershell.localhost`
- AND the health endpoint SHALL be accessible at `https://health.hypershell.localhost`
- AND the canonical OIDC issuer SHALL be accessible at `http://keycloak.hypershell.localhost:18080`

#### Scenario: Multi-Namespace Hostname Differentiation
- GIVEN the default deployment is running in `hypershell-system`
- AND a second deployment is running in `hypershell-feature-add-auth`
- WHEN a developer accesses `https://api.feature-add-auth.hypershell.localhost`
- THEN the request SHALL route to the API server in the `hypershell-feature-add-auth` namespace

### Requirement: Container Engine Support

The system SHALL support both Podman and Docker as container engines. The engine SHALL be auto-detected, preferring Podman when available, and MAY be overridden via the `CONTAINER_ENGINE` environment variable.

#### Scenario: Podman Available
- GIVEN Podman is installed and available in PATH
- WHEN a developer runs `make kind-up`
- THEN Podman SHALL be used to build and manage container images

#### Scenario: Docker Fallback
- GIVEN Podman is not installed
- AND Docker is installed
- WHEN a developer runs `make kind-up`
- THEN Docker SHALL be used to build and manage container images

### Requirement: Image Reference Consistency

All image names and tags used across Makefile targets, Kind load commands, and Kubernetes manifests SHALL resolve to the same artifacts. This reinforces the cross-cutting convention in `specs/standards/platform/cross-cutting.spec.md`.

### Requirement: Security Context Compliance

All containers in the Kind deployment manifests SHALL set restricted security contexts per `specs/standards/security/security.spec.md`: `runAsNonRoot: true`, `capabilities.drop: ["ALL"]`, and `allowPrivilegeEscalation: false`.

### Requirement: Swap Tracking

The system SHALL track swapped components in the cluster- and namespace-scoped runtime state directory at `$KIND_STATE_ROOT/clusters/<cluster>/namespaces/<namespace>/swaps`. Swap state SHALL NOT use one repository-root file because that would conflate independent clusters and namespace deployments. The file records the set of currently swapped components so that `make kind-status` can report this information. Running `make kind-up` SHALL preserve existing swap state: for non-swapped components, it pulls the latest baseline images and reapplies manifests normally; for swapped components, it skips manifest reapplication to avoid overwriting the locally-built image. Swap tracking is not cleared by `kind-up` and is removed with the owning namespace or cluster.

Each platform Deployment SHALL record its effective baseline image in the pod-template annotation `hypershell.redhat.io/baseline-image`. A component swap SHALL preserve that annotation, and the corresponding down target SHALL restore the recorded image. Restoration SHALL NOT depend on the developer repeating the `LOCAL_IMAGES`, registry, or tag arguments originally used by `make kind-up`.

#### Scenario: Swap Reported in Status
- GIVEN a developer has run `make kind-api-server-up`
- WHEN they run `make kind-status`
- THEN the output SHALL indicate the API server is running a local build
- AND the control plane is running the baseline image

#### Scenario: Kind-Up Preserves Swaps
- GIVEN a developer has swapped the API server to a local build
- WHEN they run `make kind-up`
- THEN non-swapped components SHALL be redeployed from registry images
- AND the API server SHALL remain running the locally-built image
- AND swap tracking SHALL be preserved

#### Scenario: Restore Locally Built Baseline Without Repeating Setup Flags
- GIVEN the cluster was created with `LOCAL_IMAGES=true`
- AND a component has been swapped
- WHEN the developer runs its down target without setting `LOCAL_IMAGES`
- THEN the component SHALL return to the locally built baseline recorded by the Deployment
- AND it SHALL NOT switch to the default registry image

### Requirement: Developer Documentation

The repository SHALL include a `DEVELOPMENT.md` guide that documents the local development environment. The guide SHALL cover:

- Prerequisites (Docker or Podman, Kind, kubectl)
- `make kind-up` quickstart with expected output
- Per-component swap workflow (`make kind-<component>-up` / `make kind-<component>-down`)
- Hot reload setup for the web console (`KIND_HOT_RELOAD=true`)
- Environment variable reference (all `KIND_*`, `IMAGE_*`, and `CONTAINER_ENGINE` variables)
- In-cluster Keycloak configuration and local test credentials
- Troubleshooting common issues (port conflicts, container engine not running, image pull failures)

The documentation SHALL be kept in sync with this spec. When a new Make target, environment variable, or component is added, the guide SHALL be updated in the same PR.

#### Scenario: Documentation Exists
- GIVEN a developer clones the repository
- WHEN they look for local development instructions
- THEN `DEVELOPMENT.md` SHALL exist and describe how to set up and use the Kind environment

#### Scenario: Documentation Stays Current
- GIVEN a PR adds or changes a `kind-*` Make target or environment variable
- WHEN the PR is reviewed
- THEN the reviewer SHALL verify that `DEVELOPMENT.md` is updated to reflect the change

### Requirement: Hot Reload Support

The Kind cluster configuration SHALL include `extraMounts` that map a host directory into the cluster nodes, enabling `hostPath` volumes for live source mounting. The web console is the first component to support hot reload.

| Setting | Value |
|---------|-------|
| Host path | `KIND_HOST_MOUNT_PATH` env var (default: repository root via `git rev-parse --show-toplevel`) |
| Container path | `/mnt/host` on each Kind node |
| Read-only | `false` (writable, required for npm file watchers) |

When hot reload is enabled (the default), `kind-<component>-up` for a supported component SHALL mount the host source directory into a non-root development container and run the repository-pinned development server instead of performing a full image rebuild. Before changing the Deployment, the target SHALL use that pinned development image to run a frozen workspace dependency install as the host user. The development server SHALL also run with the invoking user's UID and GID so build-tool cache and transient files remain writable without creating root-owned files in the checkout. This makes the workflow independent of the workstation Node.js version and repairs missing or stale workspace links without weakening checkout permissions. File changes on the host are reflected inside the container immediately. The hot-reload Deployment SHALL use an explicit development resource profile that can optimize and serve the complete browser module graph without restarting. That profile MAY exceed the production console resource profile because it runs the development toolchain in addition to the application. The command SHALL wait for the new rollout generation to become ready and SHALL fail if the replacement pod cannot start. Restoring the baseline SHALL restore the production resource profile from the deployment manifest. When hot reload is disabled (`KIND_HOT_RELOAD=false`), `kind-<component>-up` SHALL rebuild the image from the working tree and replace the deployment as normal.

| Env Var | Default | Description |
|---------|---------|-------------|
| `KIND_HOT_RELOAD` | `true` | Hot reload mode for components that support it; set to `false` to disable |

| Component | Hot Reload Support |
|-----------|-------------------|
| Web Console | Yes — mounts the workspace and runs the pinned pnpm development server |
| API Server | No — Go service, rebuild-and-replace only |
| Control Plane | No — Go service, rebuild-and-replace only |

#### Scenario: Web Console Hot Reload (Default)
- GIVEN a Kind cluster is running
- AND `KIND_HOT_RELOAD` is not set or is `true`
- WHEN a developer runs `make kind-web-console-up`
- THEN the `components/web-console/` source directory SHALL be mounted from the host into the container via a `hostPath` volume
- AND frozen workspace dependencies SHALL be installed with the pinned development image before the Deployment is modified
- AND the repository-pinned Node.js and pnpm versions SHALL run the web-console development server
- AND generated development caches SHALL be written to a container-owned `emptyDir`, not the host-mounted repository
- AND the development resource profile SHALL allow the complete SPA module graph to load without the pod restarting
- AND the new deployment generation SHALL become ready before the command succeeds
- AND file changes on the host SHALL be reflected inside the container without rebuilding

#### Scenario: Restore Web Console Production Resources
- GIVEN the web console is running in hot-reload mode with its development resource profile
- WHEN a developer runs `make kind-web-console-down`
- THEN the hot-reload command, mounts, and development-only environment SHALL be removed
- AND the web console resource profile SHALL be restored from `deploy/kind/web-console.yaml`

#### Scenario: Web Console Without Hot Reload
- GIVEN a Kind cluster is running
- AND `KIND_HOT_RELOAD=false` is set
- WHEN a developer runs `make kind-web-console-up`
- THEN the web console image SHALL be rebuilt from the working tree
- AND the deployment SHALL be replaced with the newly built image

#### Scenario: Hot Reload on Unsupported Component
- GIVEN hot reload is enabled (default)
- WHEN a developer runs `make kind-api-server-up` or `make kind-control-plane-up`
- THEN the component SHALL fall back to the normal rebuild-and-replace flow
- AND an info message SHALL indicate that hot reload is not supported for that component

### Requirement: Container Registry

The system SHALL pull baseline images from the container registry at `quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main/`. The registry path and image tag SHALL be configurable via environment variables.

| Env Var | Default |
|---------|---------|
| `IMAGE_REGISTRY` | `quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main` |
| `IMAGE_TAG` | `latest` |

### Requirement: Offline Development (LOCAL_IMAGES)

The system SHALL support platform development without pulling platform images from the container registry. When `LOCAL_IMAGES=true` is set, `make kind-up` SHALL build every platform component image from the current working tree and load it into the Kind cluster. Third-party prerequisite images must already be cached or remain available from their pinned public registries.

| Env Var | Default | Description |
|---------|---------|-------------|
| `LOCAL_IMAGES` | (unset — pull from registry) | Set to `true` to build baseline images from the local repository instead of pulling from the container registry |

#### Scenario: First Run — Offline
- GIVEN no Kind cluster exists
- AND the developer has no access to the container registry
- AND `LOCAL_IMAGES=true` is set
- WHEN the developer runs `make kind-up`
- THEN all component images SHALL be built from the local repository
- AND images SHALL be loaded into the Kind cluster
- AND the cluster SHALL reach a ready state without any registry pulls for platform components

#### Scenario: Subsequent Run — Rebuild from Working Tree
- GIVEN a Kind cluster is running with locally-built images
- AND `LOCAL_IMAGES=true` is set
- WHEN the developer runs `make kind-up` again
- THEN all non-swapped component images SHALL be rebuilt from the current working tree
- AND updated images SHALL be loaded into the Kind cluster
- AND swapped components SHALL be preserved

### Requirement: Pinned and Restricted Images

HyperShell component images deployed into the Kind cluster SHALL use the same hardened build definitions as production. Third-party development prerequisites, including PostgreSQL, Keycloak, cert-manager, the Kind node, cloud-provider-kind, Envoy Gateway, and the Envoy data plane, SHALL use immutable version, chart digest, or image digest pins and SHALL run with the restricted security context required by `specs/standards/security/security.spec.md`.

The local gateway database SHALL default to a public PostgreSQL image pinned by digest so that a clean checkout does not require private-registry credentials. `KIND_DB_IMAGE` SHALL override this image for developers validating another compatible database build, including Red Hat Hardened Images.

The OpenShell gateway image SHALL come from the locally reconciled GatewayRelease and SHALL be configurable through `KIND_GATEWAY_IMAGE` when that resource is first created or updated.

#### Scenario: Pinned Database Image Used
- GIVEN a Kind cluster is running
- WHEN the control plane reconciler provisions a database for a Gateway
- THEN the database pod SHALL use the image configured by `KIND_DB_IMAGE`
- AND the default image SHALL include an immutable digest

### Requirement: Multiple Namespace Deployments

The system SHALL support deploying the platform into multiple namespaces within a single Kind cluster. Each namespace gets its own set of HyperShell components with isolated hostnames, enabling developers to work on multiple features in parallel (e.g. when handing separate branches to agents).

The system SHALL provide a `make kind-deploy` target that deploys the platform into a new namespace. The namespace is derived from the current git branch name, sanitized to a valid Kubernetes namespace (lowercase, alphanumeric and hyphens, max 63 characters). Each namespace gets its own HTTPRoutes with namespace-prefixed `.localhost` hostnames (e.g. `api.<namespace>.hypershell.localhost`). The default deployment (`make kind-up`) uses the `hypershell-system` namespace and base hostnames; `kind-deploy` creates additional deployments alongside it.

Per-component swap and teardown targets operate on the specified namespace when `KIND_NAMESPACE` is set.

#### Scenario: Deploy to Additional Namespace from Branch
- GIVEN a Kind cluster is running with the default deployment in `hypershell-system`
- AND the developer is on branch `feature/add-auth`
- WHEN they run `make kind-deploy`
- THEN a namespace `hypershell-feature-add-auth` SHALL be created (derived from the branch name)
- AND a full set of HyperShell components SHALL be deployed into that namespace
- AND namespace-scoped HTTPRoutes SHALL be created (e.g. `api.feature-add-auth.hypershell.localhost`)
- AND both deployments SHALL run independently without interference

#### Scenario: Re-deploy Existing Additional Namespace

- GIVEN the current branch namespace has already been deployed
- WHEN the developer runs `make kind-deploy` again
- THEN the existing namespace SHALL be reconciled instead of duplicated
- AND its API resource graph SHALL contain only one resource with each stable local-development name

#### Scenario: Status Reports All Deployments
- GIVEN the platform is deployed into multiple namespaces
- WHEN a developer runs `make kind-status`
- THEN the output SHALL list all namespaces with their hostnames and swap state

#### Scenario: Teardown Namespace Deployment
- GIVEN the platform is deployed in `hypershell-system` and `hypershell-feature-add-auth`
- WHEN a developer runs `make kind-undeploy KIND_NAMESPACE=hypershell-feature-add-auth`
- THEN only the `hypershell-feature-add-auth` namespace and its resources SHALL be deleted
- AND the default deployment in `hypershell-system` SHALL continue running

#### Scenario: Per-Component Swap Scoped to Namespace
- GIVEN the platform is deployed in multiple namespaces
- WHEN a developer runs `KIND_NAMESPACE=hypershell-feature-add-auth make kind-api-server-up`
- THEN the API server SHALL be swapped only in the `hypershell-feature-add-auth` namespace
- AND the default deployment SHALL remain unchanged

## Environment Variable Reference

| Env Var | Default | Description |
|---------|---------|-------------|
| `KIND_CLUSTER_NAME` | `hypershell-dev` | Kind cluster name |
| `KIND_KEYCLOAK_PORT` | `18080` | Canonical Keycloak issuer Service and workstation port |
| `KIND_HOT_RELOAD` | `true` | Hot reload for supported components; set to `false` to disable |
| `KIND_HOST_MOUNT_PATH` | Repository root (`git rev-parse --show-toplevel`) | Host directory mounted into Kind nodes for hot reload |
| `IMAGE_REGISTRY` | `quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main` | Container registry path for baseline images |
| `IMAGE_TAG` | `latest` | Image tag for baseline images |
| `LOCAL_IMAGES` | (unset — pull from registry) | Set to `true` to build baseline images from the current working tree instead of pulling from registry |
| `CONTAINER_ENGINE` | Auto-detected (Podman preferred) | Container engine (`podman` or `docker`) |
| `CLOUD_PROVIDER_KIND_VERSION` | `v0.11.1` | cloud-provider-kind binary version with Gateway API support |
| `ENVOY_GATEWAY_VERSION` | `v1.8.3` | Envoy Gateway controller/data-plane release |
| `CERT_MANAGER_VERSION` | `v1.21.1` | cert-manager release version |
| `KIND_GATEWAY_IMAGE` | Pinned OpenShell gateway image | Image stored in the local GatewayRelease |
| `GATEWAY_API_BASE_DOMAIN` | `gw.localhost` | Hostname suffix used by the controller to derive omitted gateway endpoints |
| `KIND_DB_IMAGE` | Pinned public PostgreSQL 16 image | Database image used by the Gateway reconciler |
| `KIND_NAMESPACE` | `hypershell-system` | Target namespace for deployment; scopes swap/teardown targets to the specified namespace |

## Make Targets Summary

| Target | Behavior |
|--------|----------|
| `make kind-up` | Create cluster (if needed) + pull baseline images from registry + deploy + wait for readiness |
| `make kind-down` | Delete the Kind cluster |
| `make kind-status` | Show cluster info, pods, services, hostnames, and active component swaps |
| `make kind-api-server-up` | Build api-server from working tree + load + replace deployment + wait (cluster must exist; idempotent — rebuilds and replaces on every call) |
| `make kind-api-server-down` | Revert api-server to baseline image + restart + wait |
| `make kind-control-plane-up` | Build control-plane from working tree + load + replace deployment + wait (cluster must exist; idempotent — rebuilds and replaces on every call) |
| `make kind-control-plane-down` | Revert control-plane to baseline image + restart + wait |
| `make kind-web-console-up` | Default (hot reload): mount source + run the pinned Node.js/pnpm dev server and verify its rollout; with `KIND_HOT_RELOAD=false`: build + load + replace deployment + wait |
| `make kind-web-console-down` | Revert web-console to baseline image + restart + wait |
| `make kind-deploy` | Deploy platform into a new namespace (derived from current branch) with namespace-scoped `.localhost` hostnames + wait |
| `make kind-undeploy` | Delete a namespace deployment and its resources (`KIND_NAMESPACE` required) |

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Registry pull for baseline images | Faster setup; no local build required for baseline; per-component swap handles local development |
| Per-component swap for iterative development | More ergonomic than blanket rebuild; discoverable via tab-completion; `LOCAL_IMAGES=true` separately builds every baseline component from the current working tree when registry images are unsuitable or unavailable |
| Gateway-API-only workstation access | All workstation-facing traffic enters through the shared Gateway. Component and Keycloak traffic uses HTTPRoute; OpenShell traffic uses GRPCRoute. The local workflow intentionally has no NodePort or port-forward bypass, so end-to-end checks exercise the production-shaped routing path |
| Pre-check cluster existence for idempotency | Check `kind get clusters` for the target name before attempting creation; skip if already present. Avoids `\|\| true` which swallows real failures (Docker not running, resource exhaustion) |
| Images loaded via tarball archive | Compatible with both Podman and Docker; avoids registry dependency |
| Rebuild-and-replace on every swap call | Each `kind-<component>-up` rebuilds from the working tree and replaces the deployment, even if already swapped; developers iterate by re-running the same target |
| Web console as first-class component | Node.js frontend (`components/web-console/`) deployed alongside API server and control plane; supports hot reload via `KIND_HOT_RELOAD` for rapid UI iteration |
| Hot reload on by default | Swap targets for supported components mount host source into a non-root development container and verify the new rollout; `KIND_HOT_RELOAD=false` opts out to rebuild-and-replace. Keeps the same `kind-<component>-up` entrypoint for both workflows |
| Per-component targets require existing cluster | Avoids implicit full-stack deployment; keeps intent explicit |
| Database provisioned by control plane | Gateway configured with HI postgresql image; control plane reconciler provisions the database via GatewayReconciler (`specs/platform/openshell-gateway-database.spec.md`, implemented in [#14](https://github.com/openshift-online/hypershell/pull/14)), exercising the same path as production. The API server's own database (`deploy/kind/postgres.yaml`) is always deployed directly by `kind-up` |
| Pinned, restricted images | Platform images use the production-hardened build definitions; third-party local prerequisites are pinned immutably and run with restricted security contexts. Public defaults keep the first-run workflow independent of private registry credentials |
| Multiple deployments via namespace isolation | Additional platform deployments go into separate namespaces within the same Kind cluster with distinct hostnames. More performant than separate Kind clusters; shares cluster-level resources (Gateway API CRDs, cert-manager, cloud-provider-kind, Envoy Gateway). Namespace derived from branch name via explicit `kind-deploy` target; each namespace gets namespace-prefixed hostnames (e.g. `api.<namespace>.hypershell.localhost`) |
| Gateway API CRDs from cloud-provider-kind's experimental channel | Experimental channel includes BackendTLSPolicy (required for TLS re-encrypt); keeping CRDs embedded with the pinned controller avoids an independently versioned, incompatible CRD/controller pair |
| Envoy Gateway as Gateway API controller | cloud-provider-kind v0.11.1 allocates LoadBalancer addresses but explicitly does not process GRPCRoute or BackendTLSPolicy. Envoy Gateway supplies those required semantics while cloud-provider-kind exposes its LoadBalancer Service to the host |
| GRPCRoute, not HTTPRoute | OpenShell gateway speaks gRPC; GRPCRoute is the correct Gateway API resource type for gRPC backends |
| BackendTLSPolicy for TLS re-encrypt | Matches production topology — the networking Gateway verifies the pod's cert via CA ConfigMap rather than terminating TLS and sending plaintext to the pod. Exercises the same code path the control plane uses on OpenShift |
| Networking Gateway installed by kind-up | Cluster-level infrastructure (GatewayClass + Gateway), not per-tenant; the control plane only manages per-gateway route resources (GRPCRoute, BackendTLSPolicy, CA ConfigMap) |
| cert-manager as prerequisite | Automates TLS certificate lifecycle (issuance, renewal, rotation) for gateway certificates; eliminates manual re-runs of the certgen job |
| Keycloak for local OIDC | The in-cluster instance mirrors the downstream Keycloak topology (realm `hypershell`, per-gateway clients, provisioner service account) and is the sole local-development issuer |
| OIDC only, no mTLS | Team agreed to drop mTLS client auth; OIDC is the recommended auth mode for Kubernetes deployments per upstream docs |
| TLS always enabled | BackendTLSPolicy re-encrypts traffic from the networking Gateway to the pod (see Gateway API Routing section); the gateway must serve TLS even in local environments. cert-manager issues a self-signed CA for both the wildcard listener cert and the pod's server cert |
| Configurable `IMAGE_REGISTRY` and `IMAGE_TAG` | Allows teams to test against different builds or staging registries |
| Single root Makefile | All targets live in the root Makefile — build, test, codegen, and cluster lifecycle. Component-level Makefiles (`components/api-server/Makefile`, etc.) are deprecated; a single entrypoint eliminates indirection and makes `make <tab>` discoverable. Kind cluster lifecycle shell logic lives in `scripts/kind/` (`lib.sh`, `up.sh`, `down.sh`, `status.sh`, `build-images.sh`, `swap-component.sh`, `deploy-namespace.sh`); the Makefile exports configuration and dispatches to these scripts. Output uses colored headers (`NO_COLOR` respected) |
