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

## Teardown

```bash
ibmcloud oc cluster rm --cluster hypershell-cluster -f --force-delete-storage
ibmcloud resource service-instance-delete hypershell-cos -f
ibmcloud is subnet-delete hypershell-subnet-1 -f
ibmcloud is vpc-delete hypershell-vpc -f
```
