# Control Plane

**Date:** 2026-08-03
**Status:** Active

## Overview

The HyperShell control plane is a Go service that watches the API server via gRPC streaming RPCs and reconciles the desired state (Fleet resources in the database) into actual Kubernetes resources across managed clusters. It follows the informer-reconciler pattern without depending on controller-runtime.

## Architecture

```
API Server (PostgreSQL)
  │  gRPC watch streams per Kind
  ▼
Control Plane (Watcher + Reconciler)
  │  reconciles into K8s resources
  ▼
Managed Clusters (Gateway pods, Services, Configs)
```

## Components

### Watcher

The Watcher establishes gRPC streaming connections to the API server for each resource Kind (Fleets, Gateways, GatewayReleases, ManagedClusters, ManagedDatabases, GatewayNetworks). On each event (create, update, delete), it dispatches to the Reconciler.

### Reconciler

The Reconciler receives resource events from the Watcher and converges the Kubernetes state on managed clusters to match. Key responsibilities:

- Deploy/update Gateway workloads on target clusters
- Configure network meshes between gateways
- Manage release rollouts (including canary strategies)
- Update resource status back to the API server

#### GatewayReconciler

The GatewayReconciler handles Gateway resource events and deploys the full OpenShell gateway stack. It orchestrates multiple subsystems, each covered by a dedicated spec:

| Subsystem | Spec | Summary |
|-----------|------|---------|
| Gateway deployment | [openshell-gateway-deployment.spec.md](openshell-gateway-deployment.spec.md) | Deployment, Service, RBAC, ConfigMap, NetworkPolicies, provisioning order |
| Database provisioning | [openshell-gateway-database.spec.md](openshell-gateway-database.spec.md) | In-cluster PostgreSQL (Secret, PVC, Deployment, Service) |
| TLS certificates | [openshell-gateway-tls.spec.md](openshell-gateway-tls.spec.md) | cert-manager chain, JWT key generation, SAN management |
| Gateway API routing | [openshell-gateway-routing.spec.md](openshell-gateway-routing.spec.md) | GRPCRoute, BackendTLSPolicy, CA ConfigMap |
| OIDC authentication | [openshell-gateway-oidc.spec.md](openshell-gateway-oidc.spec.md) | OIDC config injection, role validation, auth modes |

#### Startup-Time Detection

The reconciler detects platform capabilities at startup (not per-reconciliation):

| Capability | Detection | Effect |
|-----------|-----------|--------|
| OpenShift | API discovery for `route.openshift.io` | Adjusts SecurityContext, adds SCC bindings |
| cert-manager | API discovery for `cert-manager.io` | Uses cert-manager for TLS certs vs. certgen Job fallback |
| Gateway API | GRPCRoute CRD exists + networking Gateway is `Accepted` | Enables GRPCRoute provisioning |

### Config

Holds connection configuration for the API server gRPC endpoint and Kubernetes client initialization.

## Requirements

### Requirement: gRPC Watch Streams

The control plane SHALL connect to the API server via gRPC watch streams for each resource Kind. On connection failure, it SHALL reconnect with exponential backoff.

#### Scenario: Watch Reconnection
- GIVEN the API server becomes unreachable
- WHEN the gRPC stream disconnects
- THEN the watcher SHALL retry with exponential backoff
- AND resume processing from the last known state

### Requirement: Gateway Reconciliation

The control plane SHALL reconcile Gateway resources into Kubernetes workloads on the target managed cluster. The full provisioning flow — including database, TLS, routing, and OIDC — is defined in the [gateway deployment spec](openshell-gateway-deployment.spec.md) and its sub-specs.

#### Scenario: New Gateway Created
- GIVEN a new Gateway resource appears via the watch stream
- WHEN the reconciler processes it
- THEN it SHALL create the corresponding K8s resources on the cluster identified by `cluster_id`
- AND apply resources in the provisioning order defined in [openshell-gateway-deployment.spec.md](openshell-gateway-deployment.spec.md)
- AND update the Gateway's `phase` to reflect provisioning status

### Requirement: Resource Cleanup

When a Gateway is deleted, the control plane SHALL clean up all associated Kubernetes resources on the target cluster.

#### Scenario: Gateway Deletion
- GIVEN a Gateway deletion event from the watch stream
- WHEN the reconciler processes it
- THEN it SHALL delete all K8s resources associated with that Gateway
- AND confirm cleanup completion

### Requirement: Status Synchronization

The control plane SHALL periodically update the `status` field of resources in the API server to reflect actual cluster state.

#### Scenario: Gateway Health Check
- GIVEN a running Gateway on a managed cluster
- WHEN the control plane checks its health
- THEN it SHALL update the Gateway's `status` in the API server
- AND set `phase` to "Degraded" if the workload is unhealthy

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| gRPC watch streams (not polling) | Real-time event delivery, efficient resource usage |
| Separate module from API server | Independent lifecycle, separate deployment |
| No controller-runtime dependency | Lightweight, custom reconciliation without CRD overhead |
| Multi-cluster client pool | Each managed cluster gets its own KubeClient for isolation |
