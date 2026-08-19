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
	testRealm           = "test-realm"
	testAdminClientID   = "admin-cli"
	testAdminSecret     = "admin-secret"
	testConsoleClientID = "my-console"
	testGatewayClientID = "my-gateway"
	testRedirectURI     = "https://console.example.com/callback"
	testWebOrigin       = "https://console.example.com"
	testFakeUUID        = "aaaabbbb-cccc-dddd-eeee-ffffffffffff"
	testGatewayUUID     = "11112222-3333-4444-5555-666677778888"
	testFakeSecret      = "test-secret"
)

// capturedMapper holds request bodies sent to the protocol-mappers endpoint.
type capturedMapper struct {
	Name   string                 `json:"name"`
	Config map[string]interface{} `json:"config"`
}

// fakeKeycloak records the mappers and scope-mapping grants the client sends.
type fakeKeycloak struct {
	mappers     []capturedMapper
	scopeMapped []keycloakRole // roles POSTed to the console client's scope-mappings
}

func newFakeKeycloak(t *testing.T) (*httptest.Server, *fakeKeycloak) {
	t.Helper()
	var mu sync.Mutex
	state := &fakeKeycloak{}

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
			// getClientUUID resolves the gateway client (for scope mappings);
			// every other clientId (e.g. the console client during delete
			// flows) resolves to an empty list.
			w.Header().Set("Content-Type", "application/json")
			if r.URL.Query().Get("clientId") == testGatewayClientID {
				_ = json.NewEncoder(w).Encode([]keycloakClient{
					{ID: testGatewayUUID, ClientID: testGatewayClientID},
				})
				return
			}
			_ = json.NewEncoder(w).Encode([]keycloakClient{})
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})

	// Gateway client roles endpoint -- source roles for the scope-mapping grant.
	rolesPath := fmt.Sprintf("/admin/realms/%s/clients/%s/roles", testRealm, testGatewayUUID)
	mux.HandleFunc(rolesPath, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode([]keycloakRole{
			{ID: "role-admin-uuid", Name: "openshell-admin"},
			{ID: "role-user-uuid", Name: "openshell-user"},
		})
	})

	// Console client scope-mappings endpoint -- grants the gateway roles into
	// the console client's scope so fullScopeAllowed=false does not strip them.
	scopePath := fmt.Sprintf("/admin/realms/%s/clients/%s/scope-mappings/clients/%s", testRealm, testFakeUUID, testGatewayUUID)
	mux.HandleFunc(scopePath, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		body, _ := io.ReadAll(r.Body)
		var roles []keycloakRole
		if err := json.Unmarshal(body, &roles); err == nil {
			mu.Lock()
			state.scopeMapped = append(state.scopeMapped, roles...)
			mu.Unlock()
		}
		w.WriteHeader(http.StatusNoContent)
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
			state.mappers = append(state.mappers, m)
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
	return srv, state
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

	// The console client must be granted scope for the gateway client's roles,
	// or Keycloak (fullScopeAllowed=false) strips hypershell.roles from the token
	// and the gateway denies every request.
	gotScope := make(map[string]bool)
	for _, role := range captured.scopeMapped {
		gotScope[role.Name] = true
	}
	for _, want := range []string{"openshell-admin", "openshell-user"} {
		if !gotScope[want] {
			t.Errorf("expected scope mapping to grant gateway role %q, got %v", want, captured.scopeMapped)
		}
	}

	// Verify that both audience and client-roles mappers use the GATEWAY client id.
	mappers := captured.mappers
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
