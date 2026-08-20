package gateways

import (
	"context"
	"testing"

	daomocks "github.com/openshift-online/rh-trex-ai/pkg/dao/mocks"
	"github.com/openshift-online/rh-trex-ai/pkg/services"
)

type databaseFinderStub struct {
	databaseID string
	fleetID    string
}

func (f databaseFinderStub) FindSoleInFleet(context.Context, string) (string, error) {
	return f.databaseID, nil
}

func (f databaseFinderStub) FindSole(context.Context) (string, string, error) {
	return f.databaseID, f.fleetID, nil
}

func TestCreateFallsBackWhenNoSoleManagedDatabaseExists(t *testing.T) {
	service := NewGatewayService(
		nil,
		NewMockGatewayDao(),
		services.NewEventService(daomocks.NewEventDao()),
		databaseFinderStub{},
		nil,
	)

	created, serviceErr := service.Create(context.Background(), &Gateway{Name: "fallback"})
	if serviceErr != nil {
		t.Fatalf("create gateway without a sole ManagedDatabase: %v", serviceErr)
	}
	if created.DatabaseId != "" {
		t.Fatalf("database_id = %q, want blank fallback assignment", created.DatabaseId)
	}
}

func TestCreateStillAutoAssignsSoleManagedDatabase(t *testing.T) {
	service := NewGatewayService(
		nil,
		NewMockGatewayDao(),
		services.NewEventService(daomocks.NewEventDao()),
		databaseFinderStub{databaseID: "managed-db", fleetID: "fleet-a"},
		nil,
	)

	created, serviceErr := service.Create(context.Background(), &Gateway{Name: "cnpg"})
	if serviceErr != nil {
		t.Fatalf("create gateway with a sole ManagedDatabase: %v", serviceErr)
	}
	if created.DatabaseId != "managed-db" || created.FleetId != "fleet-a" {
		t.Fatalf("assignment = database:%q fleet:%q", created.DatabaseId, created.FleetId)
	}
}
