# OpenShell Gateway Console Specification

**Date:** 2026-08-18
**Status:** Draft
**Parent:** `openshell-gateway.spec.md` - core gateway provisioning
**Related:** `openshell-gateway-keycloak.spec.md` - per-gateway Keycloak client + OIDC Role Bridge; `openshell-gateway-oidc.spec.md` - gateway.toml OIDC validation; `openshell-gateway-routing.spec.md` - Gateway API exposure; `openshell-gateway-tls.spec.md` - gateway TLS materials; `security/security.spec.md` - secret handling and isolation
**Upstream:** [OpenShell Dashboard](https://github.com/Gkrumbach07/openshell-dashboard) - Go BFF + React (PatternFly 6) console for a single OpenShell gateway; [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) - reverse proxy that performs the OIDC authorization-code flow

---

## Purpose

When a gateway is exposed externally, the control plane SHALL also co-deploy a
per-gateway **Gateway Console** -- the OpenShell dashboard UI, configured to talk
only to that gateway -- fronted by an authenticating reverse proxy. The console
is a data-plane companion to a single gateway: it lives in the gateway's
API-assigned namespace (`openshell-<id-hex-8>`), reaches the gateway over the
in-cluster Service, and is reachable by browsers under a per-gateway hostname.

Authentication reuses the same Keycloak realm and per-gateway isolation model
already established for the gateway itself. A browser session is authenticated by
an oauth2-proxy sidecar against a dedicated per-gateway Keycloak client; the
resulting access token carries the gateway's audience (`aud = {name}-{id}`) and
the user's per-gateway roles (`hypershell.roles`), so the gateway validates
console traffic with exactly the same rules it already applies to the `openshell`
CLI. Authorization is governed by the existing Gateway OIDC Role Bridge -- a user
sees and operates the console only where they hold a `gateway:owner` or
`gateway:viewer` RoleBinding.

This spec is scoped to **Option 1**: one oauth2-proxy per gateway, using real
IdP-issued tokens with the correct audience, no token exchange, and no shared
console credential across gateways. A future central-console option
(single sign-on across all gateways via token exchange) is out of scope here.

> **Terminology.** "Gateway Console" is the per-gateway OpenShell dashboard
> defined by this spec. It is distinct from the HyperShell **management
> web-console** (`components/web-console/`), which is the fleet-wide control
> plane UI. The two are separate deployments with separate lifecycles.

---

## Architecture

### Deployment topology (per gateway, in the tenant namespace)

```
                       Browser
                          │  HTTPS  https://console-<ns>.<base-domain>
                          ▼
   Shared Gateway (openshift-ingress, wildcard *.<base-domain> cert)
                          │  HTTPRoute (tenant ns) matches console hostname
                          ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ Pod: openshell-console  (tenant namespace openshell-<hash>)    │
   │                                                                │
   │   [oauth2-proxy sidecar]  :4180                                │
   │      · OIDC auth-code + PKCE against Keycloak client           │
   │        {name}-{id}-console (confidential)                      │
   │      · sets X-Forwarded-Access-Token, X-Forwarded-User         │
   │      · upstream → 127.0.0.1:8000                               │
   │                          │ localhost                           │
   │                          ▼                                     │
   │   [openshell-dashboard]  :8000  (Go BFF + React)               │
   │      · trusts X-Forwarded-Access-Token                         │
   │      · relays token to the gateway over gRPC/TLS               │
   └──────────────────────────────────────────────────────────────┘
                          │  grpcs://openshell-gateway.<ns>.svc:8080
                          ▼
              openshell-gateway Service → Pod
              · validates aud = {name}-{id}
              · reads roles from hypershell.roles (admin/user)
```

### Token flow

```
1. Browser hits console-<ns>.<base-domain>; oauth2-proxy has no session.
2. oauth2-proxy → Keycloak authorization-code + PKCE, client_id={name}-{id}-console.
3. User authenticates in the shared `hypershell` realm.
4. Keycloak issues an access token with:
     aud            : {name}-{id}          (audience mapper → the gateway client)
     hypershell.roles: [openshell-admin|openshell-user]  (client-role mapper → gateway client roles)
     sub            : <user>
5. oauth2-proxy stores the session (encrypted cookie) and forwards the request
   to the dashboard BFF with header X-Forwarded-Access-Token: <access token>.
6. Dashboard BFF relays that token to the gateway over gRPC.
7. Gateway validates issuer + aud={name}-{id}, maps hypershell.roles → admin/user,
   and authorizes the call. A user with no per-gateway role is denied by the
   gateway (defense in depth), even though oauth2-proxy authenticated them.
```

The console token is produced by a **second, dedicated** Keycloak client
(`{name}-{id}-console`), not the gateway's CLI client (`{name}-{id}`). The
console client's audience and client-role protocol mappers **target the gateway
client** (`{name}-{id}`), so its tokens are indistinguishable to the gateway from
CLI tokens with respect to `aud` and `hypershell.roles`. This keeps the existing
public CLI client (loopback redirect URIs, PKCE, no secret) untouched while the
console client is confidential with a browser redirect URI.

### Relationship to existing gateway resources

The console is additive. It does not alter the gateway Deployment, Service,
gateway.toml, or the gateway's own Keycloak client. It consumes:

- the gateway's in-cluster Service (`openshell-gateway:8080`) for gRPC traffic;
- the gateway's server CA (`ca.crt` from the `openshell-server-tls` Secret) to
  verify the in-cluster TLS connection;
- the shared realm and per-gateway roles established by
  `openshell-gateway-keycloak.spec.md`.

Because the console is only deployed when `route` is enabled (see enablement
requirement), and a routed gateway has `client_ca_path` stripped from its config
(see `openshell-gateway-routing.spec.md` / `openshell-gateway-tls.spec.md`), the
gateway does not require the console to present a client certificate. The console
still verifies the gateway's server certificate.

---

## Requirements

### Requirement: Console Enablement Tied to Routing

The GatewayReconciler SHALL provision the Gateway Console for a gateway when, and
only when, the gateway has `route` enabled, the cluster supports the Gateway API,
and Keycloak integration is configured. The console is not independently
configurable; it follows the gateway's external-exposure lifecycle.

#### Scenario: Routed gateway gets a console

- GIVEN a Gateway with `route` enabled on a cluster with Gateway API + Keycloak configured
- WHEN the GatewayReconciler reconciles the gateway
- THEN it SHALL provision all console resources (Keycloak console client, console Secret, Deployment with dashboard + oauth2-proxy sidecar, Service, HTTPRoute, NetworkPolicies)
- AND the console SHALL be reachable at `https://console-<tenant-namespace>.<base-domain>`

#### Scenario: Non-routed gateway gets no console

- GIVEN a Gateway with no `route` configuration
- WHEN the GatewayReconciler reconciles the gateway
- THEN it SHALL NOT create any console resources
- AND it SHALL NOT create a console Keycloak client

#### Scenario: Gateway API or Keycloak unavailable

- GIVEN a routed Gateway on a cluster where the Gateway API is not available OR Keycloak is not configured
- WHEN the GatewayReconciler reconciles the gateway
- THEN it SHALL log a warning that the console cannot be provisioned
- AND it SHALL skip console resource creation without failing the gateway reconciliation

---

### Requirement: Per-Gateway Confidential Console Keycloak Client

When provisioning the console, the GatewayReconciler SHALL create a dedicated
confidential OIDC client in the configured Keycloak realm via the Admin REST API.
This client is separate from the gateway's CLI client and exists solely for the
browser-based console session.

#### Client Properties

| Property | Value | Notes |
|---|---|---|
| `clientId` | `{name}-{id}-console` | Unique within the realm; distinct from the gateway client `{name}-{id}` |
| `name` | `{name}-{id}-console` | Display name in Keycloak admin console |
| `publicClient` | `false` | Confidential; oauth2-proxy requires a client secret |
| `standardFlowEnabled` | `true` | Authorization-code flow for the browser |
| `directAccessGrantsEnabled` | `false` | No password grant; browser flow only |
| `serviceAccountsEnabled` | `false` | Not a service account client |
| `fullScopeAllowed` | `false` | **CRITICAL** -- prevents cross-gateway role/audience leakage |
| `redirectUris` | `["https://console-<tenant-namespace>.<base-domain>/oauth2/callback"]` | oauth2-proxy callback |
| `webOrigins` | `["https://console-<tenant-namespace>.<base-domain>"]` | Same-origin |
| `attributes.pkce.code.challenge.method` | `S256` | PKCE enforced even for the confidential client (defense in depth) |
| `defaultClientScopes` | `["openid", "profile", "email", "roles", "gateway-roles", "web-origins", "acr"]` | Includes `gateway-roles` so the client-role mapper runs |

> **`fullScopeAllowed` MUST be `false`.** As with the gateway client, leaving it
> `true` combined with the built-in `oidc-audience-resolve-mapper` would inject
> every gateway's client ID and roles into the console token, breaking per-gateway
> isolation. The console token MUST carry only this gateway's audience and roles.

#### Protocol Mappers (target the gateway client)

The console client SHALL be created with three protocol mappers whose targets are
the **gateway** client (`{name}-{id}`), not the console client:

1. **Audience** -- `oidc-audience-mapper`, `included.client.audience = {name}-{id}`,
   `access.token.claim = true`, `id.token.claim = false`. Sets `aud = {name}-{id}`.
2. **Client roles** -- `oidc-usermodel-client-role-mapper`,
   `claim.name = hypershell.roles`, `multivalued = true`, `jsonType.label = String`,
   `access.token.claim = true`, `usermodel.clientRoleMapping.clientId = {name}-{id}`.
   Emits the user's gateway-client roles into `hypershell.roles`.
3. **Sub** -- `oidc-sub-mapper`, `access.token.claim = true`. Ensures `sub` is present.

Because the client-role mapper reads the user's role mappings for a named client
directly, it emits the gateway's roles into the console token even though the
token is issued by the console client. No additional role assignment is required:
the existing OIDC Role Bridge (`openshell-gateway-keycloak.spec.md`) already
assigns `openshell-admin` / `openshell-user` on the gateway client per RoleBinding.

#### Scenario: Console client provisioned with gateway-targeted mappers

- GIVEN a routed Gateway `my-gateway` (id=`2FhMpQzXBz`) with gateway client `my-gateway-2FhMpQzXBz`
- WHEN the GatewayReconciler provisions the console
- THEN it SHALL create a confidential Keycloak client `my-gateway-2FhMpQzXBz-console`
- AND the client SHALL have `fullScopeAllowed = false` and PKCE `S256`
- AND its audience mapper SHALL set `aud = my-gateway-2FhMpQzXBz`
- AND its client-role mapper SHALL emit `resource_access.my-gateway-2FhMpQzXBz.roles` into `hypershell.roles`

#### Scenario: Console token accepted by the gateway

- GIVEN user-a has `gateway:owner` on `my-gateway` (→ `openshell-admin` on `my-gateway-2FhMpQzXBz`)
- WHEN user-a authenticates through the console's oauth2-proxy
- THEN the access token SHALL contain `aud: "my-gateway-2FhMpQzXBz"` and `hypershell.roles: ["openshell-admin"]`
- AND the gateway SHALL authorize the relayed token with admin access
- AND the token SHALL NOT contain any other gateway's audience or roles

#### Scenario: User without a RoleBinding is denied at the gateway

- GIVEN user-c is a valid realm user with no RoleBinding on `my-gateway`
- WHEN user-c authenticates through the console's oauth2-proxy
- THEN the access token SHALL NOT contain `openshell-admin` or `openshell-user` in `hypershell.roles` for this gateway
- AND the gateway SHALL deny the relayed requests (the gateway runs with `allow_unauthenticated_users = false`)

---

### Requirement: Console Credential Secret

The GatewayReconciler SHALL store the console client secret and the oauth2-proxy
cookie-encryption secret in a single Kubernetes Secret in the tenant namespace,
named `openshell-console-oauth2`.

| Key | Source | Description |
|---|---|---|
| `client-secret` | Keycloak console client (`GET /admin/realms/{realm}/clients/{uuid}/client-secret`) | Confidential client secret used by oauth2-proxy |
| `cookie-secret` | Generated by the control plane (cryptographically random, 32 bytes, base64) | Encrypts the oauth2-proxy session cookie |

The Secret SHALL be created before the console Deployment and reconciled with
update-or-create semantics. The control plane SHALL never log either value.

#### Scenario: Secret materialized from Keycloak + generated cookie secret

- GIVEN the console Keycloak client `my-gateway-2FhMpQzXBz-console` has been provisioned
- WHEN the GatewayReconciler prepares console credentials
- THEN it SHALL read the client secret from Keycloak and generate a random cookie secret
- AND it SHALL store both in the `openshell-console-oauth2` Secret in the tenant namespace
- AND neither value SHALL appear in control-plane logs

#### Scenario: Cookie secret is stable across reconciliations

- GIVEN an `openshell-console-oauth2` Secret already exists with a `cookie-secret`
- WHEN the GatewayReconciler reconciles the gateway again
- THEN it SHALL preserve the existing `cookie-secret` (not regenerate it each cycle)
- AND it SHALL refresh `client-secret` only if the Keycloak client secret has changed
- AND existing browser sessions SHALL NOT be invalidated by an unrelated reconciliation

---

### Requirement: Console Deployment (Dashboard + oauth2-proxy Sidecar)

The GatewayReconciler SHALL deploy a single Deployment named `openshell-console`
in the tenant namespace containing two containers: the OpenShell dashboard and an
oauth2-proxy sidecar. The dashboard listens on loopback; only oauth2-proxy is
exposed by the Service.

All console resources SHALL carry the standard labels used by gateway resources,
with `app.kubernetes.io/component = console` and
`app.kubernetes.io/instance = openshell-console`:

- `app.kubernetes.io/name=openshell`
- `app.kubernetes.io/component=console`
- `app.kubernetes.io/instance=openshell-console`
- `app.kubernetes.io/managed-by=hypershell-control-plane`
- `hypershell.redhat.io/managed=true`

#### Dashboard container

- **Image:** control-plane default (see ImageDefaults), overridable per gateway.
- **Listen address:** loopback only (e.g. `127.0.0.1:8000`).
- **Environment:**
  - `OPENSHELL_GATEWAY_URL = grpcs://openshell-gateway.<tenant-namespace>.svc.cluster.local:8080`
  - `GATEWAY_CA_CERT = /etc/openshell-tls/gateway/ca.crt`
  - `AUTH_DISABLED = false`
  - `AUTH_TOKEN_HEADER = X-Forwarded-Access-Token`
  - `AUTH_USER_HEADER = X-Forwarded-User`
  - `LOGOUT_URL = /oauth2/sign_out`
- **Volume mounts:** `openshell-server-tls` Secret `ca.crt` at `/etc/openshell-tls/gateway` (readOnly), to verify the gateway's in-cluster server certificate.

#### oauth2-proxy sidecar container

- **Image:** control-plane default (see ImageDefaults), overridable.
- **Listen address:** `0.0.0.0:4180` (the Service target).
- **Configuration (via `OAUTH2_PROXY_*` env / args):**
  - `provider = oidc`
  - `oidc-issuer-url = {server-url}/realms/{realm}` (gateway's issuer)
  - `client-id = {name}-{id}-console`
  - `client-secret` from Secret `openshell-console-oauth2` key `client-secret`
  - `cookie-secret` from Secret `openshell-console-oauth2` key `cookie-secret`
  - `code-challenge-method = S256`
  - `redirect-url = https://console-<tenant-namespace>.<base-domain>/oauth2/callback`
  - `upstream = http://127.0.0.1:8000`
  - `http-address = 0.0.0.0:4180`
  - `reverse-proxy = true`
  - `pass-access-token = true` (adds `X-Forwarded-Access-Token` to the upstream request)
  - `pass-user-headers = true` (adds `X-Forwarded-User`, `X-Forwarded-Email`, `X-Forwarded-Preferred-Username`)
  - `skip-provider-button = true`
  - `cookie-secure = true`
  - `email-domain = *` (any authenticated realm user; the gateway enforces per-gateway authorization)
  - `scope = "openid profile email roles gateway-roles"`

#### SecurityContext (both containers)

Per the platform's restricted-SecurityContext convention, both containers SHALL set:
`runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`,
`seccompProfile.type: RuntimeDefault`, and `capabilities.drop: [ALL]`. Because
`readOnlyRootFilesystem` is `true`, each container that needs scratch space SHALL
mount a writable `emptyDir` at `/tmp` (mirroring the gateway Deployment's `tmp`
volume). Resource requests/limits SHALL be modest (e.g. requests `cpu: 50m`,
`memory: 64Mi`; limits `cpu: 250m`, `memory: 256Mi` per container). OpenShift
UID/fsGroup handling SHALL follow the same rules as the gateway Deployment (see
`openshell-gateway.spec.md` § OpenShift-Specific Gateway Provisioning).

#### Health probes

The oauth2-proxy container SHALL expose readiness/liveness probes on its
`/ready` and `/ping` endpoints (port `4180`). The dashboard container SHALL expose
a readiness probe on its HTTP listener so the pod does not receive traffic before
the BFF is serving. Probe cadence SHALL follow the gateway Deployment's pattern.

#### Scenario: Console pod runs dashboard behind oauth2-proxy

- GIVEN a routed Gateway with console provisioning enabled
- WHEN the GatewayReconciler applies the console Deployment
- THEN the pod SHALL contain a dashboard container listening on loopback and an oauth2-proxy sidecar listening on `4180`
- AND oauth2-proxy SHALL be configured with the console client id and the secrets from `openshell-console-oauth2`
- AND both containers SHALL run with the restricted SecurityContext

#### Scenario: Dashboard reaches the gateway over TLS

- GIVEN the console Deployment is running
- WHEN the dashboard establishes its gRPC connection
- THEN it SHALL connect to `grpcs://openshell-gateway.<tenant-namespace>.svc.cluster.local:8080`
- AND it SHALL verify the gateway's server certificate against the mounted `ca.crt`

---

### Requirement: Console Service and HTTP Exposure

The GatewayReconciler SHALL create a `ClusterIP` Service `openshell-console`
targeting the oauth2-proxy port (`4180`), and an `HTTPRoute` that attaches to the
shared Gateway so browsers can reach the console under a per-gateway hostname.

#### Service

- Name: `openshell-console`, `ClusterIP`, port `4180` → target `4180`, selector `app.kubernetes.io/instance: openshell-console`.

#### HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openshell-console
  namespace: <tenant-namespace>
spec:
  parentRefs:
  - name: <GATEWAY_API_GATEWAY_NAME>
    namespace: <GATEWAY_API_GATEWAY_NAMESPACE>
    sectionName: <GATEWAY_API_HTTP_LISTENER_NAME>
  hostnames:
  - console-<tenant-namespace>.<base-domain>
  rules:
  - backendRefs:
    - name: openshell-console
      port: 4180
```

The console hostname `console-<tenant-namespace>.<base-domain>` is a subdomain of
`<base-domain>` and is therefore covered by the shared Gateway's wildcard TLS
certificate, requiring no per-console certificate issuance. The console hostname
is distinct from the gateway's gRPC hostname (`gw-<tenant-namespace>.<base-domain>`)
so the two attach to different Gateway listeners (HTTP for the console, gRPC for
the gateway).

#### Scenario: Console reachable at its hostname

- GIVEN a routed Gateway in namespace `openshell-a1b2c3d4e5f67890` with base domain `apps.cluster.example.com`
- WHEN the GatewayReconciler provisions the console
- THEN it SHALL create an HTTPRoute for hostname `console-openshell-a1b2c3d4e5f67890.apps.cluster.example.com`
- AND the route SHALL forward to the `openshell-console` Service on port `4180`
- AND the hostname SHALL be served by the shared Gateway's wildcard certificate

#### Scenario: HTTP listener missing on the shared Gateway

- GIVEN the shared Gateway has no listener matching `GATEWAY_API_HTTP_LISTENER_NAME`
- WHEN the GatewayReconciler creates the HTTPRoute
- THEN the HTTPRoute SHALL fail to attach and report a not-accepted condition
- AND the reconciler SHALL log a warning identifying the missing listener
- AND it SHALL NOT fail the gateway reconciliation

---

### Requirement: Console NetworkPolicies

The GatewayReconciler SHALL create NetworkPolicies that (a) allow the shared
Gateway proxy to reach the console pod, and (b) allow the console pod to reach the
gateway pod on the gRPC port. Both are required because existing gateway
NetworkPolicies select the gateway pod for ingress, making the namespace
default-deny for any source not explicitly allowed.

1. **`openshell-console-allow-router`** -- selects the console pod
   (`app.kubernetes.io/instance: openshell-console`); allows ingress on TCP `4180`
   from the shared Gateway namespace (`GATEWAY_API_GATEWAY_NAMESPACE`).

2. **`openshell-gateway-allow-console`** -- selects the gateway pod
   (`app.kubernetes.io/instance: openshell-gateway`); allows ingress on TCP `8080`
   from console pods (`app.kubernetes.io/instance: openshell-console`) in the same
   namespace.

#### Scenario: Console-to-gateway traffic permitted

- GIVEN a routed Gateway with the console deployed
- WHEN the dashboard connects to `openshell-gateway:8080`
- THEN the `openshell-gateway-allow-console` NetworkPolicy SHALL permit the connection
- AND without it the gRPC connection would be blocked by the namespace's default-deny posture

#### Scenario: Router-to-console traffic permitted

- GIVEN a routed Gateway with the console deployed
- WHEN the shared Gateway proxy forwards a browser request to the console
- THEN the `openshell-console-allow-router` NetworkPolicy SHALL permit ingress on `4180`

---

### Requirement: Console Lifecycle and Cleanup

The console SHALL be reconciled and torn down together with the gateway's routing
configuration and the gateway resource itself, using update-or-create semantics
throughout.

#### Scenario: Routing removed from an existing gateway

- GIVEN a gateway that previously had `route` and an associated console
- WHEN the `route` field is removed
- THEN the GatewayReconciler SHALL delete all console resources (Deployment, Service, HTTPRoute, NetworkPolicies, `openshell-console-oauth2` Secret)
- AND it SHALL delete the console Keycloak client `{name}-{id}-console`
- AND it SHALL clear the `consoleAddress` field on the Gateway resource

#### Scenario: Gateway deleted

- GIVEN a gateway with a console
- WHEN the GatewayReconciler receives a Gateway DELETED event
- THEN it SHALL delete the console Keycloak client (in addition to the gateway client)
- AND the console's namespaced resources SHALL be removed with the rest of the gateway resources
- AND Keycloak client deletion SHALL cascade the console client's mappers automatically

#### Scenario: Console cleanup failure is non-blocking

- GIVEN the GatewayReconciler is tearing down a console
- WHEN deleting the console Keycloak client fails (e.g. Keycloak unavailable)
- THEN the reconciler SHALL log an error with the orphaned `clientId` for manual cleanup
- AND it SHALL continue removing the remaining console and gateway resources

---

### Requirement: Console Provisioning Atomicity and Idempotency

Console Keycloak provisioning (client, mappers, secret retrieval) SHALL be treated
as an atomic operation within the reconciliation cycle. If any step fails, the
GatewayReconciler SHALL roll back the created console Keycloak client and retry on
the next cycle. Repeated reconciliation SHALL NOT create duplicate resources.

#### Scenario: Mapper creation fails mid-provisioning

- GIVEN the GatewayReconciler has created the console Keycloak client
- WHEN a protocol-mapper creation fails
- THEN the reconciler SHALL delete the created console client (cascading its mappers)
- AND it SHALL log the error and retry on the next reconciliation cycle
- AND the console workload SHALL NOT be deployed until console provisioning succeeds

#### Scenario: Reconcile is idempotent

- GIVEN a gateway whose console is already fully provisioned
- WHEN the GatewayReconciler reconciles again
- THEN it SHALL apply the latest console configuration using update-or-create semantics
- AND it SHALL NOT create a duplicate Keycloak client, Deployment, Service, HTTPRoute, or Secret

---

### Requirement: Console Address Discovery

The GatewayReconciler SHALL PATCH the console URL into a read-only
`consoleAddress` field on the Gateway resource via the API server, so the
HyperShell management web-console and CLI can link users to the per-gateway
console.

- Format: `https://console-<tenant-namespace>.<base-domain>`
- Published during the reconciliation that creates the console resources
- Cleared when the console is torn down
- If the base domain cannot be resolved (e.g. `GATEWAY_API_BASE_DOMAIN` unset), `consoleAddress` SHALL remain empty

#### Scenario: Console address published

- GIVEN a routed Gateway whose console is provisioned in namespace `openshell-a1b2c3d4e5f67890`
- WHEN the GatewayReconciler reconciles
- THEN it SHALL set `consoleAddress = https://console-openshell-a1b2c3d4e5f67890.<base-domain>` on the Gateway resource

---

## Configuration

### Gateway Resource Schema Additions

| Field | Required | Default | Description |
|---|---|---|---|
| `consoleAddress` | - | - | Read-only. External console URL populated by the control plane; empty when no console is deployed |

No user-settable console field is introduced: console provisioning follows the
`route` configuration automatically.

### Control Plane Environment Variables

| Variable | Default | Description |
|---|---|---|
| `GATEWAY_API_HTTP_LISTENER_NAME` | `https` | `sectionName` of the shared Gateway's HTTP-capable listener that console HTTPRoutes attach to |
| `HYPERSHELL_CONSOLE_IMAGE` | *(ImageDefaults default)* | OpenShell dashboard image |
| `HYPERSHELL_OAUTH2_PROXY_IMAGE` | *(ImageDefaults default)* | oauth2-proxy image |

`GATEWAY_API_BASE_DOMAIN` (already defined in `openshell-gateway-routing.spec.md`)
is reused to derive the console hostname.

### ImageDefaults Additions

The `ImageDefaults` interface (`internal/gateway/config.go`) SHALL gain
`DefaultConsoleImage()` and `DefaultOAuth2ProxyImage()`, resolved with the same
override precedence as existing images (env var → per-namespace override →
static default).

---

## Data Model Changes

The Gateway kind SHALL include a read-only `consoleAddress` field:

```
Gateway {
    ...existing fields...
    text consoleAddress "nullable - read-only external console URL populated by control plane"
}
```

Migration:

```sql
ALTER TABLE gateways ADD COLUMN console_address TEXT;
```

The `consoleAddress` field SHALL be read-only -- not settable or updatable via the
REST or gRPC API.

---

## RBAC Requirements

The control-plane ServiceAccount already holds create/update/patch/delete on
`services`, `secrets`, `deployments`, and `networkpolicies` (see
`openshell-gateway.spec.md`). Provisioning the console additionally requires, in
tenant namespaces:

```yaml
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
```

No new Keycloak permissions are required: the existing `hypershell-keycloak-admin`
service account already manages clients, roles, and mappers.

---

## Prerequisites

1. **Shared Gateway HTTP listener.** The admin-provisioned shared Gateway (see
   `openshell-gateway-routing.spec.md`) MUST expose an HTTP-capable listener
   (HTTPS/Terminate, port 443, wildcard `*.<base-domain>` cert) that accepts
   `HTTPRoute` attachments from tenant namespaces. Its `sectionName` MUST match
   `GATEWAY_API_HTTP_LISTENER_NAME`. This is the HTTP analogue of the existing
   `grpc` listener used by gateway GRPCRoutes.

2. **Dashboard image availability.** The OpenShell dashboard image
   ([Gkrumbach07/openshell-dashboard](https://github.com/Gkrumbach07/openshell-dashboard),
   published to `quay.io/gkrumbach07/openshell-dashboard`) MUST be reachable from
   the cluster. The image and its `X-Forwarded-Access-Token` / gateway-URL
   contract are an upstream dependency; a pinned tag SHALL be used.

3. **Keycloak realm.** The same realm prerequisites as
   `openshell-gateway-keycloak.spec.md` apply. No new realm-level objects are
   required (the console client and its mappers are created per gateway).

---

## Security Considerations

- **Per-gateway isolation preserved.** `fullScopeAllowed = false` on the console
  client, with audience/role mappers scoped to a single gateway client, ensures a
  console token is valid only for its own gateway -- no skeleton-key token across
  gateways.
- **Authorization at the gateway.** oauth2-proxy authenticates any realm user;
  effective authorization is enforced by the gateway from `hypershell.roles`.
  Users without a RoleBinding on the gateway can reach the console shell but
  cannot perform gateway operations. Restricting oauth2-proxy to role-holders is a
  possible future hardening but is not required for correctness.
- **Confidential client secret handling.** The console client secret is fetched by
  the control plane from Keycloak and stored only in the tenant-namespace
  `openshell-console-oauth2` Secret; it is never logged and never leaves the
  cluster.
- **Cookie secret.** oauth2-proxy's cookie-encryption secret is generated in-cluster
  and is independent of Keycloak; it is preserved across reconciliations to avoid
  invalidating active sessions.
- **TLS everywhere.** Browser→shared Gateway is HTTPS (wildcard cert);
  console→gateway is gRPC/TLS with server-certificate verification.

---

## Out of Scope

- **Central single-console SSO across all gateways** (one login, per-request token
  exchange to `aud={name}-{id}`). That is the alternative "global proxy" option and
  is deliberately excluded here.
- **Embedding the dashboard inside the HyperShell management web-console.** This
  spec deploys a standalone per-gateway console; deep integration into
  `components/web-console/` is separate work.
- **Changes to the OpenShell dashboard image itself.** The dashboard is consumed
  as a published upstream artifact via its documented runtime configuration.

---

## References

- [OpenShell Dashboard](https://github.com/Gkrumbach07/openshell-dashboard) -- Go BFF + React console; runtime `OPENSHELL_GATEWAY_URL` and `X-Forwarded-Access-Token` relay contract
- [oauth2-proxy documentation](https://oauth2-proxy.github.io/oauth2-proxy/) -- OIDC provider, PKCE (`code-challenge-method=S256`), `pass-access-token`, `reverse-proxy`
- [oauth2-proxy #1714](https://github.com/oauth2-proxy/oauth2-proxy/issues/1714) / [#2929](https://github.com/oauth2-proxy/oauth2-proxy/issues/2929) -- client-secret is required even with PKCE (rationale for a confidential console client)
- [Gateway API HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/) -- HTTP routing attachment to a shared Gateway
- [Keycloak Admin REST API](https://www.keycloak.org/docs-api/latest/rest-api/) -- client, mapper, and client-secret endpoints
- [Keycloak Protocol Mappers](https://www.keycloak.org/docs/latest/server_admin/#_protocol-mappers) -- audience and client-role mappers targeting another client
- `openshell-gateway-keycloak.spec.md` -- per-gateway client, roles, and OIDC Role Bridge reused by the console
- `openshell-gateway-routing.spec.md` -- shared Gateway, base-domain hostname derivation, NetworkPolicy pattern
