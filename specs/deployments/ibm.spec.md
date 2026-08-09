# IBM Cloud Deployment Specification

Provisioning steps for the HyperShell OpenShift cluster on IBM Cloud (ROKS).

## Account

| Field | Value |
|-------|-------|
| Account | OSaaS Dev team |
| Account ID | `dca8e7b41db847da9e58bf43e92a7ccf` |
| Region | `us-east` |
| Resource Group | `Default` (`9dc7acd23132409c96712f2afa119fbe`) |
| User | `mturansk@redhat.com` |

## Prerequisites

```bash
ibmcloud plugin install container-service
ibmcloud plugin install vpc-infrastructure
```

Installed versions:
- `container-service` 1.0.815
- `vpc-infrastructure` 16.13.0

## Step 1: Login and Target

```bash
ibmcloud login --sso -a https://cloud.ibm.com
ibmcloud target -c dca8e7b41db847da9e58bf43e92a7ccf -g Default
```

## Step 2: Create VPC

```bash
ibmcloud is vpc-create hypershell-vpc --resource-group-name Default
```

| Field | Value |
|-------|-------|
| VPC ID | `r014-be56e5de-5cd9-493f-8ac2-149791cdc58b` |
| Name | `hypershell-vpc` |
| Region | `us-east` |

Address prefixes (auto-created):

| Zone | CIDR |
|------|------|
| us-east-1 | `10.241.0.0/18` |
| us-east-2 | `10.241.64.0/18` |
| us-east-3 | `10.241.128.0/18` |

## Step 3: Create Subnet

```bash
ibmcloud is subnet-create hypershell-subnet-1 hypershell-vpc \
  --zone us-east-1 \
  --ipv4-cidr-block 10.241.0.0/24 \
  --resource-group-name Default
```

| Field | Value |
|-------|-------|
| Subnet ID | `0757-cacfbdee-1d22-444c-8ce5-5eff35c43faf` |
| Name | `hypershell-subnet-1` |
| Zone | `us-east-1` |
| CIDR | `10.241.0.0/24` |

## Step 4: Create Cloud Object Storage

OpenShift on IBM Cloud requires a COS instance for the internal container registry.

```bash
ibmcloud resource service-instance-create hypershell-cos \
  cloud-object-storage standard global -g Default
```

When prompted for deployment type, select `1` (premium-global-deployment).

| Field | Value |
|-------|-------|
| Name | `hypershell-cos` |
| CRN | `crn:v1:bluemix:public:cloud-object-storage:global:a/dca8e7b41db847da9e58bf43e92a7ccf:e674d660-110e-49a2-94d5-6a8e7ef5fcd1::` |
| GUID | `e674d660-110e-49a2-94d5-6a8e7ef5fcd1` |

## Step 5: Create OpenShift Cluster

```bash
ibmcloud oc cluster create vpc-gen2 \
  --name hypershell-cluster \
  --zone us-east-1 \
  --vpc-id r014-be56e5de-5cd9-493f-8ac2-149791cdc58b \
  --subnet-id 0757-cacfbdee-1d22-444c-8ce5-5eff35c43faf \
  --flavor bx2.4x16 \
  --workers 2 \
  --version 4.17_openshift \
  --cos-instance "crn:v1:bluemix:public:cloud-object-storage:global:a/dca8e7b41db847da9e58bf43e92a7ccf:e674d660-110e-49a2-94d5-6a8e7ef5fcd1::"
```

| Field | Value |
|-------|-------|
| Cluster ID | `d9rnlrqw0qpuae8r1tkg` |
| Name | `hypershell-cluster` |
| OpenShift Version | `4.17.56_1595_openshift` |
| Flavor | `bx2.4x16` (4 vCPU, 16 GB) |
| Workers | 2 |
| Zone | `us-east-1` |
| Network Plugin | Calico |
| Pod Subnet | `172.17.0.0/18` |
| Service Subnet | `172.21.0.0/16` |

## Step 6: Monitor Deployment

```bash
ibmcloud oc cluster get --cluster hypershell-cluster
ibmcloud oc worker ls --cluster hypershell-cluster
```

Cluster provisioning typically takes 20-40 minutes.

## Step 7: Connect to Cluster

Once the cluster state is `normal`:

```bash
ibmcloud oc cluster config --cluster hypershell-cluster --admin
oc get nodes
oc get clusterversion
```

## Post-Provisioning: Fix COS Registry Bucket

If the COS bucket was not auto-created (warning Ece8a), manually configure it:

```bash
ibmcloud oc cluster master refresh --cluster hypershell-cluster
```

See: http://ibm.biz/roks_cos_ts

## Resource Summary

| Resource | Name | ID |
|----------|------|----|
| VPC | `hypershell-vpc` | `r014-be56e5de-5cd9-493f-8ac2-149791cdc58b` |
| Subnet | `hypershell-subnet-1` | `0757-cacfbdee-1d22-444c-8ce5-5eff35c43faf` |
| COS | `hypershell-cos` | `e674d660-110e-49a2-94d5-6a8e7ef5fcd1` |
| Cluster | `hypershell-cluster` | `d9rnlrqw0qpuae8r1tkg` |

## HyperShell Deployment

### IBM Cloud Restricted Registry

IBM Cloud ROKS worker nodes cannot pull images from external registries (ghcr.io, registry.k8s.io, docker.io). All images must be mirrored to the OpenShift internal registry.

```bash
# Expose the internal registry
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"defaultRoute":true}}'
REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')

# Login (tokens expire; re-run before each push session)
TOKEN=$(oc create token builder -n hypershell)
podman login "$REGISTRY" -u unused -p "$TOKEN" --tls-verify=false

# Mirror required images
for img in \
  "ghcr.io/nvidia/openshell/gateway:0.0.101 -> openshell-gateway:0.0.101" \
  "ghcr.io/nvidia/openshell/supervisor:0.0.101 -> openshell-supervisor:0.0.101" \
  "ghcr.io/nvidia/openshell-community/sandboxes/base:latest -> openshell-sandbox-base:latest" \
  "postgres:16 -> postgres:16" \
  "quay.io/keycloak/keycloak:26.2.5 -> keycloak:26.2.5" \
  "registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.1 -> agent-sandbox-controller:v0.5.1"; do
  SRC="${img%% ->*}"
  DST="${img##*-> }"
  podman pull "$SRC"
  podman tag "$SRC" "$REGISTRY/hypershell/$DST"
  podman push "$REGISTRY/hypershell/$DST" --tls-verify=false
done
```

Cross-namespace image pull access:

```bash
# Grant pull access to gateway and sandbox SAs
oc policy add-role-to-user system:image-puller system:serviceaccount:openshell-e2e:openshell-gateway -n hypershell
oc policy add-role-to-user system:image-puller system:serviceaccount:openshell-e2e:openshell-gateway-sandbox -n hypershell
oc policy add-role-to-user system:image-puller system:serviceaccount:agent-sandbox-system:agent-sandbox-controller -n hypershell
```

### Agent Sandbox Controller

The `agents.x-k8s.io/Sandbox` CRD must be installed before sandboxes can be created:

```bash
oc apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.1/manifest.yaml"
# Then patch the controller image to use internal registry
oc set image deployment/agent-sandbox-controller -n agent-sandbox-system \
  agent-sandbox-controller=image-registry.openshift-image-registry.svc:5000/hypershell/agent-sandbox-controller:v0.5.1
```

### Controller Environment Variables

The controller needs env vars pointing to internal registry images:

```bash
oc set env deployment/hypershell-controller -n hypershell \
  HYPERSHELL_DEFAULT_GATEWAY_IMAGE=image-registry.openshift-image-registry.svc:5000/hypershell/openshell-gateway:0.0.101 \
  HYPERSHELL_DEFAULT_SUPERVISOR_IMAGE=image-registry.openshift-image-registry.svc:5000/hypershell/openshell-supervisor:0.0.101 \
  HYPERSHELL_DEFAULT_SANDBOX_IMAGE=image-registry.openshift-image-registry.svc:5000/hypershell/openshell-sandbox-base:latest
```

### Keycloak OIDC

Keycloak is deployed in the `hypershell` namespace with realm `hypershell` and client `openshell-cli`.

Key configuration for dual-access (external HTTPS route + internal HTTP service):

| Env Var | Value | Purpose |
|---------|-------|---------|
| `KC_HOSTNAME` | `http://keycloak-service.hypershell.svc.cluster.local:8080` | Token `iss` claim uses internal URL |
| `KC_HOSTNAME_STRICT` | `false` | Allow access from any hostname |
| `KC_PROXY_HEADERS` | `xforwarded` | Trust proxy headers from OpenShift router |

This ensures tokens obtained via the external Keycloak route have the internal service URL as issuer, matching what the gateway expects.

### Gateway OIDC Configuration

Gateway OIDC is configured via the HyperShell API when creating a gateway:

```json
{
  "oidc": "{\"issuer\":\"http://keycloak-service.hypershell.svc.cluster.local:8080/realms/hypershell\",\"audience\":\"openshell-cli\",\"roles_claim\":\"realm_access.roles\",\"admin_role\":\"openshell-admin\",\"user_role\":\"openshell-user\"}"
}
```

### Supervisor Sideload Method

K8s `image` volume source requires 1.31+. IBM Cloud ROKS 4.17 runs K8s 1.30, so use `init-container` method:

```toml
supervisor_sideload_method = "init-container"
```

### OpenShift Route + NetworkPolicy

The controller deploys a passthrough Route and router NetworkPolicy for OpenShift clusters:

- `route.yaml`: passthrough TLS termination to `openshell-gateway` service port `grpc`
- `networkpolicy-router.yaml`: allows ingress from `openshift-ingress` namespace to gateway pods on ports 8080/8081

### E2E Test

```bash
SKIP_CLEANUP=1 \
HYPERSHELL_NAMESPACE=hypershell \
GATEWAY_NAMESPACE=openshell-e2e \
GATEWAY_NAME=openshell-gateway \
PAUSE=0 \
SANDBOX_TIMEOUT=240 \
PROVISION_TIMEOUT=300 \
bash components/pr-test/e2e-openshell.sh
```

### Lessons Learned

1. **Registry token expiry**: `oc create token builder` tokens expire after ~1hr. Re-login before each push session.
2. **Certgen partial PKI**: If certgen fails mid-run, delete all three secrets (`openshell-server-tls`, `openshell-client-tls`, `openshell-gateway-jwt-keys`) before retrying.
3. **Controller restart loses namespace mapping**: After controller restart, deleted gateways can't be cleaned up (namespace unknown). Manual cleanup required.
4. **Sandbox image pull**: Both gateway SA and sandbox SA need `system:image-puller` role on the image source namespace.
5. **Keycloak issuer mismatch**: Gateway OIDC issuer must exactly match the `iss` claim in tokens. Set `KC_HOSTNAME` to the internal URL the gateway uses.

## Teardown

```bash
ibmcloud oc cluster rm --cluster hypershell-cluster -f --force-delete-storage
ibmcloud resource service-instance-delete hypershell-cos -f
ibmcloud is subnet-delete hypershell-subnet-1 -f
ibmcloud is vpc-delete hypershell-vpc -f
```
