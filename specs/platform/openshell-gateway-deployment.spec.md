# OpenShell Gateway Deployment

**Date:** 2026-08-06
**Status:** Active

## Overview

When the control plane receives a Gateway resource event via gRPC watch stream, the GatewayReconciler deploys a full OpenShell gateway stack into the target namespace on the target managed cluster. This spec defines the Kubernetes resources created, their configuration, the provisioning order, and the reconciliation semantics.

Sub-specs cover specific subsystems in detail:
- [Database provisioning](openshell-gateway-database.spec.md)
- [TLS and cert-manager](openshell-gateway-tls.spec.md)
- [Gateway API routing](openshell-gateway-routing.spec.md)
- [OIDC authentication](openshell-gateway-oidc.spec.md)

## Provisioning Order

The GatewayReconciler SHALL apply resources in this order when processing a Gateway ADDED or MODIFIED event. Each step uses update-or-create (reconcile) semantics per `specs/standards/platform/cross-cutting.spec.md`.

1. **Namespace** — Ensure the namespace from `Gateway.namespace` exists on the target cluster.
2. **Database resources** — Secret, PVC, Deployment, Service, NetworkPolicy (only when Gateway has inline `database` config; see [database spec](openshell-gateway-database.spec.md)).
3. **ServiceAccounts** — `openshell-gateway` and `openshell-gateway-sandbox`.
4. **RBAC** — ClusterRole, ClusterRoleBinding, Roles, RoleBindings.
5. **cert-manager resources** — Issuers and Certificates (when cert-manager is available; see [TLS spec](openshell-gateway-tls.spec.md)).
6. **JWT key generation Job** — `openshell-gateway-certgen` (always runs; see [TLS spec](openshell-gateway-tls.spec.md)).
7. **Gateway ConfigMap** — `openshell-gateway-config` containing `gateway.toml`.
8. **Gateway Service** — `openshell-gateway` ClusterIP service.
9. **Gateway Deployment** — `openshell-gateway` with init container, probes, and volume mounts.
10. **NetworkPolicies** — Sandbox, router ingress, and inter-component policies.
11. **GRPCRoute, BackendTLSPolicy, CA ConfigMap** — When Gateway API is available (see [routing spec](openshell-gateway-routing.spec.md)).
12. **OpenShift SCC binding** — When running on OpenShift (see Platform Adjustments).
13. **Status update** — PATCH Gateway phase to `Provisioning`, then `Running` on success.

## Kubernetes Resources

### Gateway Deployment

The reconciler SHALL create a `Deployment` named `openshell-gateway` in the target namespace.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openshell-gateway
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway
    app.kubernetes.io/managed-by: hypershell
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: openshell
      app.kubernetes.io/component: gateway
  template:
    spec:
      serviceAccountName: openshell-gateway
      terminationGracePeriodSeconds: 5
      initContainers:
      - name: wait-for-db
        image: <database image>
        command: ["sh", "-c"]
        args: ["until pg_isready -h openshell-gateway-db -U openshell; do sleep 2; done"]
      containers:
      - name: openshell-gateway
        image: <GatewayRelease.image>
        args: ["--config", "/etc/openshell/gateway.toml"]
        ports:
        - name: grpc
          containerPort: 8080
        - name: health
          containerPort: 8081
        - name: metrics
          containerPort: 9090
        env:
        - name: OPENSHELL_DB_URL
          valueFrom:
            secretKeyRef:
              name: openshell-gateway-db
              key: url
        startupProbe:
          httpGet:
            path: /healthz
            port: health
          periodSeconds: 2
          failureThreshold: 30
        livenessProbe:
          httpGet:
            path: /healthz
            port: health
          initialDelaySeconds: 2
          periodSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /readyz
            port: health
          initialDelaySeconds: 1
          periodSeconds: 2
          failureThreshold: 3
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          readOnlyRootFilesystem: true
          seccompProfile:
            type: RuntimeDefault
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: config
          mountPath: /etc/openshell
        - name: jwt-keys
          mountPath: /etc/openshell-jwt
          readOnly: true
        - name: server-tls
          mountPath: /etc/openshell-tls/server
          readOnly: true
        - name: client-ca
          mountPath: /etc/openshell-tls/client-ca
          readOnly: true
        - name: tmp
          mountPath: /tmp
      volumes:
      - name: config
        configMap:
          name: openshell-gateway-config
      - name: jwt-keys
        secret:
          secretName: openshell-gateway-jwt-keys
          defaultMode: 0440
      - name: server-tls
        secret:
          secretName: openshell-server-tls
      - name: client-ca
        secret:
          secretName: openshell-server-tls
          items:
          - key: ca.crt
            path: ca.crt
      - name: tmp
        emptyDir: {}
```

The `wait-for-db` init container SHALL loop `pg_isready` until the PostgreSQL database is accepting connections. When the Gateway uses an external database (via `database_id` referencing a ManagedDatabase), the init container connects to the ManagedDatabase's host instead.

The gateway image SHALL come from the `GatewayRelease.image` referenced by `Gateway.release_id`.

### Gateway Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: openshell-gateway
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway
    app.kubernetes.io/managed-by: hypershell
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway
  ports:
  - name: grpc
    port: 8080
    targetPort: grpc
    appProtocol: grpc
  - name: metrics
    port: 9090
    targetPort: metrics
```

### ServiceAccounts

The reconciler SHALL create two ServiceAccounts:

| Name | Purpose |
|------|---------|
| `openshell-gateway` | Used by the gateway Deployment |
| `openshell-gateway-sandbox` | Used by sandbox pods spawned by the gateway |

### RBAC

The reconciler SHALL create the following RBAC resources:

| Kind | Name | Purpose |
|------|------|---------|
| ClusterRole | `openshell-gateway-node-reader` | Grants `tokenreviews/create` (authentication.k8s.io) and `nodes/get,list,watch` |
| ClusterRoleBinding | `openshell-gateway-node-reader` | Binds the ClusterRole to the `openshell-gateway` ServiceAccount |
| Role | `openshell-gateway-sandbox` | Grants CRUD on `sandboxes` and `sandboxes/status` (apiGroup `agents.x-k8s.io`), `events/get,list,watch`, and `pods/get` |
| RoleBinding | `openshell-gateway-sandbox` | Binds the sandbox Role to the `openshell-gateway` ServiceAccount |

### Gateway ConfigMap

The reconciler SHALL create a ConfigMap named `openshell-gateway-config` containing a `gateway.toml` file. The TOML is generated from the Gateway resource's fields:

```toml
[openshell.gateway]
bind_address          = "0.0.0.0:8080"
health_bind_address   = "0.0.0.0:8081"
metrics_bind_address  = "0.0.0.0:9090"
log_level             = "info"
sandbox_namespace     = "<Gateway.namespace>"
default_image         = "ghcr.io/nvidia/openshell-community/sandboxes/base:latest"
supervisor_image      = "<supervisor image>"
client_tls_secret_name = "openshell-client-tls"
server_sans           = [<Gateway.server_dns_names>]

[openshell.gateway.tls]
cert_path       = "/etc/openshell-tls/server/tls.crt"
key_path        = "/etc/openshell-tls/server/tls.key"
client_ca_path  = "/etc/openshell-tls/client-ca/ca.crt"

[openshell.gateway.gateway_jwt]
signing_key_path = "/etc/openshell-jwt/signing.pem"
public_key_path  = "/etc/openshell-jwt/public.pem"
kid_path         = "/etc/openshell-jwt/kid"
gateway_id       = "openshell-gateway"
ttl_secs         = 3600

[openshell.drivers.kubernetes]
grpc_endpoint              = "https://openshell-gateway.<namespace>.svc.cluster.local:8080"
service_account_name       = "openshell-gateway-sandbox"
supervisor_sideload_method = "image-volume"
sa_token_ttl_secs          = 3600

# OIDC section injected when Gateway.oidc.issuer is set
# See openshell-gateway-oidc.spec.md
```

When the Gateway has a `config` field set, the reconciler SHALL use its value verbatim as `gateway.toml` content, without injecting OIDC or other computed sections.

### NetworkPolicies

The reconciler SHALL create the following NetworkPolicies:

| Name | Purpose |
|------|---------|
| `openshell-gateway-sandbox-ssh` | Allows ingress on TCP/2222 from gateway pods to sandbox pods |
| `openshell-gateway-allow-sandbox` | Allows sandbox pods to connect to gateway on TCP/8080 and TCP/8081 |
| `openshell-gateway-allow-router` | Allows ingress from the networking Gateway namespace (e.g. `openshift-ingress`) to gateway on TCP/8080 and TCP/8081 |
| `openshell-gateway-db` | Restricts database ingress to only gateway pods on TCP/5432 (when in-cluster database is provisioned) |

### Labels

All resources created by the GatewayReconciler SHALL carry these labels:

```yaml
app.kubernetes.io/name: openshell
app.kubernetes.io/component: gateway
app.kubernetes.io/managed-by: hypershell
```

Database-specific resources SHALL use `app.kubernetes.io/component: gateway-database`.

## Platform Adjustments

### OpenShift

The reconciler SHALL detect OpenShift via API discovery for `route.openshift.io` at startup (not per-reconciliation). When running on OpenShift:

- Pod specs SHALL NOT set `fsGroup` or `runAsUser` (OpenShift SCC assigns UIDs from the namespace range).
- The reconciler SHALL bind the `system:openshift:scc:privileged` ClusterRole to the `openshell-gateway-sandbox` ServiceAccount (sandbox pods require privileged SCC).

### Multi-Cluster

When `Gateway.cluster_id` is set, the reconciler SHALL obtain a `KubeClient` for the target ManagedCluster from the cluster client pool and deploy all resources there. When `cluster_id` is null, resources are deployed to the local cluster.

## Event Handling

### ADDED

The reconciler SHALL validate the Gateway configuration (image reference, DNS names, OIDC config), then apply all Kubernetes resources in provisioning order using update-or-create semantics. The Gateway phase SHALL transition: `Pending` → `Provisioning` → `Running`.

### MODIFIED

The reconciler SHALL detect changes to image, OIDC config, server DNS names, or database config. Changed resources SHALL be updated; unchanged resources SHALL be skipped. Image changes trigger a Deployment rolling update. OIDC or DNS name changes trigger a ConfigMap update and Deployment restart.

### DELETED

The reconciler SHALL delete all Kubernetes resources associated with the Gateway from the target cluster. The namespace itself SHALL NOT be deleted (other resources may share it). The reconciler SHALL collect errors from all deletion steps and return them together.

## Requirements

### Requirement: Gateway Provisioning

The control plane SHALL deploy a complete OpenShell gateway stack when a Gateway resource is created.

#### Scenario: New Gateway with In-Cluster Database
- GIVEN a Gateway resource with inline `database` config and `oidc` config
- WHEN the GatewayReconciler processes the ADDED event
- THEN it SHALL create all resources in provisioning order
- AND the database SHALL be ready before the gateway Deployment starts (init container)
- AND the Gateway phase SHALL transition to `Running` on success

#### Scenario: New Gateway with External Database
- GIVEN a Gateway resource with `database_id` referencing a ManagedDatabase
- WHEN the GatewayReconciler processes the ADDED event
- THEN it SHALL skip in-cluster database provisioning (steps 2)
- AND the gateway Deployment SHALL connect to the ManagedDatabase's connection endpoint
- AND the Gateway phase SHALL transition to `Running` on success

### Requirement: Gateway Image from Release

The gateway container image SHALL be resolved from the `GatewayRelease` referenced by `Gateway.release_id`.

#### Scenario: Image Resolution
- GIVEN a Gateway with `release_id` pointing to a GatewayRelease with `image: ghcr.io/nvidia/openshell/gateway:0.0.99`
- WHEN the reconciler builds the Deployment spec
- THEN the gateway container image SHALL be `ghcr.io/nvidia/openshell/gateway:0.0.99`

### Requirement: Security Context Compliance

All containers in gateway resources SHALL set restricted security contexts: `runAsNonRoot: true`, `capabilities.drop: ["ALL"]`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `seccompProfile.type: RuntimeDefault`. Writable paths SHALL use `emptyDir` volumes.

### Requirement: Idempotent Reconciliation

Every provisioning step SHALL use update-or-create semantics. Re-processing the same Gateway event SHALL produce no unintended side effects.

#### Scenario: Re-Reconcile Running Gateway
- GIVEN a Gateway that is already in phase `Running` with all resources deployed
- WHEN the reconciler processes the same event again
- THEN all resources SHALL be verified/updated in place
- AND no resources SHALL be duplicated
- AND the Gateway phase SHALL remain `Running`

### Requirement: Gateway Deletion Cleanup

When a Gateway is deleted, the reconciler SHALL remove all Kubernetes resources it created.

#### Scenario: Full Cleanup
- GIVEN a running Gateway with database, TLS, routing, and OIDC resources
- WHEN the reconciler processes the DELETED event
- THEN all gateway Kubernetes resources SHALL be deleted from the target cluster
- AND the namespace SHALL NOT be deleted
- AND errors from individual deletion steps SHALL be collected and returned together

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Deployment, not StatefulSet | With PostgreSQL as the database backend, no local persistent state on the gateway pod; Deployment is simpler |
| Init container for DB readiness | Database must be accepting connections before the gateway starts; `pg_isready` loop is robust and portable |
| ClusterIP service only | External access is handled by the networking Gateway via GRPCRoute; the gateway Service does not need to be directly exposed |
| Read-only root filesystem | Security hardening; writable paths (`/tmp`) use emptyDir |
| Separate ServiceAccount for sandboxes | Least-privilege: sandbox pods get only sandbox-scoped permissions, not gateway-level access |
| Platform detection at startup | Avoids per-reconciliation API discovery overhead; OpenShift and cert-manager presence is stable across the control plane's lifetime |
