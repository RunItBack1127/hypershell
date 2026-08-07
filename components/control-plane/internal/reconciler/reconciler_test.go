package reconciler

import (
	"context"
	"errors"
	"strings"
	"testing"

	pb "github.com/openshift-online/hypershell/components/api-server/pkg/api/grpc/hypershell/v1"
	"google.golang.org/grpc"
)

type gatewayReleaseClientFunc func(context.Context, *pb.GetGatewayReleaseRequest, ...grpc.CallOption) (*pb.GetGatewayReleaseResponse, error)

func (f gatewayReleaseClientFunc) GetGatewayRelease(
	ctx context.Context,
	request *pb.GetGatewayReleaseRequest,
	opts ...grpc.CallOption,
) (*pb.GetGatewayReleaseResponse, error) {
	return f(ctx, request, opts...)
}

func TestGatewayConfigResolvesReleaseAndLocalDefaults(t *testing.T) {
	t.Setenv("OPENSHELL_GATEWAY_DATABASE_IMAGE", "postgres@example")
	t.Setenv("OPENSHELL_GATEWAY_DATABASE_STORAGE_SIZE", "7Gi")
	t.Setenv("OPENSHELL_GATEWAY_OIDC_ISSUER", "http://keycloak.example/realms/hypershell")
	t.Setenv("OPENSHELL_GATEWAY_OIDC_AUDIENCE", "openshell-cli")
	t.Setenv("OPENSHELL_GATEWAY_OIDC_ROLES_CLAIM", "groups")
	t.Setenv("OPENSHELL_GATEWAY_OIDC_ADMIN_ROLE", "admins")
	t.Setenv("OPENSHELL_GATEWAY_OIDC_USER_ROLE", "users")
	t.Setenv("OPENSHELL_GATEWAY_OIDC_SCOPES_CLAIM", "scope")
	t.Setenv("OPENSHELL_GATEWAY_ROUTE_ENABLED", "true")

	reconciler := &GatewayReconciler{
		releaseClient: gatewayReleaseClientFunc(func(_ context.Context, request *pb.GetGatewayReleaseRequest, _ ...grpc.CallOption) (*pb.GetGatewayReleaseResponse, error) {
			if request.GetId() != "release-1" {
				t.Fatalf("unexpected release id %q", request.GetId())
			}
			return &pb.GetGatewayReleaseResponse{GatewayRelease: &pb.GatewayRelease{Image: "gateway@example"}}, nil
		}),
	}

	config, err := reconciler.gatewayConfig(
		context.Background(),
		&pb.Gateway{ReleaseId: "release-1"},
		"openshell-example",
		"gateway.example",
	)
	if err != nil {
		t.Fatalf("gatewayConfig() error = %v", err)
	}
	if config.Image != "gateway@example" {
		t.Fatalf("image = %q, want gateway@example", config.Image)
	}
	if config.Database.Image != "postgres@example" || config.Database.StorageSize != "7Gi" {
		t.Fatalf("database config = %#v", config.Database)
	}
	if config.OIDC.Issuer != "http://keycloak.example/realms/hypershell" || config.OIDC.Audience != "openshell-cli" {
		t.Fatalf("OIDC config = %#v", config.OIDC)
	}
	if !config.Route.Enabled || config.Route.Host != "gateway.example" {
		t.Fatalf("route config = %#v", config.Route)
	}
}

func TestGatewayConfigDerivesRouteHostname(t *testing.T) {
	t.Setenv("OPENSHELL_GATEWAY_ROUTE_ENABLED", "true")
	t.Setenv("GATEWAY_API_BASE_DOMAIN", ".gw.localhost.")
	reconciler := &GatewayReconciler{
		releaseClient: gatewayReleaseClientFunc(func(context.Context, *pb.GetGatewayReleaseRequest, ...grpc.CallOption) (*pb.GetGatewayReleaseResponse, error) {
			return &pb.GetGatewayReleaseResponse{GatewayRelease: &pb.GatewayRelease{Image: "gateway@example"}}, nil
		}),
	}

	config, err := reconciler.gatewayConfig(
		context.Background(),
		&pb.Gateway{ReleaseId: "release-1"},
		"openshell-test",
		"",
	)
	if err != nil {
		t.Fatalf("gatewayConfig() error = %v", err)
	}
	if config.ExternalDns != "openshell-gateway-openshell-test.gw.localhost" {
		t.Fatalf("external DNS = %q", config.ExternalDns)
	}
	wantNames := []string{
		"openshell-gateway.openshell-test.svc.cluster.local",
		"openshell-gateway-openshell-test.gw.localhost",
	}
	if len(config.ServerDnsNames) != len(wantNames) {
		t.Fatalf("server DNS names = %#v", config.ServerDnsNames)
	}
	for index, want := range wantNames {
		if config.ServerDnsNames[index] != want {
			t.Fatalf("server DNS name %d = %q, want %q", index, config.ServerDnsNames[index], want)
		}
	}
}

func TestControllerOwnedGatewayPhases(t *testing.T) {
	for _, phase := range []string{"Provisioning", "Running", "Failed"} {
		phase := phase
		if !isControllerOwnedPhase(&phase) {
			t.Errorf("isControllerOwnedPhase(%q) = false", phase)
		}
	}
	for _, phase := range []string{"", "Pending", "Ready"} {
		phase := phase
		if isControllerOwnedPhase(&phase) {
			t.Errorf("isControllerOwnedPhase(%q) = true", phase)
		}
	}
	if isControllerOwnedPhase(nil) {
		t.Error("isControllerOwnedPhase(nil) = true")
	}
}

func TestGatewayConfigRejectsInvalidInputs(t *testing.T) {
	tests := []struct {
		name       string
		gateway    *pb.Gateway
		routeValue string
		external   string
		response   *pb.GetGatewayReleaseResponse
		clientErr  error
		want       string
	}{
		{name: "missing release", gateway: &pb.Gateway{}, want: "release_id is required"},
		{name: "release lookup", gateway: &pb.Gateway{ReleaseId: "missing"}, clientErr: errors.New("not found"), want: "get GatewayRelease missing"},
		{name: "missing image", gateway: &pb.Gateway{ReleaseId: "empty"}, response: &pb.GetGatewayReleaseResponse{GatewayRelease: &pb.GatewayRelease{}}, want: "has no image"},
		{name: "invalid route flag", gateway: &pb.Gateway{ReleaseId: "release"}, response: &pb.GetGatewayReleaseResponse{GatewayRelease: &pb.GatewayRelease{Image: "gateway@example"}}, routeValue: "sometimes", want: "parse OPENSHELL_GATEWAY_ROUTE_ENABLED"},
		{name: "route without DNS configuration", gateway: &pb.Gateway{ReleaseId: "release"}, response: &pb.GetGatewayReleaseResponse{GatewayRelease: &pb.GatewayRelease{Image: "gateway@example"}}, routeValue: "true", want: "GATEWAY_API_BASE_DOMAIN is required"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("OPENSHELL_GATEWAY_ROUTE_ENABLED", test.routeValue)
			reconciler := &GatewayReconciler{
				releaseClient: gatewayReleaseClientFunc(func(context.Context, *pb.GetGatewayReleaseRequest, ...grpc.CallOption) (*pb.GetGatewayReleaseResponse, error) {
					return test.response, test.clientErr
				}),
			}
			_, err := reconciler.gatewayConfig(context.Background(), test.gateway, "openshell-test", test.external)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("gatewayConfig() error = %v, want containing %q", err, test.want)
			}
		})
	}
}
