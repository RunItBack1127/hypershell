package reconciler

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	pb "github.com/openshift-online/hypershell/components/api-server/pkg/api/grpc/hypershell/v1"
	"github.com/openshift-online/hypershell/components/control-plane/internal/gateway"
	"github.com/openshift-online/hypershell/components/control-plane/internal/watcher"
	"google.golang.org/grpc"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
)

type FleetReconciler struct {
	mu     sync.Mutex
	active map[string]struct{}
}

func NewFleetReconciler() *FleetReconciler {
	return &FleetReconciler{active: make(map[string]struct{})}
}

func (r *FleetReconciler) Handle(ctx context.Context, event watcher.Event[*pb.Fleet]) error {
	r.mu.Lock()
	if _, ok := r.active[event.ResourceID]; ok {
		r.mu.Unlock()
		return nil
	}
	r.active[event.ResourceID] = struct{}{}
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.active, event.ResourceID)
		r.mu.Unlock()
	}()

	log.Printf("INFO reconciling Fleet %s (event=%d)", event.ResourceID, event.Type)
	return nil
}

type ManagedClusterReconciler struct {
	mu     sync.Mutex
	active map[string]struct{}
}

func NewManagedClusterReconciler() *ManagedClusterReconciler {
	return &ManagedClusterReconciler{active: make(map[string]struct{})}
}

func (r *ManagedClusterReconciler) Handle(ctx context.Context, event watcher.Event[*pb.ManagedCluster]) error {
	r.mu.Lock()
	if _, ok := r.active[event.ResourceID]; ok {
		r.mu.Unlock()
		return nil
	}
	r.active[event.ResourceID] = struct{}{}
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.active, event.ResourceID)
		r.mu.Unlock()
	}()

	log.Printf("INFO reconciling ManagedCluster %s (event=%d)", event.ResourceID, event.Type)
	return nil
}

type ManagedDatabaseReconciler struct {
	mu     sync.Mutex
	active map[string]struct{}
}

func NewManagedDatabaseReconciler() *ManagedDatabaseReconciler {
	return &ManagedDatabaseReconciler{active: make(map[string]struct{})}
}

func (r *ManagedDatabaseReconciler) Handle(ctx context.Context, event watcher.Event[*pb.ManagedDatabase]) error {
	r.mu.Lock()
	if _, ok := r.active[event.ResourceID]; ok {
		r.mu.Unlock()
		return nil
	}
	r.active[event.ResourceID] = struct{}{}
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.active, event.ResourceID)
		r.mu.Unlock()
	}()

	log.Printf("INFO reconciling ManagedDatabase %s (event=%d)", event.ResourceID, event.Type)
	return nil
}

type GatewayReleaseReconciler struct {
	mu     sync.Mutex
	active map[string]struct{}
}

func NewGatewayReleaseReconciler() *GatewayReleaseReconciler {
	return &GatewayReleaseReconciler{active: make(map[string]struct{})}
}

func (r *GatewayReleaseReconciler) Handle(ctx context.Context, event watcher.Event[*pb.GatewayRelease]) error {
	r.mu.Lock()
	if _, ok := r.active[event.ResourceID]; ok {
		r.mu.Unlock()
		return nil
	}
	r.active[event.ResourceID] = struct{}{}
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.active, event.ResourceID)
		r.mu.Unlock()
	}()

	log.Printf("INFO reconciling GatewayRelease %s (event=%d)", event.ResourceID, event.Type)
	return nil
}

type GatewayReconciler struct {
	mu                    sync.Mutex
	active                map[string]struct{}
	dynamicClient         dynamic.Interface
	clientset             *kubernetes.Clientset
	grpcConn              *grpc.ClientConn
	releaseClient         gatewayReleaseClient
	manifests             map[string][]*unstructured.Unstructured
	isOpenShift           bool
	hasCertManager        bool
	hasGatewayAPI         bool
	manifestsDir          string
	controlPlaneNamespace string
}

type gatewayReleaseClient interface {
	GetGatewayRelease(context.Context, *pb.GetGatewayReleaseRequest, ...grpc.CallOption) (*pb.GetGatewayReleaseResponse, error)
}

func NewGatewayReconciler(
	dynamicClient dynamic.Interface,
	clientset *kubernetes.Clientset,
	grpcConn *grpc.ClientConn,
	manifestsDir string,
	controlPlaneNamespace string,
) (*GatewayReconciler, error) {
	manifests, err := gateway.LoadGatewayManifests(manifestsDir)
	if err != nil {
		return nil, fmt.Errorf("load gateway manifests from %s: %w", manifestsDir, err)
	}

	isOpenShift := gateway.DetectOpenShift(clientset)
	hasCertManager := gateway.DetectCertManager(clientset)
	hasGatewayAPI := gateway.DetectGatewayAPI(clientset)
	log.Printf("INFO gateway reconciler initialized: manifests=%d openshift=%v certmanager=%v gatewayapi=%v", len(manifests), isOpenShift, hasCertManager, hasGatewayAPI)

	return &GatewayReconciler{
		active:                make(map[string]struct{}),
		dynamicClient:         dynamicClient,
		clientset:             clientset,
		grpcConn:              grpcConn,
		releaseClient:         pb.NewGatewayReleaseServiceClient(grpcConn),
		manifests:             manifests,
		isOpenShift:           isOpenShift,
		hasCertManager:        hasCertManager,
		hasGatewayAPI:         hasGatewayAPI,
		manifestsDir:          manifestsDir,
		controlPlaneNamespace: controlPlaneNamespace,
	}, nil
}

func (r *GatewayReconciler) Handle(ctx context.Context, event watcher.Event[*pb.Gateway]) error {
	r.mu.Lock()
	if _, ok := r.active[event.ResourceID]; ok {
		r.mu.Unlock()
		return nil
	}
	r.active[event.ResourceID] = struct{}{}
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.active, event.ResourceID)
		r.mu.Unlock()
	}()

	gw := event.Resource
	if gw == nil {
		log.Printf("WARN gateway event %s has nil resource, skipping", event.ResourceID)
		return nil
	}

	log.Printf("INFO reconciling Gateway %s name=%s namespace=%s (event=%d)",
		event.ResourceID, gw.Name, gw.Namespace, event.Type)

	if event.Type == watcher.EventDeleted {
		log.Printf("INFO gateway %s deleted, skipping provisioning", event.ResourceID)
		return nil
	}

	// Phase updates are emitted on the same watch as specification changes. Ignore
	// controller-owned phases so those updates do not create a reconciliation
	// loop. Callers that change desired state clear phase, causing the next
	// MODIFIED event to reconcile.
	if isControllerOwnedPhase(gw.Phase) {
		log.Printf("DEBUG gateway %s phase=%s, skipping reconciliation", event.ResourceID, *gw.Phase)
		return nil
	}

	namespace := gw.Namespace
	if namespace == "" {
		namespace = fmt.Sprintf("openshell-%s", gw.Name)
	}

	externalDns := ""
	if gw.ExternalDns != nil {
		externalDns = *gw.ExternalDns
	}

	gatewayConfig, err := r.gatewayConfig(ctx, gw, namespace, externalDns)
	if err != nil {
		r.updateGatewayState(ctx, event.ResourceID, "Failed", nil)
		return fmt.Errorf("build gateway configuration for %s: %w", gw.Name, err)
	}

	nsConfig := gateway.NamespaceConfig{
		Name:    namespace,
		Gateway: gatewayConfig,
	}

	opts := gateway.ReconcileOpts{
		IsOpenShift:           r.isOpenShift,
		HasCertManager:        r.hasCertManager,
		HasGatewayAPI:         r.hasGatewayAPI,
		ControlPlaneNamespace: r.controlPlaneNamespace,
	}

	var derivedExternalDNS *string
	if gatewayConfig.ExternalDns != externalDns {
		derivedExternalDNS = &gatewayConfig.ExternalDns
	}
	r.updateGatewayState(ctx, event.ResourceID, "Provisioning", derivedExternalDNS)

	if err := gateway.ReconcileGateway(ctx, r.dynamicClient, r.clientset, nsConfig, r.manifests, opts); err != nil {
		r.updateGatewayState(ctx, event.ResourceID, "Failed", nil)
		return fmt.Errorf("reconcile gateway %s: %w", gw.Name, err)
	}
	if err := gateway.WaitForGatewayReady(ctx, r.clientset, namespace, 5*time.Minute); err != nil {
		r.updateGatewayState(ctx, event.ResourceID, "Failed", nil)
		return fmt.Errorf("wait for gateway %s: %w", gw.Name, err)
	}

	r.updateGatewayState(ctx, event.ResourceID, "Running", nil)
	log.Printf("INFO gateway %s provisioned in namespace %s", gw.Name, namespace)
	return nil
}

func (r *GatewayReconciler) gatewayConfig(
	ctx context.Context,
	gw *pb.Gateway,
	namespace string,
	externalDNS string,
) (gateway.GatewayConfig, error) {
	if gw.GetReleaseId() == "" {
		return gateway.GatewayConfig{}, fmt.Errorf("release_id is required")
	}

	response, err := r.releaseClient.GetGatewayRelease(ctx, &pb.GetGatewayReleaseRequest{Id: gw.GetReleaseId()})
	if err != nil {
		return gateway.GatewayConfig{}, fmt.Errorf("get GatewayRelease %s: %w", gw.GetReleaseId(), err)
	}
	release := response.GetGatewayRelease()
	if release == nil || release.GetImage() == "" {
		return gateway.GatewayConfig{}, fmt.Errorf("GatewayRelease %s has no image", gw.GetReleaseId())
	}

	routeEnabled := false
	if value := os.Getenv("OPENSHELL_GATEWAY_ROUTE_ENABLED"); value != "" {
		routeEnabled, err = strconv.ParseBool(value)
		if err != nil {
			return gateway.GatewayConfig{}, fmt.Errorf("parse OPENSHELL_GATEWAY_ROUTE_ENABLED: %w", err)
		}
	}
	if routeEnabled && externalDNS == "" {
		baseDomain := strings.Trim(strings.TrimSpace(os.Getenv("GATEWAY_API_BASE_DOMAIN")), ".")
		if baseDomain == "" {
			return gateway.GatewayConfig{}, fmt.Errorf("GATEWAY_API_BASE_DOMAIN is required to derive external_dns when Gateway API routing is enabled")
		}
		externalDNS = fmt.Sprintf("openshell-gateway-%s.%s", namespace, baseDomain)
	}
	dnsNames := []string{fmt.Sprintf("openshell-gateway.%s.svc.cluster.local", namespace)}
	if externalDNS != "" {
		dnsNames = append(dnsNames, externalDNS)
	}

	return gateway.GatewayConfig{
		Image:          release.GetImage(),
		ServerDnsNames: dnsNames,
		ExternalDns:    externalDNS,
		Database: gateway.DatabaseConfig{
			Image:       os.Getenv("OPENSHELL_GATEWAY_DATABASE_IMAGE"),
			StorageSize: os.Getenv("OPENSHELL_GATEWAY_DATABASE_STORAGE_SIZE"),
		},
		OIDC: gateway.OIDCConfig{
			Issuer:      os.Getenv("OPENSHELL_GATEWAY_OIDC_ISSUER"),
			Audience:    os.Getenv("OPENSHELL_GATEWAY_OIDC_AUDIENCE"),
			RolesClaim:  os.Getenv("OPENSHELL_GATEWAY_OIDC_ROLES_CLAIM"),
			AdminRole:   os.Getenv("OPENSHELL_GATEWAY_OIDC_ADMIN_ROLE"),
			UserRole:    os.Getenv("OPENSHELL_GATEWAY_OIDC_USER_ROLE"),
			ScopesClaim: os.Getenv("OPENSHELL_GATEWAY_OIDC_SCOPES_CLAIM"),
		},
		Route: gateway.RouteConfig{
			Enabled: routeEnabled,
			Host:    externalDNS,
		},
	}, nil
}

func isControllerOwnedPhase(phase *string) bool {
	if phase == nil {
		return false
	}
	switch *phase {
	case "Provisioning", "Running", "Failed":
		return true
	default:
		return false
	}
}

func (r *GatewayReconciler) updateGatewayState(ctx context.Context, gatewayID string, phase string, externalDNS *string) {
	client := pb.NewGatewayServiceClient(r.grpcConn)
	request := &pb.UpdateGatewayRequest{Id: gatewayID, Phase: &phase}
	request.ExternalDns = externalDNS
	_, err := client.UpdateGateway(ctx, request)
	if err != nil {
		log.Printf("WARN failed to update gateway %s state to phase %s: %v", gatewayID, phase, err)
	}
}

type StubGatewayReconciler struct{}

func NewStubGatewayReconciler() *StubGatewayReconciler {
	return &StubGatewayReconciler{}
}

func (r *StubGatewayReconciler) Handle(ctx context.Context, event watcher.Event[*pb.Gateway]) error {
	log.Printf("INFO [stub] reconciling Gateway %s (event=%d)", event.ResourceID, event.Type)
	return nil
}

type GatewayNetworkReconciler struct {
	mu     sync.Mutex
	active map[string]struct{}
}

func NewGatewayNetworkReconciler() *GatewayNetworkReconciler {
	return &GatewayNetworkReconciler{active: make(map[string]struct{})}
}

func (r *GatewayNetworkReconciler) Handle(ctx context.Context, event watcher.Event[*pb.GatewayNetwork]) error {
	r.mu.Lock()
	if _, ok := r.active[event.ResourceID]; ok {
		r.mu.Unlock()
		return nil
	}
	r.active[event.ResourceID] = struct{}{}
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.active, event.ResourceID)
		r.mu.Unlock()
	}()

	log.Printf("INFO reconciling GatewayNetwork %s (event=%d)", event.ResourceID, event.Type)
	return nil
}
