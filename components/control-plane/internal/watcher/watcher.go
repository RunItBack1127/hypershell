package watcher

import (
	"context"
	"fmt"
	"io"
	"log"
	"time"

	pb "github.com/openshift-online/hypershell/components/api-server/pkg/api/grpc/hypershell/v1"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
)

type EventType int

const (
	EventCreated EventType = iota
	EventUpdated
	EventDeleted
)

type Event[T any] struct {
	Type       EventType
	ResourceID string
	Resource   T
}

type Handler[T any] interface {
	Handle(ctx context.Context, event Event[T]) error
}

func toEventType(t pb.EventType) EventType {
	switch t {
	case pb.EventType_EVENT_TYPE_CREATED:
		return EventCreated
	case pb.EventType_EVENT_TYPE_UPDATED:
		return EventUpdated
	case pb.EventType_EVENT_TYPE_DELETED:
		return EventDeleted
	default:
		return EventCreated
	}
}

func WatchFleets(ctx context.Context, conn *grpc.ClientConn, handler Handler[*pb.Fleet]) error {
	client := pb.NewFleetServiceClient(conn)
	return watchLoop(ctx, "Fleet", func(ctx context.Context) error {
		stream, err := client.WatchFleets(ctx, &pb.WatchFleetsRequest{})
		if err != nil {
			return fmt.Errorf("starting fleet watch: %w", err)
		}
		for {
			event, err := stream.Recv()
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return fmt.Errorf("receiving fleet event: %w", err)
			}
			if err := handler.Handle(ctx, Event[*pb.Fleet]{
				Type:       toEventType(event.Type),
				ResourceID: event.ResourceId,
				Resource:   event.Fleet,
			}); err != nil {
				log.Printf("ERROR handling fleet %s: %v", event.ResourceId, err)
			}
		}
	})
}

func WatchManagedClusters(ctx context.Context, conn *grpc.ClientConn, handler Handler[*pb.ManagedCluster]) error {
	client := pb.NewManagedClusterServiceClient(conn)
	return watchLoop(ctx, "ManagedCluster", func(ctx context.Context) error {
		stream, err := client.WatchManagedClusters(ctx, &pb.WatchManagedClustersRequest{})
		if err != nil {
			return fmt.Errorf("starting managed cluster watch: %w", err)
		}
		for {
			event, err := stream.Recv()
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return fmt.Errorf("receiving managed cluster event: %w", err)
			}
			if err := handler.Handle(ctx, Event[*pb.ManagedCluster]{
				Type:       toEventType(event.Type),
				ResourceID: event.ResourceId,
				Resource:   event.ManagedCluster,
			}); err != nil {
				log.Printf("ERROR handling managed cluster %s: %v", event.ResourceId, err)
			}
		}
	})
}

func WatchManagedDatabases(ctx context.Context, conn *grpc.ClientConn, handler Handler[*pb.ManagedDatabase]) error {
	client := pb.NewManagedDatabaseServiceClient(conn)
	return watchLoop(ctx, "ManagedDatabase", func(ctx context.Context) error {
		stream, err := client.WatchManagedDatabases(ctx, &pb.WatchManagedDatabasesRequest{})
		if err != nil {
			return fmt.Errorf("starting managed database watch: %w", err)
		}
		for {
			event, err := stream.Recv()
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return fmt.Errorf("receiving managed database event: %w", err)
			}
			if err := handler.Handle(ctx, Event[*pb.ManagedDatabase]{
				Type:       toEventType(event.Type),
				ResourceID: event.ResourceId,
				Resource:   event.ManagedDatabase,
			}); err != nil {
				log.Printf("ERROR handling managed database %s: %v", event.ResourceId, err)
			}
		}
	})
}

func WatchGatewayReleases(ctx context.Context, conn *grpc.ClientConn, handler Handler[*pb.GatewayRelease]) error {
	client := pb.NewGatewayReleaseServiceClient(conn)
	return watchLoop(ctx, "GatewayRelease", func(ctx context.Context) error {
		stream, err := client.WatchGatewayReleases(ctx, &pb.WatchGatewayReleasesRequest{})
		if err != nil {
			return fmt.Errorf("starting gateway release watch: %w", err)
		}
		for {
			event, err := stream.Recv()
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return fmt.Errorf("receiving gateway release event: %w", err)
			}
			if err := handler.Handle(ctx, Event[*pb.GatewayRelease]{
				Type:       toEventType(event.Type),
				ResourceID: event.ResourceId,
				Resource:   event.GatewayRelease,
			}); err != nil {
				log.Printf("ERROR handling gateway release %s: %v", event.ResourceId, err)
			}
		}
	})
}

func WatchGateways(ctx context.Context, conn *grpc.ClientConn, handler Handler[*pb.Gateway]) error {
	client := pb.NewGatewayServiceClient(conn)
	// Gateway reconciliation is driven through a per-resource reconcile queue rather
	// than invoked inline: the watch stream does not replay state on reconnect, so a
	// reconcile that fails (e.g. an API-server outage that also blocks recording a
	// Failed phase) would otherwise strand the gateway until its spec next changes.
	// The queue serializes work per gateway, coalesces to the latest observed state,
	// and retries failures indefinitely with capped backoff -- all on the watcher
	// lifetime context so recovery survives a stream reconnect.
	rq := newReconcileQueue(ctx, "Gateway", handler, withRetryTransform(clearGatewayPhaseForRetry))
	defer rq.stop()
	return watchLoop(ctx, "Gateway", func(ctx context.Context) error {
		stream, err := client.WatchGateways(ctx, &pb.WatchGatewaysRequest{})
		if err != nil {
			return fmt.Errorf("starting gateway watch: %w", err)
		}
		for {
			event, err := stream.Recv()
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return fmt.Errorf("receiving gateway event: %w", err)
			}
			rq.enqueue(Event[*pb.Gateway]{
				Type:       toEventType(event.Type),
				ResourceID: event.ResourceId,
				Resource:   event.Gateway,
			})
		}
	})
}

// clearGatewayPhaseForRetry returns the event with the Gateway's phase cleared so
// a recovery retry bypasses the reconciler's phase gate. The reconciler stamps
// phase=Provisioning before it does the provisioning work, and that DB write emits
// a watch event that coalesces into the queue's latest payload; a retry that
// reused it verbatim would hit the phase gate (Provisioning => skip) and silently
// no-op, re-stranding a gateway whose original provisioning failed before it could
// record a terminal phase. Clearing the phase -- and only on retries -- restores
// the gate-bypassing recovery the watch stream cannot provide, while the rest of
// the payload still reflects the latest observed spec so an un-routed gateway is
// torn down, not resurrected. proto.Clone avoids mutating the shared latest entry
// (and copying the message value, which vet forbids).
func clearGatewayPhaseForRetry(ev Event[*pb.Gateway]) Event[*pb.Gateway] {
	if ev.Resource == nil {
		return ev
	}
	clone := proto.Clone(ev.Resource).(*pb.Gateway)
	clone.Phase = nil
	ev.Resource = clone
	return ev
}

func WatchGatewayNetworks(ctx context.Context, conn *grpc.ClientConn, handler Handler[*pb.GatewayNetwork]) error {
	client := pb.NewGatewayNetworkServiceClient(conn)
	return watchLoop(ctx, "GatewayNetwork", func(ctx context.Context) error {
		stream, err := client.WatchGatewayNetworks(ctx, &pb.WatchGatewayNetworksRequest{})
		if err != nil {
			return fmt.Errorf("starting gateway network watch: %w", err)
		}
		for {
			event, err := stream.Recv()
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return fmt.Errorf("receiving gateway network event: %w", err)
			}
			if err := handler.Handle(ctx, Event[*pb.GatewayNetwork]{
				Type:       toEventType(event.Type),
				ResourceID: event.ResourceId,
				Resource:   event.GatewayNetwork,
			}); err != nil {
				log.Printf("ERROR handling gateway network %s: %v", event.ResourceId, err)
			}
		}
	})
}

func WatchRoleBindings(ctx context.Context, conn *grpc.ClientConn, handler Handler[*pb.RoleBinding]) error {
	client := pb.NewRoleBindingServiceClient(conn)
	return watchLoop(ctx, "RoleBinding", func(ctx context.Context) error {
		stream, err := client.WatchRoleBindings(ctx, &pb.WatchRoleBindingsRequest{})
		if err != nil {
			return fmt.Errorf("starting role binding watch: %w", err)
		}
		for {
			event, err := stream.Recv()
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return fmt.Errorf("receiving role binding event: %w", err)
			}
			if err := handler.Handle(ctx, Event[*pb.RoleBinding]{
				Type:       toEventType(event.Type),
				ResourceID: event.ResourceId,
				Resource:   event.RoleBinding,
			}); err != nil {
				log.Printf("ERROR handling role binding %s: %v", event.ResourceId, err)
			}
		}
	})
}

func watchLoop(ctx context.Context, kind string, connectAndRecv func(ctx context.Context) error) error {
	backoff := time.Second
	maxBackoff := 30 * time.Second

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		log.Printf("INFO connecting %s watch stream...", kind)
		err := connectAndRecv(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}

		log.Printf("WARN %s watch stream disconnected: %v; reconnecting in %v", kind, err, backoff)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}

		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}
