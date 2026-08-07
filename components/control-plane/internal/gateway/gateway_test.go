package gateway

import (
	"context"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/kubernetes/fake"
)

func TestApplyConfigOverridesEscapesValuesAndChangesRolloutHash(t *testing.T) {
	configMap := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "v1",
		"kind":       "ConfigMap",
		"metadata": map[string]interface{}{
			"name": "openshell-gateway-config",
		},
		"data": map[string]interface{}{
			"gateway.toml": "server_sans = []\nallow_unauthenticated_users = true",
		},
	}}
	config := GatewayConfig{
		ServerDnsNames: []string{"gateway.example"},
		OIDC: OIDCConfig{
			Issuer:     "https://issuer.example/realm/\"quoted\"",
			Audience:   "openshell-cli",
			AdminRole:  "admins",
			UserRole:   "users",
			RolesClaim: "groups",
		},
	}
	if err := ApplyConfigOverrides(configMap, config); err != nil {
		t.Fatalf("ApplyConfigOverrides(ConfigMap) error = %v", err)
	}
	toml, _, _ := unstructured.NestedString(configMap.Object, "data", "gateway.toml")
	for _, expected := range []string{
		`server_sans = ["gateway.example"]`,
		`issuer      = "https://issuer.example/realm/\"quoted\""`,
		"allow_unauthenticated_users = false",
	} {
		if !strings.Contains(toml, expected) {
			t.Fatalf("gateway TOML does not contain %q:\n%s", expected, toml)
		}
	}

	deployment := gatewayDeploymentForTest()
	if err := ApplyConfigOverrides(deployment, config); err != nil {
		t.Fatalf("ApplyConfigOverrides(Deployment) error = %v", err)
	}
	annotations, _, _ := unstructured.NestedStringMap(deployment.Object, "spec", "template", "metadata", "annotations")
	firstHash := annotations["hypershell.redhat.io/config-hash"]
	if len(firstHash) != 64 {
		t.Fatalf("rollout hash = %q, want a SHA-256 hex digest", firstHash)
	}
	config.OIDC.Audience = "different"
	if err := ApplyConfigOverrides(deployment, config); err != nil {
		t.Fatalf("ApplyConfigOverrides(Deployment) second error = %v", err)
	}
	annotations, _, _ = unstructured.NestedStringMap(deployment.Object, "spec", "template", "metadata", "annotations")
	if annotations["hypershell.redhat.io/config-hash"] == firstHash {
		t.Fatal("rollout hash did not change when gateway config changed")
	}
}

func TestApplyDatabaseOverridesUsesPinnedPublicDefault(t *testing.T) {
	object := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"spec": map[string]interface{}{
			"template": map[string]interface{}{
				"spec": map[string]interface{}{
					"containers": []interface{}{map[string]interface{}{"image": "DB_IMAGE_PLACEHOLDER"}},
				},
			},
		},
	}}
	if err := ApplyDatabaseOverrides(object, DatabaseConfig{}); err != nil {
		t.Fatalf("ApplyDatabaseOverrides() error = %v", err)
	}
	image, _, _ := unstructured.NestedString(object.Object, "spec", "template", "spec", "containers", "0", "image")
	if image != "" {
		// NestedString cannot index slices; inspect the rendered object below.
		t.Fatalf("unexpected direct nested image = %q", image)
	}
	containers, _, _ := unstructured.NestedSlice(object.Object, "spec", "template", "spec", "containers")
	container := containers[0].(map[string]interface{})
	got := container["image"].(string)
	if !strings.Contains(got, "docker.io/library/postgres:16@sha256:") {
		t.Fatalf("database image = %q, want pinned public PostgreSQL 16", got)
	}
}

func TestGatewayImageSubstitutionDoesNotCorruptDatabasePlaceholder(t *testing.T) {
	manifests, err := LoadGatewayManifests("../../manifests/gateway")
	if err != nil {
		t.Fatalf("LoadGatewayManifests() error = %v", err)
	}
	resources := manifests["deployment.yaml"]
	if len(resources) != 1 {
		t.Fatalf("deployment resources = %d, want 1", len(resources))
	}

	object, err := ApplyManifestToNamespace(resources[0], "gateway-test", GatewayConfig{}, "gateway@example")
	if err != nil {
		t.Fatalf("ApplyManifestToNamespace() error = %v", err)
	}
	podSpec, _, _ := unstructured.NestedMap(object.Object, "spec", "template", "spec")
	initContainers := podSpec["initContainers"].([]interface{})
	containers := podSpec["containers"].([]interface{})
	initImage := initContainers[0].(map[string]interface{})["image"]
	gatewayImage := containers[0].(map[string]interface{})["image"]
	if initImage != "DB_IMAGE_PLACEHOLDER" {
		t.Fatalf("database init image = %q, want untouched database placeholder", initImage)
	}
	if gatewayImage != "gateway@example" {
		t.Fatalf("gateway image = %q, want gateway@example", gatewayImage)
	}
}

func TestWaitForGatewayReady(t *testing.T) {
	available := func(name string) *appsv1.Deployment {
		return &appsv1.Deployment{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "gateway", Generation: 2},
			Status: appsv1.DeploymentStatus{
				ObservedGeneration: 2,
				Conditions:         []appsv1.DeploymentCondition{{Type: appsv1.DeploymentAvailable, Status: corev1.ConditionTrue}},
			},
		}
	}
	client := fake.NewSimpleClientset(available("openshell-gateway-db"), available("openshell-gateway"))
	if err := WaitForGatewayReady(context.Background(), client, "gateway", time.Second); err != nil {
		t.Fatalf("WaitForGatewayReady() error = %v", err)
	}
}

func TestWaitForGatewayReadyTimesOutWithDeploymentIdentity(t *testing.T) {
	client := fake.NewSimpleClientset()
	err := WaitForGatewayReady(context.Background(), client, "gateway-test", 10*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "gateway-test/openshell-gateway-db") {
		t.Fatalf("WaitForGatewayReady() error = %v, want database Deployment identity", err)
	}
}

func TestWaitForTLSSecret(t *testing.T) {
	client := fake.NewSimpleClientset(&corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "openshell-server-tls", Namespace: "gateway"},
		Data: map[string][]byte{
			"ca.crt":  []byte("ca"),
			"tls.crt": []byte("cert"),
			"tls.key": []byte("key"),
		},
	})
	if err := waitForTLSSecret(context.Background(), client, "gateway", time.Second); err != nil {
		t.Fatalf("waitForTLSSecret() error = %v", err)
	}
}

func TestValidateGatewayConfigRejectsInvalidRouteAndIssuer(t *testing.T) {
	tests := []GatewayConfig{
		{Route: RouteConfig{Enabled: true, Host: "not a dns name"}},
		{OIDC: OIDCConfig{Issuer: "keycloak.example", AdminRole: "admins", UserRole: "users"}},
	}
	for _, config := range tests {
		if err := ValidateGatewayConfig(config); err == nil {
			t.Fatalf("ValidateGatewayConfig(%#v) unexpectedly succeeded", config)
		}
	}
}

func TestGatewayNetworkPolicyExposesOnlyPublicGRPC(t *testing.T) {
	manifests, err := LoadGatewayManifests("../../manifests/gateway")
	if err != nil {
		t.Fatalf("LoadGatewayManifests() error = %v", err)
	}

	var publicPolicy *unstructured.Unstructured
	for _, object := range manifests["networkpolicy.yaml"] {
		if object.GetName() == "openshell-gateway-public-grpc" {
			publicPolicy = object
			break
		}
	}
	if publicPolicy == nil {
		t.Fatal("openshell-gateway-public-grpc NetworkPolicy not found")
	}

	ingress, found, err := unstructured.NestedSlice(publicPolicy.Object, "spec", "ingress")
	if err != nil || !found || len(ingress) != 1 {
		t.Fatalf("public ingress rules = %#v, found = %v, error = %v; want one rule", ingress, found, err)
	}
	rule, ok := ingress[0].(map[string]interface{})
	if !ok {
		t.Fatalf("public ingress rule has type %T", ingress[0])
	}
	if _, hasSourceRestriction := rule["from"]; hasSourceRestriction {
		t.Fatalf("public ingress rule unexpectedly restricts external sources: %#v", rule["from"])
	}
	ports, ok := rule["ports"].([]interface{})
	if !ok || len(ports) != 1 {
		t.Fatalf("public ingress ports = %#v, want only gateway gRPC", rule["ports"])
	}
	port, ok := ports[0].(map[string]interface{})
	if !ok || port["port"] != int64(8080) || port["protocol"] != "TCP" {
		t.Fatalf("public ingress port = %#v, want TCP 8080", ports[0])
	}
}

func gatewayDeploymentForTest() *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]interface{}{
			"name": "openshell-gateway",
		},
		"spec": map[string]interface{}{
			"template": map[string]interface{}{
				"metadata": map[string]interface{}{},
			},
		},
	}}
}
