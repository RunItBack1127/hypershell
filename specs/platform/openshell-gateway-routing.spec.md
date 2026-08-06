# OpenShell Gateway Routing

**Date:** 2026-08-06
**Status:** Active

## Overview

The control plane uses the Kubernetes Gateway API to route external gRPC traffic to gateway pods. For each Gateway resource, the GatewayReconciler creates a GRPCRoute, BackendTLSPolicy, and CA ConfigMap that connect the cluster's networking Gateway to the gateway Service with TLS re-encryption.

This spec covers per-gateway routing resources managed by the control plane. Cluster-level infrastructure (GatewayClass, networking Gateway) is a prerequisite managed outside the control plane — see [local-development.spec.md](local-development.spec.md) for the Kind environment and the Platform Adjustments section for production clusters.

## Traffic Flow

```
Client
  │  HTTPS/gRPC (external TLS)
  ▼
Networking Gateway (Gateway API data plane)
  │  terminates external TLS
  │  re-encrypts via BackendTLSPolicy
  ▼
openshell-gateway Service (ClusterIP :8080)
  │
  ▼
openshell-gateway Pod (TLS on :8080)
```

1. **Client to networking Gateway:** The client connects via HTTPS with HTTP/2 (ALPN negotiation). The networking Gateway terminates external TLS using its listener certificate.
2. **Networking Gateway to pod:** BackendTLSPolicy instructs the networking Gateway to establish a new TLS connection to the backend, verifying the pod's certificate against the CA in the `openshell-backend-ca` ConfigMap.

## Gateway API Detection

At control plane startup (not per-reconciliation), the reconciler SHALL:

1. Check for the `gateway.networking.k8s.io` API group via API discovery (confirms GRPCRoute CRD is installed).
2. Check for a networking Gateway resource in the configured namespace with `Accepted: True` status condition.
3. If both conditions are met, enable GRPCRoute provisioning (`hasGatewayAPI = true`).

When Gateway API is not available, the reconciler SHALL skip routing resource creation and log a warning. The gateway remains accessible only via direct Service access (e.g. `kubectl port-forward`).

### Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `GATEWAY_API_GATEWAY_NAME` | `hypershell-gw` | Name of the networking Gateway resource |
| `GATEWAY_API_GATEWAY_NAMESPACE` | `hypershell-system` | Namespace of the networking Gateway resource |
| `GATEWAY_API_BASE_DOMAIN` | Auto-detected | Base domain for gateway hostnames (on OpenShift: derived from `ingresses.config.openshift.io/cluster`) |

## Per-Gateway Routing Resources

When Gateway API is available, the reconciler SHALL create three resources per Gateway in the Gateway's namespace:

### GRPCRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: openshell-gateway
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway
    app.kubernetes.io/managed-by: hypershell
spec:
  parentRefs:
  - name: <GATEWAY_API_GATEWAY_NAME>
    namespace: <GATEWAY_API_GATEWAY_NAMESPACE>
  hostnames:
  - <derived hostname>
  rules:
  - backendRefs:
    - name: openshell-gateway
      port: 8080
```

The GRPCRoute matches all gRPC traffic to the derived hostname and forwards it to the gateway Service on port 8080. No method or header matchers are applied — the route catches all gRPC methods.

#### Hostname Derivation

The route hostname SHALL be derived as:
- **Kind (local):** `<gateway-name>.gw.localhost`
- **OpenShift:** `<gateway-name>-<namespace>.gw.<base-domain>`

When the Gateway has an explicit `external_dns` field set, that value SHALL be used instead of the derived hostname.

### BackendTLSPolicy

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha3
kind: BackendTLSPolicy
metadata:
  name: openshell-gateway
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway
    app.kubernetes.io/managed-by: hypershell
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
    hostname: openshell-gateway.<namespace>.svc.cluster.local
```

The BackendTLSPolicy instructs the networking Gateway's data plane (Envoy) to:
1. Establish a TLS connection to the backend pod.
2. Verify the pod's server certificate against the CA in the `openshell-backend-ca` ConfigMap.
3. Validate that the certificate's SAN matches `openshell-gateway.<namespace>.svc.cluster.local`.

The `v1alpha3` API version ships in the Gateway API experimental channel. The version SHALL track the `GATEWAY_API_VERSION` variable.

### CA ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openshell-backend-ca
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway
    app.kubernetes.io/managed-by: hypershell
data:
  ca.crt: |
    <contents of openshell-server-tls Secret ca.crt>
```

The reconciler SHALL read the `ca.crt` from the `openshell-server-tls` Secret (created by cert-manager or the certgen Job) and populate this ConfigMap. The ConfigMap SHALL be updated whenever the server certificate is re-issued (e.g. after SAN changes).

## Route Address Discovery

After creating the GRPCRoute, the reconciler SHALL derive the route address from the hostname and PATCH the Gateway resource's `route_address` field via the API server:

- Format: `grpcs://<hostname>:443`
- Example: `grpcs://openshell-gateway.gw.localhost:443`

This address is displayed to users (e.g. in the web console or CLI output) as the gateway's external endpoint.

## NetworkPolicy for Router Ingress

The reconciler SHALL create a NetworkPolicy allowing traffic from the networking Gateway's namespace to reach gateway pods:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: openshell-gateway-allow-router
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/managed-by: hypershell
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: gateway
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: <GATEWAY_API_GATEWAY_NAMESPACE>
    ports:
    - port: 8080
      protocol: TCP
    - port: 8081
      protocol: TCP
```

Without this NetworkPolicy, the networking Gateway's proxy cannot reach the gateway pod, causing TLS handshake hangs.

## Cluster Prerequisites

The following resources are NOT managed by the control plane reconciler. They must exist before gateway routing can function:

| Resource | Description | Managed By |
|----------|-------------|------------|
| GatewayClass | Registers the gateway controller (e.g. `cloud-provider-kind`, `openshift-default`) | Cluster admin / `make kind-up` |
| Networking Gateway | Shared ingress point with HTTPS listeners | Cluster admin / `make kind-up` |
| Gateway API CRDs | GRPCRoute, BackendTLSPolicy, and related CRDs | Cluster admin / `make kind-up` |

See [local-development.spec.md](local-development.spec.md) for Kind cluster prerequisites.

## RBAC Requirements

The control plane ServiceAccount SHALL have the following RBAC:

```yaml
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["grpcroutes", "backendtlspolicies"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["gateways"]
  verbs: ["get", "list"]
```

The `gateways` read permission is needed for startup detection of the networking Gateway.

## Requirements

### Requirement: GRPCRoute Provisioning

When Gateway API is available, the reconciler SHALL create a GRPCRoute for each Gateway resource.

#### Scenario: Route Created
- GIVEN a new Gateway resource and Gateway API is available on the target cluster
- WHEN the GatewayReconciler processes the ADDED event
- THEN it SHALL create a GRPCRoute referencing the networking Gateway
- AND the route hostname SHALL be derived from the gateway name and base domain
- AND a BackendTLSPolicy SHALL be created for TLS re-encryption
- AND a CA ConfigMap SHALL be created with the gateway's CA certificate
- AND the Gateway's `route_address` SHALL be PATCHed with the derived endpoint URL

#### Scenario: Gateway API Not Available
- GIVEN Gateway API CRDs are not installed on the target cluster
- WHEN the GatewayReconciler processes a Gateway event
- THEN it SHALL skip GRPCRoute, BackendTLSPolicy, and CA ConfigMap creation
- AND it SHALL log a warning indicating Gateway API routing is not available
- AND the Gateway's `route_address` SHALL remain empty

### Requirement: Route Cleanup

When a Gateway is deleted, its routing resources SHALL be removed.

#### Scenario: Route Deleted
- GIVEN a Gateway with an active GRPCRoute
- WHEN the Gateway is deleted
- THEN the GRPCRoute, BackendTLSPolicy, and CA ConfigMap SHALL be deleted

### Requirement: CA Certificate Synchronization

The CA ConfigMap SHALL stay in sync with the gateway's server certificate CA.

#### Scenario: Certificate Re-Issued
- GIVEN a Gateway with an active GRPCRoute and BackendTLSPolicy
- WHEN the gateway's server certificate is re-issued (e.g. due to SAN change)
- THEN the `openshell-backend-ca` ConfigMap SHALL be updated with the new CA certificate

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| GRPCRoute, not HTTPRoute | OpenShell gateway speaks gRPC; GRPCRoute is the correct Gateway API resource for gRPC backends |
| BackendTLSPolicy for TLS re-encrypt | Preserves end-to-end TLS; the networking Gateway verifies the pod's cert rather than sending plaintext |
| CA ConfigMap, not Secret | BackendTLSPolicy `caCertificateRefs` supports ConfigMap references; CA certificates are not sensitive |
| Hostname derivation from gateway name | Predictable, DNS-safe hostnames without user intervention; `external_dns` provides an override |
| Detection at startup, not per-reconciliation | Networking Gateway presence is stable; avoids API discovery on every event |
| No method/header matchers on GRPCRoute | The gateway handles its own method routing; the GRPCRoute is a pure traffic forwarder |
