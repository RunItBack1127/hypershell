package gateway

import (
	"encoding/base64"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// consoleContainerByName returns the named container map from a console
// Deployment built by buildConsoleDeployment.
func consoleContainerByName(t *testing.T, dep *unstructured.Unstructured, name string) map[string]interface{} {
	t.Helper()
	containers, found, err := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "containers")
	if err != nil || !found {
		t.Fatalf("containers not found: found=%v err=%v", found, err)
	}
	for _, c := range containers {
		m, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		if n, _, _ := unstructured.NestedString(m, "name"); n == name {
			return m
		}
	}
	t.Fatalf("container %q not found", name)
	return nil
}

func envValue(container map[string]interface{}, name string) (string, bool) {
	env, _, _ := unstructured.NestedSlice(container, "env")
	for _, e := range env {
		m, ok := e.(map[string]interface{})
		if !ok {
			continue
		}
		if n, _, _ := unstructured.NestedString(m, "name"); n == name {
			v, _, _ := unstructured.NestedString(m, "value")
			return v, true
		}
	}
	return "", false
}

func volumeNames(t *testing.T, dep *unstructured.Unstructured) map[string]bool {
	t.Helper()
	vols, _, _ := unstructured.NestedSlice(dep.Object, "spec", "template", "spec", "volumes")
	out := map[string]bool{}
	for _, v := range vols {
		m, ok := v.(map[string]interface{})
		if !ok {
			continue
		}
		if n, _, _ := unstructured.NestedString(m, "name"); n != "" {
			out[n] = true
		}
	}
	return out
}

func volumeMountNames(container map[string]interface{}) map[string]bool {
	mounts, _, _ := unstructured.NestedSlice(container, "volumeMounts")
	out := map[string]bool{}
	for _, m := range mounts {
		mm, ok := m.(map[string]interface{})
		if !ok {
			continue
		}
		if n, _, _ := unstructured.NestedString(mm, "name"); n != "" {
			out[n] = true
		}
	}
	return out
}

// When the issuer is served with a privately-signed certificate (trustedCA), the
// oauth2-proxy sidecar must mount the CA bundle and be pointed at it for OIDC
// discovery -- otherwise discovery fails with an x509 unknown-authority error.
func TestBuildConsoleDeployment_TrustedCAWiresOAuth2ProxyCA(t *testing.T) {
	dep := buildConsoleDeployment("ns", "dash:latest", "proxy:latest",
		"https://issuer.example/realms/r", "gw-1-console", "https://console.example/oauth2/callback", true)

	proxy := consoleContainerByName(t, dep, "oauth2-proxy")

	caFile, ok := envValue(proxy, "OAUTH2_PROXY_PROVIDER_CA_FILES")
	if !ok {
		t.Fatal("expected OAUTH2_PROXY_PROVIDER_CA_FILES to be set when trustedCA is true")
	}
	if caFile != consoleTrustedCAMountPath {
		t.Errorf("OAUTH2_PROXY_PROVIDER_CA_FILES = %q, want %q", caFile, consoleTrustedCAMountPath)
	}
	if !volumeNames(t, dep)["oidc-trusted-ca"] {
		t.Error("expected oidc-trusted-ca volume on the pod spec")
	}
	if !volumeMountNames(proxy)["oidc-trusted-ca"] {
		t.Error("expected oidc-trusted-ca volumeMount on the oauth2-proxy container")
	}
}

// In production the issuer is publicly trusted and the trusted-CA ConfigMap is
// absent, so the sidecar must not reference a CA file or mount that would fail
// to bind.
func TestBuildConsoleDeployment_NoTrustedCAOmitsOAuth2ProxyCA(t *testing.T) {
	dep := buildConsoleDeployment("ns", "dash:latest", "proxy:latest",
		"https://issuer.example/realms/r", "gw-1-console", "https://console.example/oauth2/callback", false)

	proxy := consoleContainerByName(t, dep, "oauth2-proxy")

	if _, ok := envValue(proxy, "OAUTH2_PROXY_PROVIDER_CA_FILES"); ok {
		t.Error("did not expect OAUTH2_PROXY_PROVIDER_CA_FILES when trustedCA is false")
	}
	if volumeNames(t, dep)["oidc-trusted-ca"] {
		t.Error("did not expect oidc-trusted-ca volume when trustedCA is false")
	}
	if volumeMountNames(proxy)["oidc-trusted-ca"] {
		t.Error("did not expect oidc-trusted-ca volumeMount when trustedCA is false")
	}
}

// The cookie secret must survive oauth2-proxy's SecretBytes decoding: strip
// padding, URL-base64-decode, and land on 16/24/32 bytes. A standard-base64
// value (44 chars, +/ alphabet) is rejected and used verbatim, crashing the
// sidecar with "cookie_secret must be 16, 24, or 32 bytes".
func TestGenerateConsoleCookieSecret_DecodesTo32Bytes(t *testing.T) {
	for i := 0; i < 50; i++ {
		s, err := generateConsoleCookieSecret()
		if err != nil {
			t.Fatalf("generateConsoleCookieSecret: %v", err)
		}
		if strings.ContainsAny(s, "+/=") {
			t.Fatalf("cookie secret %q contains std-base64/padding chars oauth2-proxy cannot URL-decode", s)
		}
		decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
		if err != nil {
			t.Fatalf("cookie secret %q not RawURLEncoding-decodable: %v", s, err)
		}
		if n := len(decoded); n != 16 && n != 24 && n != 32 {
			t.Fatalf("cookie secret decodes to %d bytes, want 16/24/32", n)
		}
	}
}
