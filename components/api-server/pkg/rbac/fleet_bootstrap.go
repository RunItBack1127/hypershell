package rbac

import (
	"context"
)

type GatewayOwnerBindingCreator interface {
	CreateGatewayOwnerBinding(ctx context.Context, userID string, gatewayID string) error
}

type gatewayBootstrapper struct {
	rbCreator GatewayOwnerBindingCreator
}

func NewGatewayBootstrapper(rbCreator GatewayOwnerBindingCreator) *gatewayBootstrapper {
	return &gatewayBootstrapper{rbCreator: rbCreator}
}

func (b *gatewayBootstrapper) CreateOwnerBinding(ctx context.Context, userID string, gatewayID string) error {
	return b.rbCreator.CreateGatewayOwnerBinding(ctx, userID, gatewayID)
}

// GatewayOwnerResolver resolves the username of a gateway's owner from RBAC.
type GatewayOwnerResolver interface {
	FindOwnerUsernameByGatewayID(ctx context.Context, gatewayID string) (string, error)
}

type gatewayOwnerLookup struct {
	resolver GatewayOwnerResolver
}

func NewGatewayOwnerLookup(resolver GatewayOwnerResolver) *gatewayOwnerLookup {
	return &gatewayOwnerLookup{resolver: resolver}
}

func (l *gatewayOwnerLookup) FindOwnerUsername(ctx context.Context, gatewayID string) (string, error) {
	return l.resolver.FindOwnerUsernameByGatewayID(ctx, gatewayID)
}
