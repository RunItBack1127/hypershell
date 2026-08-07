CONTAINER_ENGINE?=$(shell command -v podman 2>/dev/null || echo docker)
LEFTHOOK_CMD=go tool lefthook
GO_TOOLCHAIN=go1.26.4
GOLANGCI_LINT_VERSION=v2.12.2
GOLANGCI_LINT_PACKAGE=github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)
DEPENDENCY_MIN_AGE_DAYS=14
PNPM_VERSION=11.15.1
PNPM?=pnpm

# --- Image registry and tags ---
IMAGE_REGISTRY?=quay.io/redhat-services-prod/hcm-eng-prod-tenant/hypershell-main
IMAGE_TAG?=latest

# Build version (embedded in api-server binary via ldflags)
git_sha:=$(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
git_dirty:=$(shell git diff --quiet 2>/dev/null || echo -modified)
build_version:=$(git_sha)$(git_dirty)
build_time:=$(shell date -u '+%Y-%m-%d %H:%M:%S UTC')

# Computed baseline references (registry images used in Kind manifests)
api_server_ref=$(IMAGE_REGISTRY)/hypershell-api-server-main:$(IMAGE_TAG)
control_plane_ref=$(IMAGE_REGISTRY)/hypershell-control-plane-main:$(IMAGE_TAG)
web_console_ref=$(IMAGE_REGISTRY)/hypershell-web-console-main:$(IMAGE_TAG)

# Local dev image names
api_server_local=localhost/hypershell-api-server:dev
control_plane_local=localhost/hypershell-control-plane:dev
web_console_local=localhost/hypershell-web-console:dev
api_server_baseline_local=localhost/hypershell-api-server:baseline
control_plane_baseline_local=localhost/hypershell-control-plane:baseline
web_console_baseline_local=localhost/hypershell-web-console:baseline

# --- Kind cluster configuration ---
KIND_CLUSTER_NAME?=hypershell-dev
KIND_NAMESPACE?=hypershell-system
KIND_HOT_RELOAD?=true
KIND_HOST_MOUNT_PATH?=$(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
KIND_KEYCLOAK_PORT?=18080
LOCAL_IMAGES?=
KIND_PULL_SECRET?=

# Prerequisite versions
CLOUD_PROVIDER_KIND_VERSION?=v0.11.1
ENVOY_GATEWAY_VERSION?=v1.8.3
ENVOY_GATEWAY_CHART?=oci://docker.io/envoyproxy/gateway-helm@sha256:cfb34ff4266c87a394cd6be5c13607a2dd47083aef771368302eaeaa99c4a0a9
ENVOY_GATEWAY_CRDS_CHART?=oci://docker.io/envoyproxy/gateway-crds-helm@sha256:99b14db0bc57c8f413023d66145a2c53e8ed47f85fe0163b675c04165ff242d4
ENVOY_GATEWAY_IMAGE?=docker.io/envoyproxy/gateway:v1.8.3@sha256:e7a8c70537628bf996e5dec5c4c835704b4b9f4f715a74cf361bea30608c49ac
ENVOY_PROXY_IMAGE?=docker.io/envoyproxy/envoy:distroless-v1.38.3@sha256:574348fada8eb1130b448132287d76626dfb07525b16668075382f8e154a45a8
ENVOY_RATELIMIT_IMAGE?=docker.io/envoyproxy/ratelimit:1e50889b@sha256:5bb3741fd6709bab1d498eae1a5807faa2113b712dfb236fb76c04a00871ffc9
CERT_MANAGER_VERSION?=v1.21.1
KIND_NODE_IMAGE?=docker.io/kindest/node:v1.35.0@sha256:4613778f3cfcd10e615029370f5786704559103cf27bef934597ba562b269661
KIND_POSTGRES_IMAGE?=docker.io/library/postgres:16@sha256:95206741a5b214807675e14165369d05b93a9cf692223b616d07cca227e74b0b
KIND_GATEWAY_IMAGE?=ghcr.io/nvidia/openshell/gateway:0.0.92@sha256:6a789b7cba7a121245687653a3f7e7781fd569f495b3bf7f2a43ea1387d20d22

# Kind config
KIND_CONFIG=deploy/kind/kind-config.yaml

# Service hostnames (routed through the networking Gateway)
API_HOSTNAME=api.hypershell.localhost
CONSOLE_HOSTNAME=console.hypershell.localhost
HEALTH_HOSTNAME=health.hypershell.localhost
KEYCLOAK_HOSTNAME=keycloak.hypershell.localhost

# ============================================================================
# Build targets
# ============================================================================

.PHONY: build-all
build-all:
	@scripts/kind/build-images.sh

.PHONY: verify-pnpm
verify-pnpm:
	test "$$($(PNPM) --version)" = "$(PNPM_VERSION)"

.PHONY: install-js
install-js: verify-pnpm
	$(PNPM) install --frozen-lockfile

.PHONY: web-console-dev
web-console-dev: install-js
	$(PNPM) dev

.PHONY: web-console-image
web-console-image:
	$(CONTAINER_ENGINE) build -t $(web_console_local) \
		-f components/web-console/Dockerfile .

# ============================================================================
# Policy checks
# ============================================================================

.PHONY: check-forbidden-terms
check-forbidden-terms:
	python3 scripts/check_forbidden_terms.py

.PHONY: test-dependency-pin-policy
test-dependency-pin-policy:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts/test_check_dependency_pins.py

.PHONY: check-dependency-pins
check-dependency-pins: test-dependency-pin-policy
	python3 scripts/check_dependency_pins.py

.PHONY: check-ci-components
check-ci-components:
	python3 scripts/check_ci_components.py

.PHONY: test-dependency-age-policy
test-dependency-age-policy:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts/test_check_dependency_age.py

.PHONY: check-dependency-age
check-dependency-age: test-dependency-age-policy
	PYTHONDONTWRITEBYTECODE=1 python3 scripts/check_dependency_age.py --min-age-days $(DEPENDENCY_MIN_AGE_DAYS)

.PHONY: check
check: check-forbidden-terms check-dependency-pins check-ci-components check-dependency-age

# ============================================================================
# Git hooks
# ============================================================================

.PHONY: hooks-install
hooks-install:
	$(LEFTHOOK_CMD) install

.PHONY: hooks-run
hooks-run:
	$(LEFTHOOK_CMD) run check

# ============================================================================
# Lint targets
# ============================================================================

.PHONY: lint-api-server
lint-api-server:
	@unformatted="$$(gofmt -l components/api-server)"; \
	if [ -n "$$unformatted" ]; then \
		echo "The following API server files are not formatted:"; \
		echo "$$unformatted"; \
		exit 1; \
	fi
	cd components/api-server && GOTOOLCHAIN=$(GO_TOOLCHAIN) go vet ./...
	cd components/api-server && GOTOOLCHAIN=$(GO_TOOLCHAIN) go run $(GOLANGCI_LINT_PACKAGE) run --timeout=5m

.PHONY: lint-control-plane
lint-control-plane:
	bash -n scripts/kind/*.sh
	@unformatted="$$(gofmt -l components/control-plane)"; \
	if [ -n "$$unformatted" ]; then \
		echo "The following control plane files are not formatted:"; \
		echo "$$unformatted"; \
		exit 1; \
	fi
	cd components/control-plane && GOTOOLCHAIN=$(GO_TOOLCHAIN) go vet ./...
	cd components/control-plane && GOTOOLCHAIN=$(GO_TOOLCHAIN) go run $(GOLANGCI_LINT_PACKAGE) run --timeout=5m

.PHONY: lint-sdk-typescript
lint-sdk-typescript: install-js
	$(PNPM) --filter @openshift-online/hypershell-sdk check

.PHONY: lint-gateway-ui
lint-gateway-ui: install-js
	$(PNPM) --filter @openshift-online/hypershell-domain-probes build
	$(PNPM) --filter @openshift-online/hypershell-gateway-ui check

.PHONY: lint-web-console
lint-web-console: install-js
	$(PNPM) --filter @openshift-online/hypershell-domain-probes check
	$(PNPM) --filter @openshift-online/hypershell-web-console check
	$(PNPM) --filter @openshift-online/hypershell-web-console-bff check

.PHONY: lint
lint: check install-js lint-api-server lint-control-plane lint-sdk-typescript lint-gateway-ui lint-web-console

# ============================================================================
# Test targets
# ============================================================================

.PHONY: test-all
test-all: install-js
	cd components/api-server && $(MAKE) test
	$(PNPM) --filter @openshift-online/hypershell-domain-probes test:run
	$(PNPM) --filter @openshift-online/hypershell-gateway-ui test:run
	$(PNPM) --filter @openshift-online/hypershell-web-console test:run
	$(PNPM) --filter @openshift-online/hypershell-web-console-bff test:run

# ============================================================================
# Kind cluster lifecycle — shell logic lives in scripts/kind/
# ============================================================================

export CONTAINER_ENGINE KIND_CLUSTER_NAME KIND_NAMESPACE
export KIND_HOT_RELOAD KIND_HOST_MOUNT_PATH KIND_KEYCLOAK_PORT LOCAL_IMAGES
export KIND_PULL_SECRET
export CLOUD_PROVIDER_KIND_VERSION CERT_MANAGER_VERSION KIND_NODE_IMAGE
export ENVOY_GATEWAY_VERSION ENVOY_GATEWAY_CHART ENVOY_GATEWAY_CRDS_CHART
export ENVOY_GATEWAY_IMAGE ENVOY_PROXY_IMAGE ENVOY_RATELIMIT_IMAGE
export KIND_POSTGRES_IMAGE KIND_GATEWAY_IMAGE KIND_DB_IMAGE
export IMAGE_REGISTRY IMAGE_TAG KIND_CONFIG
export api_server_ref control_plane_ref web_console_ref
export api_server_local control_plane_local web_console_local
export api_server_baseline_local control_plane_baseline_local web_console_baseline_local
export build_version build_time
export API_HOSTNAME CONSOLE_HOSTNAME HEALTH_HOSTNAME KEYCLOAK_HOSTNAME

.PHONY: kind-up
kind-up:
	@scripts/kind/up.sh

.PHONY: kind-down
kind-down:
	@scripts/kind/down.sh

.PHONY: kind-status
kind-status:
	@scripts/kind/status.sh

.PHONY: kind-api-server-up
kind-api-server-up:
	@scripts/kind/swap-component.sh up api-server

.PHONY: kind-api-server-down
kind-api-server-down:
	@scripts/kind/swap-component.sh down api-server

.PHONY: kind-control-plane-up
kind-control-plane-up:
	@scripts/kind/swap-component.sh up control-plane

.PHONY: kind-control-plane-down
kind-control-plane-down:
	@scripts/kind/swap-component.sh down control-plane

.PHONY: kind-web-console-up
kind-web-console-up:
	@scripts/kind/swap-component.sh up web-console

.PHONY: kind-web-console-down
kind-web-console-down:
	@scripts/kind/swap-component.sh down web-console

.PHONY: kind-deploy
kind-deploy:
	@scripts/kind/deploy-namespace.sh

.PHONY: kind-undeploy
kind-undeploy:
	@scripts/kind/deploy-namespace.sh undeploy
