# OpenShell Gateway Database Provisioning

**Date:** 2026-08-06
**Status:** Active

## Overview

When a Gateway resource has inline `database` configuration (as opposed to referencing an external ManagedDatabase via `database_id`), the GatewayReconciler provisions an in-cluster PostgreSQL instance alongside the gateway. This spec defines the database resources, credential management, provisioning order, and lifecycle semantics.

The in-cluster database option is used in local development and single-cluster deployments. For managed cloud databases (e.g. Amazon RDS), the Gateway references a ManagedDatabase resource via `database_id` instead.

## Database Configuration

The Gateway resource's `database` field is a JSONB object with the following structure:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `image` | string | `registry.access.redhat.com/hi/postgresql:18` | PostgreSQL container image |
| `storage_size` | string | `5Gi` | PVC size for database storage |

When `database` is set and `database_id` is null, the reconciler provisions in-cluster PostgreSQL resources. When `database_id` is set, the reconciler skips in-cluster provisioning and the gateway connects to the ManagedDatabase's endpoint. Setting both is a validation error.

## Kubernetes Resources

The reconciler SHALL create the following resources in this order, all in the Gateway's target namespace. Database resources are applied BEFORE the gateway workload so the database is ready when the gateway starts.

### Credentials Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: openshell-gateway-db
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway-database
    app.kubernetes.io/managed-by: hypershell
type: Opaque
stringData:
  POSTGRESQL_USER: openshell
  POSTGRESQL_PASSWORD: <generated>
  POSTGRESQL_DATABASE: openshell
  url: "postgresql://openshell:<password>@openshell-gateway-db.<namespace>.svc.cluster.local:5432/openshell?sslmode=disable"
```

The password SHALL be a 32-byte cryptographically random hex string generated via `crypto/rand`. The Secret SHALL be created with create-if-not-exists semantics (NOT update-or-create) to avoid password churn on re-reconciliation. If the Secret already exists, the reconciler SHALL read the existing password and use it for the connection URL.

Passwords SHALL NOT appear in log output. Debug logging SHALL log `len(password)` only.

The `sslmode=disable` is intentional: in-cluster, same-namespace traffic is isolated by NetworkPolicy. TLS between the gateway pod and the database pod adds overhead without meaningful security benefit in this topology.

### PersistentVolumeClaim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openshell-gateway-db-data
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway-database
    app.kubernetes.io/managed-by: hypershell
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: <database.storage_size, default 5Gi>
```

### Database Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openshell-gateway-db
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway-database
    app.kubernetes.io/instance: openshell-gateway-db
    app.kubernetes.io/managed-by: hypershell
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: openshell
      app.kubernetes.io/component: gateway-database
      app.kubernetes.io/instance: openshell-gateway-db
  template:
    spec:
      containers:
      - name: postgresql
        image: <database.image>
        ports:
        - containerPort: 5432
        envFrom:
        - secretRef:
            name: openshell-gateway-db
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "openshell"]
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "openshell"]
          initialDelaySeconds: 15
          periodSeconds: 10
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
        - name: data
          mountPath: /var/lib/pgsql/data
        - name: run
          mountPath: /var/run/postgresql
        - name: tmp
          mountPath: /tmp
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: openshell-gateway-db-data
      - name: run
        emptyDir: {}
      - name: tmp
        emptyDir: {}
```

The strategy SHALL be `Recreate` (not `RollingUpdate`) because the PVC is `ReadWriteOnce` and cannot be mounted by two pods simultaneously.

The `emptyDir` volumes for `/var/run/postgresql` and `/tmp` are required because `readOnlyRootFilesystem: true` prevents writing to the container filesystem. PostgreSQL needs these paths for its Unix socket and temporary files.

#### Image Environment Variable Detection

The reconciler SHALL detect whether the database image is a Red Hat image or a Docker Hub image based on the image path. Red Hat images (`registry.access.redhat.com`, `registry.redhat.io`) use `POSTGRESQL_*` environment variable names. Docker Hub images (`docker.io`, `postgres:*`) use `POSTGRES_*` names. The Secret keys SHALL match the detected convention:

| Image Source | User Env Var | Password Env Var | Database Env Var |
|-------------|-------------|-----------------|-----------------|
| Red Hat (`registry.access.redhat.com/hi/postgresql`, `registry.redhat.io/rhel*/postgresql-*`) | `POSTGRESQL_USER` | `POSTGRESQL_PASSWORD` | `POSTGRESQL_DATABASE` |
| Docker Hub (`docker.io/library/postgres`, `postgres:*`) | `POSTGRES_USER` | `POSTGRES_PASSWORD` | `POSTGRES_DB` |

### Database Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: openshell-gateway-db
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway-database
    app.kubernetes.io/instance: openshell-gateway-db
    app.kubernetes.io/managed-by: hypershell
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: openshell
    app.kubernetes.io/component: gateway-database
    app.kubernetes.io/instance: openshell-gateway-db
  ports:
  - port: 5432
    targetPort: 5432
```

### Database NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: openshell-gateway-db
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/managed-by: hypershell
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: gateway-database
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/component: gateway
    ports:
    - port: 5432
      protocol: TCP
```

Only gateway pods can reach the database on port 5432.

## Gateway Integration

### Database URL Injection

The gateway Deployment receives the database connection string via the `OPENSHELL_DB_URL` environment variable, sourced from the `openshell-gateway-db` Secret's `url` key:

```yaml
env:
- name: OPENSHELL_DB_URL
  valueFrom:
    secretKeyRef:
      name: openshell-gateway-db
      key: url
```

When the Gateway uses an external ManagedDatabase (via `database_id`), the reconciler SHALL use the ManagedDatabase's `connection_secret` reference instead.

### Init Container

The gateway Deployment includes a `wait-for-db` init container that loops `pg_isready` until PostgreSQL is accepting connections. This ensures the gateway does not start before its database is ready:

```yaml
initContainers:
- name: wait-for-db
  image: <database.image>
  command: ["sh", "-c"]
  args: ["until pg_isready -h openshell-gateway-db -U openshell; do sleep 2; done"]
```

## Requirements

### Requirement: In-Cluster Database Provisioning

When a Gateway has inline `database` configuration, the reconciler SHALL provision a PostgreSQL instance in the same namespace.

#### Scenario: Provision Database
- GIVEN a Gateway with `database: {image: "registry.access.redhat.com/hi/postgresql:18"}`
- AND `database_id` is null
- WHEN the GatewayReconciler processes the ADDED event
- THEN it SHALL create the credentials Secret, PVC, Deployment, Service, and NetworkPolicy
- AND the database SHALL be accepting connections before the gateway Deployment starts

#### Scenario: Skip Database When Using ManagedDatabase
- GIVEN a Gateway with `database_id` referencing a ManagedDatabase
- AND no inline `database` config
- WHEN the GatewayReconciler processes the ADDED event
- THEN it SHALL NOT create in-cluster database resources
- AND the gateway SHALL connect to the ManagedDatabase endpoint

#### Scenario: Reject Conflicting Database Config
- GIVEN a Gateway with both `database_id` set and inline `database` config
- WHEN the API server validates the request
- THEN it SHALL reject the request with a validation error

### Requirement: Credential Persistence

Database credentials SHALL survive re-reconciliation without change.

#### Scenario: Re-Reconcile Preserves Password
- GIVEN a Gateway with a running in-cluster database
- WHEN the reconciler re-processes the Gateway
- THEN the existing credentials Secret SHALL NOT be overwritten
- AND the database password SHALL remain unchanged

### Requirement: Database Cleanup on Gateway Deletion

When a Gateway with in-cluster database is deleted, all database resources SHALL be removed.

#### Scenario: Database Resource Cleanup
- GIVEN a running Gateway with in-cluster database
- WHEN the Gateway is deleted
- THEN the reconciler SHALL delete the database Deployment, Service, Secret, PVC, and NetworkPolicy
- AND the PVC deletion SHALL release the persistent volume

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Create-if-not-exists for credentials Secret | Avoids password churn on re-reconciliation; preserves existing database connections |
| `Recreate` deployment strategy | `ReadWriteOnce` PVC cannot be mounted by multiple pods; rolling update would deadlock |
| `sslmode=disable` for in-cluster connection | NetworkPolicy isolation makes same-namespace TLS unnecessary overhead |
| Separate `emptyDir` for `/var/run/postgresql` and `/tmp` | Required by `readOnlyRootFilesystem: true`; PostgreSQL needs writable socket and temp paths |
| Image-based env var detection | Red Hat and Docker Hub PostgreSQL images use different env var conventions; auto-detection avoids misconfiguration |
