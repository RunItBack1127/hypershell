package keycloak

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

const (
	testRealm            = "test-realm"
	testAdminClientID    = "admin-cli"
	testAdminSecret      = "admin-secret"
	testConsoleClientID  = "my-console"
	testGatewayClientID  = "my-gateway"
	testRedirectURI      = "https://console.example.com/callback"
	testWebOrigin        = "https://console.example.com"
	testFakeUUID         = "aaaabbbb-cccc-dddd-eeee-ffffffffffff"
	testFakeSecret       = "test-secret"
)

// capturedMapper holds request bodies sent to the protocol-mappers endpoint.
type capturedMapper struct {
	Name   string                 `json:"name"`
	Config map[string]interface{} `json:"config"`
}

func newFakeKeycloak(t *testing.T) (*httptest.Server, *[]capturedMapper) {
	t.Helper()
	var mu sync.Mutex
	var mappers []capturedMapper

	mux := http.NewServeMux()

	// Token endpoint
	tokenPath := fmt.Sprintf("/realms/%s/protocol/openid-connect/token", testRealm)
	mux.HandleFunc(tokenPath, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"access_token": "fake-token",
			"expires_in":   300,
		})
	})

	// Create client endpoint -- returns 201 with Location header
	clientsPath := fmt.Sprintf("/admin/realms/%s/clients", testRealm)
	mux.HandleFunc(clientsPath, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			w.Header().Set("Location", fmt.Sprintf("/admin/realms/%s/clients/%s", testRealm, testFakeUUID))
			w.WriteHeader(http.StatusCreated)
		case http.MethodGet:
			// Return an empty list (used by getClientUUID for delete flows)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode([]keycloakClient{})
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})

	// Protocol mappers endpoint
	mappersPath := fmt.Sprintf("/admin/realms/%s/clients/%s/protocol-mappers/models", testRealm, testFakeUUID)
	mux.HandleFunc(mappersPath, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		body, _ := io.ReadAll(r.Body)
		var m capturedMapper
		if err := json.Unmarshal(body, &m); err == nil {
			mu.Lock()
			mappers = append(mappers, m)
			mu.Unlock()
		}
		w.WriteHeader(http.StatusCreated)
	})

	// Client secret endpoint
	secretPath := fmt.Sprintf("/admin/realms/%s/clients/%s/client-secret", testRealm, testFakeUUID)
	mux.HandleFunc(secretPath, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"value": testFakeSecret})
	})

	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, &mappers
}

func TestProvisionConsoleClient_HappyPath(t *testing.T) {
	srv, captured := newFakeKeycloak(t)

	kc := NewClient(srv.URL, testRealm, testAdminClientID, testAdminSecret)

	uuid, secret, err := kc.ProvisionConsoleClient(
		t.Context(),
		testConsoleClientID,
		testGatewayClientID,
		testRedirectURI,
		testWebOrigin,
	)
	if err != nil {
		t.Fatalf("ProvisionConsoleClient: unexpected error: %v", err)
	}
	if uuid != testFakeUUID {
		t.Errorf("uuid: got %q, want %q", uuid, testFakeUUID)
	}
	if secret != testFakeSecret {
		t.Errorf("secret: got %q, want %q", secret, testFakeSecret)
	}

	// Verify that both audience and client-roles mappers use the GATEWAY client id.
	mappers := *captured
	if len(mappers) != 3 {
		t.Fatalf("expected 3 protocol mappers, got %d", len(mappers))
	}

	for _, m := range mappers {
		switch m.Name {
		case "audience":
			aud, _ := m.Config["included.client.audience"].(string)
			if aud != testGatewayClientID {
				t.Errorf("audience mapper: included.client.audience = %q, want %q", aud, testGatewayClientID)
			}
			if strings.Contains(aud, testConsoleClientID) {
				t.Errorf("audience mapper must NOT reference console client, got %q", aud)
			}
		case "client-roles":
			clientRef, _ := m.Config["usermodel.clientRoleMapping.clientId"].(string)
			if clientRef != testGatewayClientID {
				t.Errorf("client-roles mapper: usermodel.clientRoleMapping.clientId = %q, want %q", clientRef, testGatewayClientID)
			}
			if strings.Contains(clientRef, testConsoleClientID) {
				t.Errorf("client-roles mapper must NOT reference console client, got %q", clientRef)
			}
		case "sub":
			// nothing extra to assert
		default:
			t.Errorf("unexpected mapper name: %q", m.Name)
		}
	}
}

func TestDeleteConsoleClient_NotFound(t *testing.T) {
	srv, _ := newFakeKeycloak(t)
	kc := NewClient(srv.URL, testRealm, testAdminClientID, testAdminSecret)

	// The fake server returns an empty client list, so delete should be a no-op.
	if err := kc.DeleteConsoleClient(t.Context(), testConsoleClientID); err != nil {
		t.Fatalf("DeleteConsoleClient: unexpected error: %v", err)
	}
}
