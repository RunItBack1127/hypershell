# OpenShell Gateway TLS and Certificate Management

**Date:** 2026-08-06
**Status:** Active

## Overview

The OpenShell gateway serves gRPC over TLS. Certificate management is handled by cert-manager when available, with a fallback certgen Job for JWT key generation. This spec defines the certificate chain, cert-manager resources, JWT key generation, SAN management, and TLS modes.

## Certificate Strategy

The reconciler uses two complementary mechanisms:

1. **cert-manager** (preferred) — Manages TLS certificate lifecycle (issuance, renewal, rotation) via Kubernetes-native Certificate resources. Detected at startup.
2. **certgen Job** — A one-shot Job using the gateway image's `generate-certs` command. Always runs for JWT key generation. Falls back to full certificate generation when cert-manager is unavailable.

### cert-manager Detection

At control plane startup (not per-reconciliation), the reconciler SHALL use API discovery to check for the `cert-manager.io` API group. The result SHALL be stored as `hasCertManager bool` on the reconciler struct. This avoids per-reconciliation discovery overhead since cert-manager presence is stable.

## cert-manager Resources

When cert-manager is available, the reconciler SHALL create five cert-manager resources per gateway, all as inline unstructured objects (not YAML templates):

### 1. Self-Signed Bootstrap Issuer

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: openshell-selfsigned
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/managed-by: hypershell
spec:
  selfSigned: {}
```

### 2. CA Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openshell-ca
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/managed-by: hypershell
spec:
  isCA: true
  commonName: openshell-ca
  secretName: openshell-ca-tls
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: openshell-selfsigned
    kind: Issuer
```

### 3. CA-Backed Issuer

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: openshell-ca-issuer
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/managed-by: hypershell
spec:
  ca:
    secretName: openshell-ca-tls
```

### 4. Server Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openshell-server
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/managed-by: hypershell
spec:
  secretName: openshell-server-tls
  commonName: openshell-gateway
  dnsNames: <Gateway.server_dns_names>
  privateKey:
    rotationPolicy: Always
  issuerRef:
    name: openshell-ca-issuer
    kind: Issuer
```

The `dnsNames` SHALL include at minimum:
- `openshell-gateway.<namespace>.svc.cluster.local`
- Any additional names from `Gateway.server_dns_names` (e.g. external hostnames)

The `openshell-server-tls` Secret SHALL contain `ca.crt`, `tls.crt`, and `tls.key`.

### 5. Client Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openshell-client
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/managed-by: hypershell
spec:
  secretName: openshell-client-tls
  commonName: openshell-client
  privateKey:
    rotationPolicy: Always
  issuerRef:
    name: openshell-ca-issuer
    kind: Issuer
```

The client certificate is used for mTLS between sandboxes/supervisors and the gateway.

## JWT Key Generation Job

The reconciler SHALL always create a certgen Job for JWT key generation, regardless of cert-manager availability:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: openshell-gateway-certgen
  namespace: <Gateway.namespace>
  labels:
    app.kubernetes.io/managed-by: hypershell
spec:
  template:
    spec:
      serviceAccountName: openshell-gateway-certgen
      restartPolicy: OnFailure
      containers:
      - name: certgen
        image: <GatewayRelease.image>
        args:
        - generate-certs
        - --jwt-only
        - --jwt-secret-name=openshell-gateway-jwt-keys
```

The Job creates the `openshell-gateway-jwt-keys` Secret containing:
- `signing.pem` — JWT signing private key
- `public.pem` — JWT verification public key
- `kid` — Key ID

The Job requires a dedicated ServiceAccount (`openshell-gateway-certgen`) with a Role granting `secrets/get,create` in the namespace.

When cert-manager is NOT available, the `--jwt-only` flag SHALL be omitted, and the Job SHALL generate both TLS certificates and JWT keys. The Job SHALL also receive `--server-san` arguments for each entry in `Gateway.server_dns_names`.

## SAN Management and Certificate Rotation

When `Gateway.server_dns_names` changes, the reconciler SHALL:

1. Compare the new DNS names against the `server_sans` key in the `openshell-gateway-config` ConfigMap.
2. When they differ:
   - Delete TLS secrets: `openshell-server-tls`, `openshell-client-tls`, `openshell-gateway-jwt-keys`.
   - Delete any completed certgen Job.
   - Re-create the certgen Job with updated `--server-san` arguments.
   - Update the ConfigMap with the new `server_sans` value.
   - When cert-manager is available, update the server Certificate's `dnsNames` field. cert-manager will re-issue the certificate automatically.

This operation is destructive — connected sandbox supervisors will experience TLS errors until the new certificates are propagated.

## Volume Mounts

The gateway Deployment mounts TLS and JWT materials at these paths:

| Mount Path | Source | Contents |
|-----------|--------|----------|
| `/etc/openshell-tls/server` | Secret `openshell-server-tls` | `tls.crt`, `tls.key`, `ca.crt` |
| `/etc/openshell-tls/client-ca` | Secret `openshell-server-tls` (projected, `ca.crt` only) | `ca.crt` |
| `/etc/openshell-jwt` | Secret `openshell-gateway-jwt-keys` (mode 0440) | `signing.pem`, `public.pem`, `kid` |

## Gateway Configuration

The `gateway.toml` TLS section references these mount paths:

```toml
[openshell.gateway.tls]
cert_path      = "/etc/openshell-tls/server/tls.crt"
key_path       = "/etc/openshell-tls/server/tls.key"
client_ca_path = "/etc/openshell-tls/client-ca/ca.crt"

[openshell.gateway.gateway_jwt]
signing_key_path = "/etc/openshell-jwt/signing.pem"
public_key_path  = "/etc/openshell-jwt/public.pem"
kid_path         = "/etc/openshell-jwt/kid"
gateway_id       = "openshell-gateway"
ttl_secs         = 3600
```

The `client_ca_path` SHALL always be set regardless of OIDC state. When OIDC is enabled alongside client CA, the gateway operates in optional mTLS mode: sandbox supervisors authenticate via client certificates, CLI users authenticate via OIDC Bearer tokens.

## TLS Modes

The gateway supports four authentication modes depending on configuration:

| `client_ca_path` | OIDC | Mode |
|-----------------|------|------|
| set | disabled | Full mTLS — all clients must present certificates |
| set | enabled | Optional mTLS — certificates validated when present, OIDC for others |
| unset | enabled | HTTPS + OIDC only |
| unset | disabled | HTTPS only (`allow_unauthenticated_users = true`) |

The reconciler SHALL always set `client_ca_path` in the generated configuration. The effective authentication mode is determined by whether OIDC is configured (see [OIDC spec](openshell-gateway-oidc.spec.md)).

## RBAC Requirements

The control plane ServiceAccount SHALL have the following RBAC for cert-manager operations:

```yaml
- apiGroups: ["cert-manager.io"]
  resources: ["issuers", "certificates"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
```

## Requirements

### Requirement: cert-manager Certificate Chain

When cert-manager is available, the reconciler SHALL create a self-signed CA chain with server and client leaf certificates.

#### Scenario: cert-manager Available
- GIVEN cert-manager is installed on the target cluster
- WHEN the GatewayReconciler provisions a gateway
- THEN it SHALL create the self-signed Issuer, CA Certificate, CA Issuer, server Certificate, and client Certificate
- AND the server certificate SHALL include all DNS names from `Gateway.server_dns_names`
- AND cert-manager SHALL manage certificate renewal automatically

#### Scenario: cert-manager Not Available
- GIVEN cert-manager is NOT installed on the target cluster
- WHEN the GatewayReconciler provisions a gateway
- THEN it SHALL create a certgen Job that generates both TLS certificates and JWT keys
- AND the Job SHALL use the gateway image's `generate-certs` command with `--server-san` arguments

### Requirement: JWT Key Generation

The reconciler SHALL always create a certgen Job for JWT key generation.

#### Scenario: JWT Keys Created
- GIVEN a new Gateway is being provisioned
- WHEN the reconciler creates the certgen Job
- THEN the Job SHALL create the `openshell-gateway-jwt-keys` Secret
- AND the Secret SHALL contain `signing.pem`, `public.pem`, and `kid`

### Requirement: Certificate Rotation on SAN Change

When server DNS names change, certificates SHALL be re-issued.

#### Scenario: DNS Name Added
- GIVEN a running Gateway with `server_dns_names: ["gw.example.com"]`
- WHEN `server_dns_names` is updated to `["gw.example.com", "gw2.example.com"]`
- THEN existing TLS secrets SHALL be deleted
- AND new certificates SHALL be issued with the updated DNS names
- AND the gateway Deployment SHALL be restarted to pick up new certificates

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| cert-manager preferred, certgen Job as fallback | cert-manager provides automated renewal; certgen Job is a manual fallback for clusters without cert-manager |
| Self-signed CA per gateway namespace | Each gateway gets its own CA for isolation; no shared CA across namespaces |
| ECDSA P-256 for CA | Strong security with smaller key size; widely supported |
| `rotationPolicy: Always` on leaf certs | Generates new private keys on each renewal for forward secrecy |
| JWT keys via separate Job, not cert-manager | JWT keys are not X.509 certificates; cert-manager cannot generate them |
| `client_ca_path` always set | Simplifies mode switching between mTLS and OIDC; gateway handles the logic internally |
