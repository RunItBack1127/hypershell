package watcher

import (
	"context"
	"fmt"
	"io"
	"log"
	"time"

	pb "github.com/openshift-online/hypershell/components/api-server/pkg/api/grpc/hypershell/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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
	rq := newReconcileQueue(ctx, "Gateway", handler,
		withRetryTransform(clearGatewayPhaseForRetry),
		withVersion(gatewayEventVersion))
	defer rq.stop()
	return watchLoop(ctx, "Gateway", func(ctx context.Context) error {
		stream, err := client.WatchGateways(ctx, &pb.WatchGatewaysRequest{})
		if err != nil {
			return fmt.Errorf("starting gateway watch: %w", err)
		}
		// Wait for the stream header before seeding. Opening the stream is not a
		// subscription handshake: client.WatchGateways can return before the server
		// registers its broker subscription, so a seed issued immediately could
		// list state, then miss an event that fires before the subscription goes
		// live. The server flushes the header only after it has subscribed (see the
		// WatchGateways handler), so blocking on Header() closes that list-watch gap
		// -- every event after this point is captured by the watch, and the seed's
		// list captures everything before it. A one-shot seed per connect is then
		// sufficient; no periodic forced resync is needed (which would re-provision
		// gateways the health reconciler legitimately owns in an active phase).
		if _, err := stream.Header(); err != nil {
			return fmt.Errorf("awaiting gateway watch subscription header: %w", err)
		}
		// Seed the queue from the current inventory before processing live events.
		// The watch stream sends only future events and never replays existing
		// state on (re)connect, so this LIST is the only path that recovers a
		// gateway whose reconcile never completed -- e.g. one persisted at
		// Provisioning when the controller died before creating its workload or
		// recording a terminal phase. Returning on failure lets watchLoop back off
		// and retry the seed, rather than watch live traffic while recoverable
		// gateways stay stranded.
		if err := seedGateways(ctx, client, rq); err != nil {
			return err
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

// gatewayEventVersion returns a monotonically increasing version for a gateway
// event, taken from the resource's updated_at (the API server bumps it on every
// write and stamps it into both list and watch payloads). The reconcile queue
// uses it to coalesce to the newest observed state, so a stale seed/resync
// snapshot cannot clobber a newer live event. A missing resource or timestamp
// yields 0, degrading to plain last-writer-wins for that event.
func gatewayEventVersion(ev Event[*pb.Gateway]) int64 {
	return ev.Resource.GetMetadata().GetUpdatedAt().AsTime().UnixNano()
}

// gatewaySeedPageSize is the page size used when listing existing gateways to
// seed the reconcile queue. It matches the reconcilers' list page size so a
// typical fleet is covered in a single request.
const gatewaySeedPageSize = 500

// gatewaySeedSink is the subset of the reconcile queue that seedGateways drives:
// enqueue a gateway for reconciliation, snapshot the keys the queue still tracks,
// and prune a key whose resource no longer exists.
type gatewaySeedSink interface {
	enqueue(Event[*pb.Gateway])
	knownKeys() map[string]Event[*pb.Gateway]
	prune(id string)
}

// seedGateways lists the current gateway inventory and enqueues every gateway so
// a controller (re)start re-drives reconciles the watch stream will never replay.
// It is the LIST half of the standard controller LIST-then-WATCH pattern: without
// it, a gateway stranded mid-reconcile by a restart is only ever re-enqueued if
// its spec later changes.
//
// Gateways in a phase the reconciler's phase gate suppresses (Provisioning,
// Degraded) are seeded with the phase cleared -- the "forced retry for active
// phases" recovery needs -- so the reconcile actually runs instead of being
// skipped by the gate. Running gateways are seeded verbatim: their provisioning
// completed, so they hit the gate and no-op, avoiding a needless re-provision
// flap on every reconnect. Gateways with no phase (a create whose event was
// missed while the controller was down) or a terminal Failed phase already pass
// the gate, so they reconcile normally without forcing.
//
// The list is also authoritative for absence, but only after confirmation. A
// gateway the queue is still retrying but that the list omits may have been
// deleted while the stream was disconnected (its delete event was never
// replayed) -- or it may simply have been skipped by the paginated list, which
// is not a consistent snapshot: a concurrent create or delete shifts offsets, so
// a still-live gateway can slide across a page boundary and be missing from the
// union of pages. Pruning on list-absence alone would cancel that live gateway's
// only retry. So each omitted, still-tracked gateway is confirmed with a point
// GetGateway, and pruned only on a NotFound; any other outcome (it still exists,
// or the confirmation itself failed) leaves the retry in place. Cleanup of any
// orphaned namespace is left to the NamespaceGCReconciler, which rechecks
// liveness before it deletes -- safer than synthesizing a delete here. Absence is
// only trusted after a fully successful list: any page error aborts before
// pruning.
func seedGateways(ctx context.Context, client pb.GatewayServiceClient, sink gatewaySeedSink) error {
	listed := make(map[string]struct{})
	var seeded, forced int
	for page := int32(1); ; page++ {
		resp, err := client.ListGateways(ctx, &pb.ListGatewaysRequest{Page: page, Size: gatewaySeedPageSize})
		if err != nil {
			return fmt.Errorf("listing gateways to seed reconcile queue: %w", err)
		}
		items := resp.GetItems()
		for _, gw := range items {
			listed[gw.GetMetadata().GetId()] = struct{}{}
			if enqueueSeed(sink, gw) {
				forced++
			}
			seeded++
		}
		// Stop on the authoritative Total, or a short/empty page (defensive, so a
		// misreported Total cannot spin forever) -- mirrors listAllGateways.
		total := int(resp.GetMetadata().GetTotal())
		if len(items) == 0 || len(items) < gatewaySeedPageSize || (total > 0 && seeded >= total) {
			break
		}
	}

	// Prune tracked keys the authoritative list omits -- but confirm each first,
	// because offset pagination can omit a still-live gateway (see the doc comment).
	// A pending delete is left alone so its teardown still runs.
	var pruned int
	for id, ev := range sink.knownKeys() {
		if _, present := listed[id]; present || ev.Type == EventDeleted {
			continue
		}
		// The list omitted this tracked gateway; confirm it is truly gone with a
		// point read before dropping its retry.
		resp, err := client.GetGateway(ctx, &pb.GetGatewayRequest{Id: id})
		if err != nil {
			if status.Code(err) != codes.NotFound {
				// Confirmation failed for another reason (transient RPC error, etc.):
				// absence is unproven, so keep the retry; a later seed reconfirms.
				log.Printf("WARN could not confirm gateway %s absence during seed; keeping its retry: %v", id, err)
				continue
			}
			// NotFound: the gateway really is gone. Prune its stale retry.
			sink.prune(id)
			pruned++
			continue
		}
		// The gateway still exists; the paginated list just missed it. Re-seed it
		// with the payload GetGateway returned rather than leaving the tracked
		// entry untouched: its spec may have changed while the stream was
		// disconnected, and because the list missed it there is no buffered watch
		// event to correct a stale payload. Enqueuing the current state keeps the
		// reconcile driving the right desired state (and version-aware coalescing
		// discards it as a no-op if the tracked payload is already newer).
		enqueueSeed(sink, resp.GetGateway())
	}

	log.Printf("INFO seeded %d gateway(s) into reconcile queue on watch (re)connect (%d forced past the phase gate for recovery, %d absent retries pruned)", seeded, forced, pruned)
	return nil
}

// enqueueSeed enqueues one gateway as a seed event and reports whether it was
// forced past the phase gate. A gateway in a gate-suppressed active phase
// (Provisioning, Degraded) has its phase cleared -- the seed of such a gateway is
// exactly a forced retry of a reconcile a restart lost -- so the reconcile runs
// instead of being skipped by the gate. Every other phase is seeded verbatim.
func enqueueSeed(sink gatewaySeedSink, gw *pb.Gateway) (forced bool) {
	ev := Event[*pb.Gateway]{
		Type:       EventUpdated,
		ResourceID: gw.GetMetadata().GetId(),
		Resource:   gw,
	}
	if forceSeedRecovery(gw) {
		ev = clearGatewayPhaseForRetry(ev)
		forced = true
	}
	sink.enqueue(ev)
	return forced
}

// forceSeedRecovery reports whether a seeded gateway must bypass the phase gate
// to recover. Provisioning and Degraded denote reconciliation that never reached
// a healthy steady state, so a restart must re-drive them; the gate would
// otherwise skip these phases. Running is deliberately excluded so healthy
// gateways are not re-provisioned on every reconnect.
func forceSeedRecovery(gw *pb.Gateway) bool {
	switch gw.GetPhase() {
	case "Provisioning", "Degraded":
		return true
	default:
		return false
	}
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
		// Scope each attempt to its own cancelable context so the RPC -- and its
		// server-side broker subscription -- is torn down before we reconnect.
		// connectAndRecv can return while the stream is still healthy (e.g. a
		// post-header seed LIST failed), so relying on the stream erroring to end
		// the RPC would leak one subscription per reconnect. Any reconcile queue is
		// created on the parent ctx, not this per-attempt one, so pending retries
		// survive the reconnect.
		attemptCtx, cancel := context.WithCancel(ctx)
		err := connectAndRecv(attemptCtx)
		cancel()
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
