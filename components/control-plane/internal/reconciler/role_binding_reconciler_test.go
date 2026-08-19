package reconciler

import "testing"

// A gateway owner must receive BOTH openshell-admin and openshell-user on the
// per-gateway console client. The gateway admin API enforces the two roles
// independently (admin does not imply user), so an owner missing openshell-user
// can read gateway info but is refused "list workspaces" with
// "role 'openshell-user' required". A viewer receives only openshell-user.
func TestKeycloakRoleMap_OwnerGetsAdminAndUser(t *testing.T) {
	cases := []struct {
		roleBinding string
		want        []string
	}{
		{"gateway:owner", []string{"openshell-admin", "openshell-user"}},
		{"gateway:viewer", []string{"openshell-user"}},
	}
	for _, tc := range cases {
		got, ok := keycloakRoleMap[tc.roleBinding]
		if !ok {
			t.Fatalf("keycloakRoleMap missing mapping for %q", tc.roleBinding)
		}
		if len(got) != len(tc.want) {
			t.Fatalf("keycloakRoleMap[%q] = %v, want %v", tc.roleBinding, got, tc.want)
		}
		for i, role := range tc.want {
			if got[i] != role {
				t.Errorf("keycloakRoleMap[%q][%d] = %q, want %q", tc.roleBinding, i, got[i], role)
			}
		}
	}
}
