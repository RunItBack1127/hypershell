FROM registry.access.redhat.com/ubi9/go-toolset:1.25 AS builder

USER root

WORKDIR /workspace

COPY go.mod go.sum ./
RUN GOPRIVATE=github.com/openshift-online/rh-trex-ai go mod download

COPY cmd/ cmd/
COPY pkg/ pkg/
COPY plugins/ plugins/
COPY openapi/ openapi/

ARG GIT_VERSION=unknown
ARG BUILD_TIME=unknown
RUN go build -ldflags="-s -w \
  -X github.com/openshift-online/hypershell/components/api-server/pkg/api.Version=${GIT_VERSION} \
  -X 'github.com/openshift-online/hypershell/components/api-server/pkg/api.BuildTime=${BUILD_TIME}'" \
  -o hypershell ./cmd/hypershell

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

WORKDIR /

COPY --from=builder /workspace/hypershell /usr/local/bin/

EXPOSE 8000
EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/hypershell"]
CMD ["serve"]

LABEL name="hypershell" \
      version="0.0.1" \
      summary="HyperShell API Server" \
      description="REST + gRPC API server for HyperShell fleet management"
