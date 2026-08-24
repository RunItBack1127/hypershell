# OpenShell Gateway Database Specification

**Date:** 2026-08-24
**Status:** Draft
**Parent:** `openshell-gateway.spec.md` - core gateway provisioning

---

## Purpose

This specification defines PostgreSQL database provisioning for OpenShell gateways. The control plane supports two parallel deployment modes, selected via the `DATABASE_PROVIDER` environment variable:

| Mode | `DATABASE_PROVIDER` | Description |
|---|---|---|
| **CNPG** (default) | `cnpg` | Uses the [CloudNativePG](https://cloudnative-pg.io/) operator. Multiple gateways share one ManagedDatabase's CNPG Cluster; each gateway gets its own logical database inside it. Requires the CNPG operator to be installed on the cluster. |
| **Deployment** | `deployment` | Uses a standalone PostgreSQL Deployment per gateway. No operator required. Each gateway gets its own dedicated ManagedDatabase (and thus its own PostgreSQL pod) created automatically at gateway creation time. Suitable for environments where installing the CNPG operator is not feasible (e.g. minimal dev clusters). |

PostgreSQL is the only supported database backend for HyperShell gateways.

---

## Prerequisites

### CNPG Mode

The CNPG operator SHALL be installed on every managed cluster as a cluster-level prerequisite, similar to cert-manager. The operator provides the `Cluster`, `Database`, and `DatabaseRole` CRDs.

- In the Kind development environment with CNPG mode, `make kind-up` installs the operator (see `local-development.spec.md`)
- In production environments, the platform administrator installs the operator before registering the cluster with HyperShell

The control plane SHALL detect the CNPG operator presence by checking for the `postgresql.cnpg.io/v1` API group. If the operator is absent and `DATABASE_PROVIDER=cnpg`, gateway provisioning SHALL fail with an explicit error.

### Deployment Mode

No operator prerequisites. The control plane provisions a standard PostgreSQL Deployment using the `postgres:18` image (or the image configured via `OPENSHELL_DATABASE_IMAGE`).

---

## Architecture

### ManagedDatabase as the Database Abstraction Layer

In both modes, a `ManagedDatabase` resource is the indirection between a gateway and its PostgreSQL infrastructure. A `Gateway` has a `database_id` foreign key pointing to a `ManagedDatabase`. The `ManagedDatabase` has a `provider` field (`cnpg` or `deployment`) that determines how the ManagedDatabaseReconciler provisions its infrastructure, and a `namespace` field (auto-assigned at creation) that locates that infrastructure in the cluster.

### CNPG Mode Architecture

```
ManagedDatabase (provider=cnpg)
  │  ManagedDatabaseReconciler
  ▼
Namespace: openshell-db-<hex16>
  └── CNPG Cluster: openshell-db
        │  GatewayReconciler (per gateway)
        ├── DatabaseRole: gw-<gatewayID>
        ├── Database: gw-<gatewayID>
        └── Secret: gw-<gatewayID>-credentials

Gateway A ──database_id──→ ManagedDatabase ──namespace──→ CNPG Cluster
Gateway B ──database_id──→ ManagedDatabase ──namespace──→ CNPG Cluster (same)
Gateway C ──database_id──→ ManagedDatabase (different) ──→ different CNPG Cluster
```

Multiple gateways can share one ManagedDatabase. The ManagedDatabaseReconciler creates the CNPG Cluster once; the GatewayReconciler adds per-gateway `DatabaseRole`, `Database`, and password `Secret` CRs to it.

### Deployment Mode Architecture

```
Gateway created
  │  API server (deploymentPlacement)
  ▼
ManagedDatabase (provider=deployment) ← auto-created per gateway
  │  ManagedDatabaseReconciler
  ▼
Namespace: openshell-db-<hex16>
  ├── PVC: openshell-gateway-db-data
  ├── Deployment: openshell-gateway-db (postgres:18)
  ├── Service: openshell-gateway-db
  └── Secret: openshell-db-credentials

GatewayReconciler
  └── copies Secret → openshell-gateway-db-credentials (tenant namespace)
```

Each gateway gets its own dedicated ManagedDatabase (and thus its own PostgreSQL pod). The API server auto-creates the ManagedDatabase at gateway creation time; no pre-existing database resource is required.

### ManagedDatabase Namespace Naming

In both modes, the ManagedDatabase namespace is derived from the ManagedDatabase's KSUID using the same pattern as gateway namespaces: `openshell-db-<hex16>`, where `<hex16>` is the lowercase hexadecimal encoding of 8 bytes from the KSUID's random payload. The API server assigns this namespace in `BeforeCreate`. Example: `openshell-db-a1b2c3d4e5f67890`.

### Automatic Fleet and Database Assignment

The API server resolves missing relationship fields at gateway creation time, following a resolution chain: `cluster_id` → `fleet_id` → `database_id`. The `database_id` resolution strategy depends on `DATABASE_PROVIDER`:

**CNPG mode (`cnpgPlacement`):** When a Gateway is created with a blank `database_id`, the API server looks up existing ManagedDatabases:
1. If `fleet_id` is present (explicitly or resolved from `cluster_id`), query all ManagedDatabases in the fleet. If exactly one exists, auto-assign its ID. If zero or more than one exist, reject the request.
2. If `fleet_id` is also blank, query all ManagedDatabases globally. If exactly one exists, auto-assign its ID and `fleet_id`. If zero or more than one exist, reject the request.

**Deployment mode (`deploymentPlacement`):** When a Gateway is created with a blank `database_id`, the API server auto-creates a new ManagedDatabase (provider=deployment) for that gateway and assigns its ID. No pre-existing ManagedDatabase is needed.

The admin workflows differ accordingly:

| | CNPG mode | Deployment mode |
|---|---|---|
| Pre-requisite | Create a ManagedDatabase (provider=cnpg) in the fleet | None |
| Gateway creation | Provide `name` (and optionally `cluster_id`); fleet and database auto-resolved | Provide `name` (and optionally `cluster_id`); ManagedDatabase auto-created |

In the Kind development environment, `make kind-up` seeds a single `openshell-db` ManagedDatabase in CNPG mode; no seeding is needed in deployment mode.

---

## Requirements

### Requirement: ManagedDatabase Reconciliation (provider=cnpg)

The ManagedDatabaseReconciler SHALL provision CNPG infrastructure for each ManagedDatabase with `provider: "cnpg"`.

For each such ManagedDatabase, the reconciler SHALL:

1. **Create the namespace** derived from the ManagedDatabase ID (`openshell-db-<hex16>`), if it does not exist
2. **Create a CNPG Cluster CR** in that namespace:
   - `metadata.name` = `openshell-db` (fixed name; isolation is per-namespace, not per-cluster-name)
   - `spec.instances` = 1 (fixed default)
   - `spec.storage.size` = `1Gi` (fixed default)
   - `spec.resources` = `requests: {memory: 256Mi}`, `limits: {memory: 512Mi}`
   - `spec.imageName` = value of `OPENSHELL_DATABASE_IMAGE` env var (omitted when unset; CNPG uses its default image)
3. **Wait for the CNPG Cluster** to reach `Ready` status (all instances running)
4. **Update the ManagedDatabase status** in the API server to reflect readiness

#### Scenario: New ManagedDatabase created (provider=cnpg)

- GIVEN a new ManagedDatabase resource with `provider: "cnpg"`
- WHEN the ManagedDatabaseReconciler processes the event
- THEN it SHALL create the namespace `openshell-db-<hex16>`
- AND it SHALL create a CNPG Cluster CR in that namespace
- AND it SHALL wait for the Cluster to reach Ready
- AND it SHALL update the ManagedDatabase status

#### Scenario: ManagedDatabase already exists (idempotent, cnpg)

- GIVEN a ManagedDatabase whose CNPG Cluster is already running
- WHEN the ManagedDatabaseReconciler re-processes the event
- THEN it SHALL verify the namespace and Cluster exist
- AND it SHALL NOT recreate them

---

### Requirement: ManagedDatabase Reconciliation (provider=deployment)

The ManagedDatabaseReconciler SHALL provision a standalone PostgreSQL Deployment for each ManagedDatabase with `provider: "deployment"`.

For each such ManagedDatabase, the reconciler SHALL:

1. **Create the namespace** derived from the ManagedDatabase ID (`openshell-db-<hex16>`), if it does not exist
2. **Create or update a credentials Secret** (`openshell-db-credentials`) in that namespace:
   - `username` = `postgres`
   - `password` = 32-byte cryptographically random hex string (`crypto/rand`), generated once and reused on subsequent reconciliations (create-or-skip semantics)
   - `database` = `postgres`
   - `uri` = `postgresql://postgres:<password>@openshell-gateway-db.<namespace>.svc.cluster.local:5432/postgres?sslmode=disable`
3. **Create or update a PVC** (`openshell-gateway-db-data`, `1Gi`)
4. **Create or update a Deployment** (`openshell-gateway-db`) running `postgres:18` (or `OPENSHELL_DATABASE_IMAGE`):
   - Mounts the PVC at `/var/lib/postgresql/data`
   - Reads `POSTGRES_PASSWORD` from the credentials Secret
   - `securityContext`: `runAsNonRoot: true`, drops `ALL` capabilities
5. **Create or update a Service** (`openshell-gateway-db`, port 5432, ClusterIP)
6. **Wait up to 2 minutes** for the Deployment to become ready (all replicas available)
7. **Update the ManagedDatabase status** in the API server to reflect readiness

All resources carry label `hypershell.redhat.io/managed: "true"` and the `app: openshell-gateway-db` selector.

#### Scenario: New ManagedDatabase created (provider=deployment)

- GIVEN a new ManagedDatabase resource with `provider: "deployment"`
- WHEN the ManagedDatabaseReconciler processes the event
- THEN it SHALL create the namespace, credentials Secret, PVC, Deployment, and Service
- AND it SHALL wait for the Deployment to become ready (2-minute timeout)
- AND it SHALL update the ManagedDatabase status

#### Scenario: ManagedDatabase already exists (idempotent, deployment)

- GIVEN a ManagedDatabase whose Deployment is already running
- WHEN the ManagedDatabaseReconciler re-processes the event
- THEN it SHALL reconcile each resource (create-or-update) without regenerating the password

#### Scenario: Deployment readiness timeout (provider=deployment)

- GIVEN a ManagedDatabase with `provider: "deployment"`
- WHEN the Deployment does not become ready within 2 minutes
- THEN the reconciler SHALL return an error
- AND the ManagedDatabase phase SHALL remain `Provisioning`
- AND the next reconciliation SHALL retry

---

### Requirement: ManagedDatabase Deletion Protection

A ManagedDatabase SHALL NOT be deleted if any Gateway references it via `database_id`. This prevents orphaned gateway databases.

#### Scenario: Attempt to delete ManagedDatabase with referencing gateways

- GIVEN a ManagedDatabase referenced by one or more Gateways
- WHEN a user attempts to delete the ManagedDatabase
- THEN the API server SHALL reject the deletion with HTTP 409: "managed database cannot be deleted while gateways reference it; reassign or delete all referencing gateways first"

#### Scenario: Delete ManagedDatabase (cnpg) with no referencing gateways

- GIVEN a ManagedDatabase (provider=cnpg) with no Gateway references
- WHEN a user deletes the ManagedDatabase
- THEN the ManagedDatabaseReconciler SHALL delete the CNPG Cluster CR
- AND delete the namespace `openshell-db-<hex16>`

#### Scenario: Delete ManagedDatabase (deployment) with no referencing gateways

- GIVEN a ManagedDatabase (provider=deployment) with no Gateway references
- WHEN a user deletes the ManagedDatabase
- THEN the ManagedDatabaseReconciler SHALL delete the Deployment, Service, PVC, and credentials Secret
- AND delete the namespace `openshell-db-<hex16>`

---

### Requirement: Gateway Database Resolution

The GatewayReconciler SHALL resolve the gateway's `database_id` to a ManagedDatabase resource to determine the provider and the infrastructure location. The global `CNPG_CLUSTER_NAME`/`CNPG_CLUSTER_NAMESPACE` environment variables are removed; each gateway's database target is derived from its ManagedDatabase. Every gateway MUST have a `database_id`; a missing value is an error.

#### Resolution flow:

1. Read the gateway's `database_id` from the gRPC watch event
2. Look up the ManagedDatabase resource via the API server
3. Extract `namespace` and `provider`
4. Dispatch based on `provider` and the control plane's `DATABASE_PROVIDER` setting

#### Scenario: Gateway with valid database_id (cnpg)

- GIVEN a Gateway with a `database_id` pointing to a ManagedDatabase (provider=cnpg)
- WHEN the GatewayReconciler processes the event
- THEN it SHALL resolve the ManagedDatabase's namespace and cluster name
- AND proceed with per-gateway CNPG resource provisioning in that namespace

#### Scenario: Gateway with valid database_id (deployment)

- GIVEN a Gateway with a `database_id` pointing to a ManagedDatabase (provider=deployment)
- WHEN the GatewayReconciler processes the event
- THEN it SHALL read the credentials Secret from the ManagedDatabase's namespace
- AND copy it into the gateway's tenant namespace as `openshell-gateway-db-credentials`

#### Scenario: Gateway created with cluster_id only (fleet and database auto-resolved, cnpg mode)

- GIVEN `DATABASE_PROVIDER=cnpg` and a Gateway with a non-empty `cluster_id`, blank `fleet_id`, and blank `database_id`
- WHEN the API server processes the creation request
- THEN the API server SHALL look up the ManagedCluster by `cluster_id`
- AND assign the cluster's `fleet_id` to the gateway
- AND query all ManagedDatabases in the resolved fleet
- AND if exactly one exists, assign its ID as the gateway's `database_id`
- AND if zero or more than one exist, reject the creation with an error

#### Scenario: Gateway created (deployment mode, ManagedDatabase auto-created)

- GIVEN `DATABASE_PROVIDER=deployment` and a Gateway with a blank `database_id`
- WHEN the API server processes the creation request
- THEN the API server SHALL auto-create a new ManagedDatabase (provider=deployment) for this gateway
- AND assign the new ManagedDatabase's ID as the gateway's `database_id`

---

### Requirement: Per-Gateway Database Provisioning (CNPG Mode)

In CNPG mode, the GatewayReconciler SHALL provision a dedicated PostgreSQL database and role for each gateway using CNPG custom resources. All CNPG resources (DatabaseRole, Database, and the password Secret) SHALL be created in the ManagedDatabase's namespace.

For each gateway, the reconciler SHALL create three resources in the ManagedDatabase's namespace:

1. **Password Secret** (`gw-<gatewayID>-credentials`)
   - Type: `kubernetes.io/basic-auth`
   - `username` = `gw_<gatewayID>` (the PostgreSQL role name)
   - `password` = 32-byte cryptographically random hex string (`crypto/rand`)
   - Label: `cnpg.io/reload: "true"` (ensures CNPG applies password changes immediately)
   - Label: `hypershell.redhat.io/managed: "true"`
   - Created with create-or-skip semantics (do NOT update password on re-reconciliation)

2. **DatabaseRole** (`gw-<gatewayID>`)
   - Kind: `DatabaseRole` (apiVersion: `postgresql.cnpg.io/v1`)
   - `spec.cluster.name` = the ManagedDatabase's CNPG Cluster name
   - `spec.name` = `gw_<gatewayID>` (the PostgreSQL role name; underscores for valid SQL identifiers)
   - `spec.login` = `true`
   - `spec.passwordSecret.name` = `gw-<gatewayID>-credentials`
   - `spec.databaseRoleReclaimPolicy` = `delete` (drop role when CR is deleted)
   - Label: `hypershell.redhat.io/managed: "true"`
   - Label: `hypershell.redhat.io/gateway-namespace: "<tenant-namespace>"` (for cleanup)

3. **Database** (`gw-<gatewayID>`)
   - Kind: `Database` (apiVersion: `postgresql.cnpg.io/v1`)
   - `spec.cluster.name` = the ManagedDatabase's CNPG Cluster name
   - `spec.name` = `gw_<gatewayID>` (the PostgreSQL database name)
   - `spec.owner` = `gw_<gatewayID>` (same as the role)
   - `spec.databaseReclaimPolicy` = `delete` (drop database when CR is deleted)
   - Label: `hypershell.redhat.io/managed: "true"`
   - Label: `hypershell.redhat.io/gateway-namespace: "<tenant-namespace>"` (for cleanup)

> **Naming convention:** `<gatewayID>` is the Gateway's full resource ID (lowercased). The database and role use underscores (`gw_<gatewayID>`) because PostgreSQL identifiers conventionally avoid hyphens. The Kubernetes CR names use hyphens (`gw-<gatewayID>`) per Kubernetes naming conventions.

The reconciler SHALL then wait for the CNPG `Database` CR to reach `status.applied: true` (2-minute timeout) before creating the tenant-namespace credentials Secret and proceeding to deploy the gateway workload.

---

### Requirement: Per-Gateway Database Provisioning (Deployment Mode)

In deployment mode, the GatewayReconciler SHALL copy the shared credentials Secret from the ManagedDatabase's namespace into the gateway's tenant namespace. The PostgreSQL instance is already provisioned by the ManagedDatabaseReconciler; the gateway reconciler only propagates access.

The reconciler SHALL:

1. Read the `openshell-db-credentials` Secret from the ManagedDatabase's namespace
2. Create or update `openshell-gateway-db-credentials` in the gateway's tenant namespace with the same connection details

No CNPG CRs are created. No readiness wait is required beyond what the ManagedDatabaseReconciler already ensures.

---

### Requirement: Gateway Credentials Secret

After per-gateway database provisioning, the GatewayReconciler SHALL ensure a credentials Secret named `openshell-gateway-db-credentials` exists in the gateway's tenant namespace. The gateway workload consumes this Secret for its database connection.

The Secret contents differ by provider:

**CNPG mode:**

| Key | Value |
|---|---|
| `host` | `openshell-db-rw.<managed-db-namespace>.svc.cluster.local` |
| `port` | `5432` |
| `dbname` | `gw_<gatewayID>` |
| `user` | `gw_<gatewayID>` |
| `password` | generated password |
| `uri` | `postgresql://gw_<gatewayID>:<password>@<host>:5432/gw_<gatewayID>?sslmode=require` |

**Deployment mode:**

| Key | Value |
|---|---|
| `host` | `openshell-gateway-db.<managed-db-namespace>.svc.cluster.local` |
| `port` | `5432` |
| `dbname` | `postgres` |
| `user` | `postgres` |
| `password` | generated password (from the ManagedDatabase's credentials Secret) |
| `uri` | `postgresql://postgres:<password>@<host>:5432/postgres?sslmode=disable` |

The `uri` key provides the full connection string for the gateway's `--db-url` argument. The gateway Deployment SHALL reference this Secret via environment variable.

> **TLS:** CNPG clusters enable TLS by default (`sslmode=require`). Deployment mode uses a plain TCP connection without TLS (`sslmode=disable`). Upgrading deployment mode to TLS is a future hardening step.

---

### Requirement: Database Provisioning Readiness

**CNPG mode:** The GatewayReconciler SHALL wait for the CNPG `Database` CR to reach `status.applied: true` (2-minute timeout) before proceeding to deploy the gateway workload.

**Deployment mode:** The ManagedDatabaseReconciler waits for the Deployment to become ready (2-minute timeout) before marking the ManagedDatabase ready. The GatewayReconciler does not add an additional wait beyond checking that the credentials Secret is present.

#### Scenario: Database provisioning completes successfully (cnpg)

- GIVEN a new Gateway resource (cnpg mode)
- WHEN the GatewayReconciler creates the DatabaseRole and Database CRs
- AND the CNPG operator reconciles them (`status.applied: true`)
- THEN the reconciler SHALL proceed to deploy the gateway workload

#### Scenario: Database provisioning times out (cnpg)

- GIVEN a new Gateway resource (cnpg mode)
- WHEN the CNPG Database CR does not reach `status.applied: true` within 2 minutes
- THEN the reconciler SHALL return an error
- AND the Gateway phase SHALL remain `Provisioning`
- AND the next reconciliation SHALL retry

---

### Requirement: Database Credential Security

- Passwords SHALL be generated using `crypto/rand` (32 bytes, hex-encoded)
- Passwords SHALL NEVER appear in log messages or error strings
- Password Secrets SHALL be created with create-or-skip semantics (do NOT update password on re-reconciliation)
- In CNPG mode, the `cnpg.io/reload: "true"` label on the password Secret ensures CNPG picks up password changes immediately when rotation occurs

---

### Requirement: Manual Credential Rotation

The GatewayReconciler SHALL support manual database credential rotation for CNPG mode gateways.

- To trigger rotation, an operator adds the annotation `hypershell.redhat.io/rotate-db-credentials: "<timestamp>"` to the Gateway resource
- When the reconciler detects a new value for this annotation (different from the last-observed value stored on the gateway credentials Secret), it SHALL:
  1. Generate a new password using `crypto/rand`
  2. Update the password Secret (`gw-<gatewayID>-credentials`) in the ManagedDatabase namespace
  3. The CNPG operator applies the password change to PostgreSQL automatically (via the `cnpg.io/reload` label)
  4. Update the gateway credentials Secret (`openshell-gateway-db-credentials`) in the tenant namespace
  5. Set annotation `hypershell.redhat.io/last-db-rotation` on the gateway credentials Secret to match the trigger annotation
  6. The config-hash annotation on the Deployment changes, triggering a rolling restart

The full rotation design (procedure, failure handling, config-hash coverage) is specified in [`openshell-gateway-secret-rotation.spec.md`](./openshell-gateway-secret-rotation.spec.md).

---

### Requirement: Gateway Workload Type

The gateway workload SHALL always be deployed as a Deployment (not a StatefulSet). In both modes, the gateway workload does not require persistent local storage; database storage is managed by the ManagedDatabase's infrastructure (CNPG Cluster or standalone Deployment).

---

### Requirement: Database Resource Provisioning Order

In CNPG mode, CNPG resources (password Secret, DatabaseRole, Database) SHALL be created BEFORE the gateway workload. After creating the Database CR, the control plane SHALL wait for `status.applied: true` (2-minute timeout) before deploying the gateway.

In deployment mode, the ManagedDatabase's Deployment SHALL be ready before the GatewayReconciler attempts to copy the credentials Secret.

---

### Requirement: Gateway Deletion Cleanup

When a Gateway is deleted:

**CNPG mode:** The control plane SHALL delete the CNPG resources in the ManagedDatabase's namespace:

1. Delete the `Database` CR (`gw-<gatewayID>`) -- CNPG drops the PostgreSQL database (`databaseReclaimPolicy: delete`)
2. Delete the `DatabaseRole` CR (`gw-<gatewayID>`) -- CNPG drops the PostgreSQL role (`databaseRoleReclaimPolicy: delete`)
3. Delete the password Secret (`gw-<gatewayID>-credentials`) in the ManagedDatabase namespace

CNPG resources in the ManagedDatabase namespace are identified for cleanup using the label `hypershell.redhat.io/gateway-namespace: "<tenant-namespace>"`.

**Deployment mode:** Because each gateway has its own dedicated ManagedDatabase, the ManagedDatabase is deleted along with the gateway (since it will have no remaining references). ManagedDatabase deletion triggers cleanup of the Deployment, Service, PVC, and credentials Secret in the ManagedDatabase namespace.

**Both modes:** Resources in the gateway's tenant namespace (including `openshell-gateway-db-credentials`) are cleaned up by the existing label-based cleanup (`hypershell.redhat.io/managed: "true"`).

#### Scenario: Delete gateway (cnpg mode)

- GIVEN a Gateway (cnpg mode) with no active sandboxes
- WHEN a user deletes the Gateway
- THEN the control plane SHALL delete CNPG resources (Database, DatabaseRole, password Secret) from the ManagedDatabase namespace
- AND delete all resources with label `hypershell.redhat.io/managed: "true"` from the tenant namespace

#### Scenario: Delete gateway (deployment mode)

- GIVEN a Gateway (deployment mode) with no active sandboxes
- WHEN a user deletes the Gateway
- THEN the control plane SHALL delete the gateway's dedicated ManagedDatabase
- AND the ManagedDatabaseReconciler SHALL delete the Deployment, Service, PVC, credentials Secret, and namespace
- AND delete all resources with label `hypershell.redhat.io/managed: "true"` from the tenant namespace

---

### Requirement: Gateway Deletion With Active Sandboxes (Advisory)

Active sandboxes SHALL NOT block Gateway deletion. Before an operator deletes a
Gateway, the active sandbox count is surfaced as a warning so they can see how
many running sessions the deletion would disrupt (see
[`openshell-gateway-namespace-gc.spec.md`](./openshell-gateway-namespace-gc.spec.md)
§ Surface Active Sandbox Count Before Deletion and
[`openshell-gateway-sandbox-count.spec.md`](./openshell-gateway-sandbox-count.spec.md)),
but the count is advisory only: deletion proceeds regardless and reclaims the
gateway's resources.

#### Scenario: Delete gateway that has active sandboxes

- GIVEN a Gateway with one or more active sandboxes
- WHEN a user deletes the Gateway (having been warned of the active sandbox count)
- THEN the API server SHALL accept the deletion and SHALL NOT reject it on account of the active sandboxes
- AND the control plane SHALL reclaim the gateway's namespace, disrupting those sandboxes and cascading removal of their in-namespace resources

---

### Requirement: CNPG Operator Detection

When `DATABASE_PROVIDER=cnpg` (or unset), the control plane SHALL detect the CNPG operator at startup by checking for the `postgresql.cnpg.io/v1` API group in the cluster's discovery information. If the CNPG operator is not available, gateway provisioning SHALL fail with an explicit error: "CNPG operator is required but not available on the cluster."

When `DATABASE_PROVIDER=deployment`, this check is skipped and no CNPG operator is required.

---

## Configuration Reference

| Variable | Type | Default | Description |
|---|---|---|---|
| `DATABASE_PROVIDER` | env var | `cnpg` | Selects the database deployment mode. Valid values: `cnpg`, `deployment`. |
| `OPENSHELL_DATABASE_IMAGE` | env var | (unset) | PostgreSQL image override. In CNPG mode: sets `spec.imageName` on the CNPG Cluster CR. In deployment mode: sets the container image for the PostgreSQL Deployment. When unset, CNPG uses its default image; deployment mode uses `postgres:18`. |

> **Removed:** `CNPG_CLUSTER_NAME` and `CNPG_CLUSTER_NAMESPACE` environment variables are no longer used. The database location is derived per-gateway from the ManagedDatabase resource referenced by the gateway's `database_id`.

---

## Configuration Examples

### CNPG Mode

ManagedDatabase (created via API, reconciled by ManagedDatabaseReconciler):

```json
{
  "name": "openshell-db",
  "fleet_id": "<fleet-id>",
  "provider": "cnpg"
}
```

The ManagedDatabaseReconciler creates:

```yaml
# Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: openshell-db-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
---
# CNPG Cluster
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: openshell-db
  namespace: openshell-db-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
spec:
  instances: 1
  storage:
    size: 1Gi
  resources:
    requests:
      memory: 256Mi
    limits:
      memory: 512Mi
```

Per-gateway CNPG resources (created by GatewayReconciler in ManagedDatabase namespace):

```yaml
# Password Secret
apiVersion: v1
kind: Secret
metadata:
  name: gw-2j5k7m9pqrstvwxyz-credentials
  namespace: openshell-db-a1b2c3d4e5f67890
  labels:
    cnpg.io/reload: "true"
    hypershell.redhat.io/managed: "true"
    hypershell.redhat.io/gateway-namespace: openshell-a1b2c3d4e5f67890
type: kubernetes.io/basic-auth
stringData:
  username: gw_2j5k7m9pqrstvwxyz
  password: <32-byte-hex-random>
---
# DatabaseRole
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: gw-2j5k7m9pqrstvwxyz
  namespace: openshell-db-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
    hypershell.redhat.io/gateway-namespace: openshell-a1b2c3d4e5f67890
spec:
  cluster:
    name: openshell-db
  name: gw_2j5k7m9pqrstvwxyz
  login: true
  passwordSecret:
    name: gw-2j5k7m9pqrstvwxyz-credentials
  databaseRoleReclaimPolicy: delete
---
# Database
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: gw-2j5k7m9pqrstvwxyz
  namespace: openshell-db-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
    hypershell.redhat.io/gateway-namespace: openshell-a1b2c3d4e5f67890
spec:
  cluster:
    name: openshell-db
  name: gw_2j5k7m9pqrstvwxyz
  owner: gw_2j5k7m9pqrstvwxyz
  databaseReclaimPolicy: delete
---
# Gateway credentials Secret (in tenant namespace)
apiVersion: v1
kind: Secret
metadata:
  name: openshell-gateway-db-credentials
  namespace: openshell-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
type: Opaque
stringData:
  host: openshell-db-rw.openshell-db-a1b2c3d4e5f67890.svc.cluster.local
  port: "5432"
  dbname: gw_2j5k7m9pqrstvwxyz
  user: gw_2j5k7m9pqrstvwxyz
  password: <32-byte-hex-random>
  uri: postgresql://gw_2j5k7m9pqrstvwxyz:<password>@openshell-db-rw.openshell-db-a1b2c3d4e5f67890.svc.cluster.local:5432/gw_2j5k7m9pqrstvwxyz?sslmode=require
```

### Deployment Mode

ManagedDatabase (auto-created by the API server per gateway):

```json
{
  "name": "openshell-db",
  "fleet_id": "<fleet-id>",
  "provider": "deployment"
}
```

The ManagedDatabaseReconciler creates (all in namespace `openshell-db-a1b2c3d4e5f67890`):

```yaml
# Credentials Secret
apiVersion: v1
kind: Secret
metadata:
  name: openshell-db-credentials
  namespace: openshell-db-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
type: Opaque
stringData:
  username: postgres
  password: <32-byte-hex-random>
  database: postgres
  uri: postgresql://postgres:<password>@openshell-gateway-db.openshell-db-a1b2c3d4e5f67890.svc.cluster.local:5432/postgres?sslmode=disable
---
# PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openshell-gateway-db-data
  namespace: openshell-db-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
# Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openshell-gateway-db
  namespace: openshell-db-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
    app: openshell-gateway-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openshell-gateway-db
  template:
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: postgres
          image: postgres:18
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: openshell-db-credentials
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          securityContext:
            capabilities:
              drop: [ALL]
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: openshell-gateway-db-data
---
# Service
apiVersion: v1
kind: Service
metadata:
  name: openshell-gateway-db
  namespace: openshell-db-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
spec:
  selector:
    app: openshell-gateway-db
  ports:
    - port: 5432
      targetPort: 5432
---
# Gateway credentials Secret (copied by GatewayReconciler into tenant namespace)
apiVersion: v1
kind: Secret
metadata:
  name: openshell-gateway-db-credentials
  namespace: openshell-a1b2c3d4e5f67890
  labels:
    hypershell.redhat.io/managed: "true"
type: Opaque
stringData:
  host: openshell-gateway-db.openshell-db-a1b2c3d4e5f67890.svc.cluster.local
  port: "5432"
  dbname: postgres
  user: postgres
  password: <32-byte-hex-random>
  uri: postgresql://postgres:<password>@openshell-gateway-db.openshell-db-a1b2c3d4e5f67890.svc.cluster.local:5432/postgres?sslmode=disable
```

---

## Debugging Reference

| Symptom | Mode | Root Cause | Fix |
|---|---|---|---|
| Database CR `status.applied: false` | cnpg | CNPG operator not running or Cluster not ready | Check CNPG operator pods and Cluster status |
| DatabaseRole stuck in `Terminating` | cnpg | Role owns objects that prevent DROP | Manually drop owned objects or delete database first |
| Gateway pod cannot connect to database | both | Credentials Secret not created or wrong host | Verify `openshell-gateway-db-credentials` in tenant namespace |
| ManagedDatabase namespace not found | both | ManagedDatabaseReconciler has not yet processed the resource | Check ManagedDatabase status and reconciler logs |
| Gateway fails with "CNPG operator required" | cnpg | `DATABASE_PROVIDER=cnpg` but operator not installed | Install CNPG operator or switch to `DATABASE_PROVIDER=deployment` |
| PostgreSQL Deployment not ready | deployment | Image pull failure or PVC not bound | Check Deployment events and PVC status in ManagedDatabase namespace |
| `openshell-db-credentials` Secret missing | deployment | ManagedDatabaseReconciler has not yet completed | Check ManagedDatabase status and reconciler logs |
| Password rotation not applied | cnpg | Missing `cnpg.io/reload: "true"` label on password Secret | Add the label to the Secret |

---

## Resources Removed (vs. Pre-ManagedDatabase Spec)

Before the ManagedDatabase model was introduced, each gateway namespace directly contained a standalone PostgreSQL pod. Those resources were moved to the ManagedDatabase's namespace:

| Resource | Previous Location | Current Location |
|---|---|---|
| PVC (`openshell-gateway-db-data`) | gateway tenant namespace | ManagedDatabase namespace (deployment mode) |
| Deployment (`openshell-gateway-db`) | gateway tenant namespace | ManagedDatabase namespace (deployment mode) |
| Service (`openshell-gateway-db`) | gateway tenant namespace | ManagedDatabase namespace (deployment mode) |

In CNPG mode, the Deployment/PVC/Service do not exist; CNPG manages PostgreSQL pods internally.

The `database.yaml` manifest template (per-gateway PostgreSQL resources applied directly by `deployGateway()`) is removed. In deployment mode, the ManagedDatabaseReconciler creates the equivalent resources in the ManagedDatabase namespace.

The RHEL/upstream PostgreSQL image detection logic (`isRHELPostgres`, `postgresEnvKeys`, `postgresDataPath`, `postgresPGDataPath`) is removed. Both modes use a single configurable image (`OPENSHELL_DATABASE_IMAGE`).

The global `CNPG_CLUSTER_NAME` and `CNPG_CLUSTER_NAMESPACE` environment variables are removed. The database location is resolved per-gateway from the ManagedDatabase resource.

---

## References

- [CloudNativePG Documentation](https://cloudnative-pg.io/docs/)
- [CNPG Database CRD](https://cloudnative-pg.io/docs/devel/declarative_database_management)
- [CNPG DatabaseRole CRD](https://cloudnative-pg.io/docs/devel/declarative_role_management)
