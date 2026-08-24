package gateways

import (
	"context"
	"fmt"
)

type PlacementResolver interface {
	Resolve(ctx context.Context, gateway *Gateway) error
}

type FleetLookup interface {
	FleetIDForCluster(ctx context.Context, clusterID string) (string, error)
	FindSoleFleet(ctx context.Context) (string, error)
}

type DatabaseLookup interface {
	FindSoleInFleet(ctx context.Context, fleetID string) (databaseID string, err error)
	FindSole(ctx context.Context) (databaseID string, fleetID string, err error)
}

type DatabaseCreator interface {
	CreateForGateway(ctx context.Context, gatewayName, fleetID string) (databaseID string, err error)
}

type cnpgPlacement struct {
	fleets FleetLookup
	dbs    DatabaseLookup
}

func NewCNPGPlacement(fleets FleetLookup, dbs DatabaseLookup) PlacementResolver {
	return &cnpgPlacement{fleets: fleets, dbs: dbs}
}

func (p *cnpgPlacement) Resolve(ctx context.Context, gw *Gateway) error {
	if err := resolveFleet(ctx, p.fleets, gw); err != nil {
		return err
	}
	if gw.DatabaseId != "" {
		return nil
	}
	if gw.FleetId != "" {
		dbID, err := p.dbs.FindSoleInFleet(ctx, gw.FleetId)
		if err != nil {
			return fmt.Errorf("resolve fleet database: %w", err)
		}
		if dbID == "" {
			return fmt.Errorf("database_id is required: fleet %s has zero or multiple ManagedDatabases", gw.FleetId)
		}
		gw.DatabaseId = dbID
		return nil
	}
	dbID, fleetID, err := p.dbs.FindSole(ctx)
	if err != nil {
		return fmt.Errorf("resolve database: %w", err)
	}
	if dbID == "" {
		return fmt.Errorf("database_id is required: zero or multiple ManagedDatabases exist")
	}
	gw.DatabaseId = dbID
	gw.FleetId = fleetID
	return nil
}

type deploymentPlacement struct {
	fleets FleetLookup
	dbs    DatabaseCreator
}

func NewDeploymentPlacement(fleets FleetLookup, dbs DatabaseCreator) PlacementResolver {
	return &deploymentPlacement{fleets: fleets, dbs: dbs}
}

func (p *deploymentPlacement) Resolve(ctx context.Context, gw *Gateway) error {
	if err := resolveFleet(ctx, p.fleets, gw); err != nil {
		return err
	}
	if gw.DatabaseId != "" {
		return nil
	}
	if gw.FleetId == "" {
		return fmt.Errorf("fleet_id is required for per-gateway database provisioning")
	}
	dbID, err := p.dbs.CreateForGateway(ctx, gw.Name, gw.FleetId)
	if err != nil {
		return fmt.Errorf("create per-gateway database: %w", err)
	}
	gw.DatabaseId = dbID
	return nil
}

func resolveFleet(ctx context.Context, fleets FleetLookup, gw *Gateway) error {
	if gw.FleetId != "" {
		return nil
	}
	if fleets == nil {
		return nil
	}
	if gw.ClusterId != "" {
		fid, err := fleets.FleetIDForCluster(ctx, gw.ClusterId)
		if err != nil {
			return fmt.Errorf("resolve fleet from cluster %s: %w", gw.ClusterId, err)
		}
		if fid == "" {
			return fmt.Errorf("cluster %s does not belong to a fleet", gw.ClusterId)
		}
		gw.FleetId = fid
		return nil
	}
	fid, err := fleets.FindSoleFleet(ctx)
	if err != nil {
		return fmt.Errorf("resolve fleet: %w", err)
	}
	gw.FleetId = fid
	return nil
}
