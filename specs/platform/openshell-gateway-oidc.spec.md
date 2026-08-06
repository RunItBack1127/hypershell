# OpenShell Gateway OIDC Authentication

**Date:** 2026-08-06
**Status:** Active

## Overview

The OpenShell gateway supports OIDC-based authentication for CLI users. When a Gateway resource has OIDC configuration, the GatewayReconciler injects the OIDC settings into the gateway's `gateway.toml` configuration. This spec defines the OIDC API fields, configuration injection, role validation, and interaction with TLS authentication modes.

## Gateway OIDC Fields

The Gateway resource's `oidc` field is a JSONB object with the following structure:

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `issuer` | string | yes (to enable) | — | OIDC issuer URL (e.g. `https://keycloak.example.com/realms/hypershell`). Empty string disables OIDC. |
| `audience` | string | no | `"openshell-cli"` | Expected `aud` claim in JWT access tokens |
| `jwks_ttl` | integer | no | `3600` | JWKS cache retention in seconds |
| `roles_claim` | string | no | — | Dot-delimited path to roles array in JWT claims (e.g. `realm_access.roles` or `groups`) |
| `admin_role` | string | no | — | Role name granting administrator access |
| `user_role` | string | no | — | Role name granting standard user access |
| `scopes_claim` | string | no | — | Dot-delimited path to scopes array in JWT claims |

### Validation Rules

- `admin_role` and `user_role` SHALL both be set or both be empty. Setting only one is a validation error (upstream OpenShell constraint).
- When `roles_claim` is set, `admin_role` and `user_role` SHOULD also be set to enable role-based access control.
- `issuer` SHALL be a valid URL. The gateway validates the issuer by fetching `<issuer>/.well-known/openid-configuration` at startup.

## Configuration Injection

When OIDC is enabled (non-empty `oidc.issuer`) and the Gateway does not have a custom `config` field, the reconciler SHALL inject the OIDC section into the generated `gateway.toml`:

```toml
[openshell.gateway.auth]
allow_unauthenticated_users = false

[openshell.gateway.oidc]
issuer      = "<oidc.issuer>"
audience    = "<oidc.audience>"
roles_claim = "<oidc.roles_claim>"
admin_role  = "<oidc.admin_role>"
user_role   = "<oidc.user_role>"
```

Only non-empty, non-zero fields SHALL be written to the TOML. The upstream gateway applies its own defaults for omitted fields.

When OIDC is disabled (empty or absent `oidc.issuer`), the reconciler SHALL set:

```toml
[openshell.gateway.auth]
allow_unauthenticated_users = true
```

When a custom `config` field is present on the Gateway resource, the reconciler SHALL use it verbatim as `gateway.toml` content without injecting OIDC or any other computed sections. The user is responsible for including OIDC configuration in the custom config.

## OIDC Change Detection

Changes to OIDC configuration SHALL trigger:

1. **ConfigMap update** — The `openshell-gateway-config` ConfigMap is updated with the new `gateway.toml` content.
2. **Deployment restart** — The gateway Deployment SHALL be restarted to pick up the new configuration. The reconciler SHALL apply a restart annotation (e.g. `kubectl.kubernetes.io/restartedAt`) to trigger a rolling update.

### Transitions

| From | To | Effect |
|------|----|--------|
| No OIDC | OIDC enabled | `allow_unauthenticated_users` changes from `true` to `false`; OIDC section added |
| OIDC enabled | OIDC disabled | `allow_unauthenticated_users` changes from `false` to `true`; OIDC section removed |
| OIDC config A | OIDC config B | OIDC section updated (e.g. new issuer, new audience) |

## Interaction with TLS

OIDC operates alongside the gateway's TLS certificate authentication. The `client_ca_path` is always set in the gateway configuration (see [TLS spec](openshell-gateway-tls.spec.md)). The effective authentication mode depends on whether OIDC is configured:

| OIDC | Effect |
|------|--------|
| Enabled | Optional mTLS mode — sandbox supervisors authenticate via client certificates, CLI users authenticate via OIDC Bearer tokens |
| Disabled | Full mTLS mode — all clients must present valid client certificates |

The gateway internally computes `require_client_auth = has_client_ca && !has_oidc`. When OIDC is enabled, client certificate authentication becomes optional (certificates are validated when presented but not required).

## OIDC Provider Configuration

The OIDC provider (e.g. Keycloak) must be configured with a client and realm that matches the Gateway's OIDC settings. The control plane does not manage the OIDC provider — it is a prerequisite.

### Required OIDC Provider Setup

| Setting | Description |
|---------|-------------|
| Client | Public client (no client secret), OpenID Connect protocol |
| Redirect URIs | `http://localhost/*` and `http://127.0.0.1/*` (for CLI-based auth flows) |
| Standard flow | Enabled (authorization code flow) |
| Direct access grants | Enabled (password grant for automation) |
| Default client scopes | `openid`, `email`, `profile` |

### Required Protocol Mappers

| Mapper | Type | Purpose |
|--------|------|---------|
| audience | `oidc-audience-mapper` | Hardcodes `aud` claim to the configured audience value. Do NOT use `oidc-audience-resolve-mapper`. |
| sub | `oidc-sub-mapper` | Ensures `sub` claim is present in access tokens |
| roles | `oidc-usermodel-realm-role-mapper` or group membership | Maps realm roles or group membership into the configured `roles_claim` path |

See [local-development.spec.md](local-development.spec.md) for the Kind cluster Keycloak configuration.

## Requirements

### Requirement: OIDC Configuration Injection

When a Gateway has OIDC configuration, the reconciler SHALL inject it into the gateway's configuration.

#### Scenario: Gateway with OIDC
- GIVEN a Gateway with `oidc: {issuer: "https://keycloak.example.com/realms/hypershell", audience: "hypershell-frontend", roles_claim: "groups", admin_role: "hypershell-admins", user_role: "hypershell-users"}`
- WHEN the GatewayReconciler generates the ConfigMap
- THEN the `gateway.toml` SHALL include the `[openshell.gateway.oidc]` section with the specified values
- AND `allow_unauthenticated_users` SHALL be `false`

#### Scenario: Gateway without OIDC
- GIVEN a Gateway with no `oidc` configuration (or empty `oidc.issuer`)
- WHEN the GatewayReconciler generates the ConfigMap
- THEN the `gateway.toml` SHALL NOT include the `[openshell.gateway.oidc]` section
- AND `allow_unauthenticated_users` SHALL be `true`

#### Scenario: Gateway with Custom Config
- GIVEN a Gateway with a `config` field containing custom TOML content
- WHEN the GatewayReconciler generates the ConfigMap
- THEN the custom content SHALL be used verbatim
- AND the reconciler SHALL NOT inject OIDC or other computed sections

### Requirement: OIDC Role Validation

Both `admin_role` and `user_role` must be set together or both left empty.

#### Scenario: Partial Role Configuration
- GIVEN a Gateway with `oidc.admin_role: "admins"` but no `oidc.user_role`
- WHEN the API server validates the request
- THEN it SHALL reject the request with a validation error indicating both roles must be set

### Requirement: OIDC Change Triggers Restart

Changes to OIDC configuration SHALL trigger a gateway Deployment restart.

#### Scenario: OIDC Issuer Changed
- GIVEN a running Gateway with OIDC configured
- WHEN the `oidc.issuer` is updated to a different URL
- THEN the ConfigMap SHALL be updated with the new issuer
- AND the Deployment SHALL be restarted via a rolling update

#### Scenario: OIDC Enabled on Existing Gateway
- GIVEN a running Gateway without OIDC
- WHEN `oidc.issuer` is set for the first time
- THEN the ConfigMap SHALL be updated to include the OIDC section
- AND `allow_unauthenticated_users` SHALL change from `true` to `false`
- AND the Deployment SHALL be restarted

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| OIDC only, no standalone mTLS for end users | Team decision to simplify auth; OIDC is the recommended auth mode per upstream OpenShell docs. mTLS is retained only for internal sandbox-to-gateway communication |
| Custom `config` overrides injection | Provides an escape hatch for advanced users; prevents the reconciler from fighting user-provided configuration |
| Only non-empty fields in TOML | Upstream gateway has sensible defaults; omitting optional fields avoids overriding them with zero values |
| Restart annotation for config changes | ConfigMap changes are not automatically detected by pods; a restart annotation triggers a controlled rolling update |
| Audience mapper, not resolve mapper | `oidc-audience-resolve-mapper` includes all client IDs that the user has access to, which can include unrelated clients. The hardcoded audience mapper ensures the `aud` claim matches exactly |
