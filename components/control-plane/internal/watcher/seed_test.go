package watcher

import (
	"context"
	"errors"
	"testing"

	pb "github.com/openshift-online/hypershell/components/api-server/pkg/api/grpc/hypershell/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// fakeGatewayLister serves a fixed gateway inventory across paginated
// ListGateways calls so seedGateways can be exercised without a real API server.
type fakeGatewayLister struct {
	pb.GatewayServiceClient
	items    []*pb.Gateway
	pageSize int32
	err      error
	calls    int
	// getExtra holds gateways that exist but are deliberately absent from the
	// paginated list, to simulate pagination skew (a live gateway shifted past a
	// page boundary). getErr forces GetGateway to fail with a non-NotFound error,
	// simulating a transient confirmation failure.
	getExtra map[string]*pb.Gateway
	getErr   error
	getCalls int
}

// GetGateway confirms whether an id still exists. It returns any gateway in the
// listed inventory or in getExtra (present but list-omitted), a forced getErr if
// set, and NotFound otherwise -- so seedGateways can distinguish a truly-deleted
// gateway from one the paginated list merely skipped.
func (f *fakeGatewayLister) GetGateway(_ context.Context, in *pb.GetGatewayRequest, _ ...grpc.CallOption) (*pb.GetGatewayResponse, error) {
	f.getCalls++
	if f.getErr != nil {
		return nil, f.getErr
	}
	for _, g := range f.items {
		if g.GetMetadata().GetId() == in.Id {
			return &pb.GetGatewayResponse{Gateway: g}, nil
		}
	}
	if g, ok := f.getExtra[in.Id]; ok {
		return &pb.GetGatewayResponse{Gateway: g}, nil
	}
	return nil, status.Error(codes.NotFound, "gateway not found")
}

func (f *fakeGatewayLister) ListGateways(_ context.Context, in *pb.ListGatewaysRequest, _ ...grpc.CallOption) (*pb.ListGatewaysResponse, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	size := int(f.pageSize)
	if size == 0 {
		size = int(in.Size)
	}
	start := (int(in.Page) - 1) * size
	total := len(f.items)
	if start >= total {
		return &pb.ListGatewaysResponse{
			Metadata: &pb.ListMeta{Page: in.Page, Size: in.Size, Total: int32(total)},
		}, nil
	}
	end := start + size
	if end > total {
		end = total
	}
	return &pb.ListGatewaysResponse{
		Items:    f.items[start:end],
		Metadata: &pb.ListMeta{Page: in.Page, Size: in.Size, Total: int32(total)},
	}, nil
}

func gw(id, phase string) *pb.Gateway {
	g := &pb.Gateway{Metadata: &pb.ObjectReference{Id: id}}
	if phase != "" {
		g.Phase = &phase
	}
	return g
}

// recordingSink captures what seedGateways does: enqueued events, and the keys it
// prunes. Its known map seeds knownKeys so absence handling can be exercised.
type recordingSink struct {
	enqueued map[string]Event[*pb.Gateway]
	known    map[string]Event[*pb.Gateway]
	pruned   []string
}

func newRecordingSink(known map[string]Event[*pb.Gateway]) *recordingSink {
	return &recordingSink{enqueued: map[string]Event[*pb.Gateway]{}, known: known}
}

func (s *recordingSink) enqueue(ev Event[*pb.Gateway]) { s.enqueued[ev.ResourceID] = ev }

func (s *recordingSink) knownKeys() map[string]Event[*pb.Gateway] { return s.known }

func (s *recordingSink) prune(id string) {
	s.pruned = append(s.pruned, id)
	delete(s.known, id)
}

// seedGateways must enqueue every gateway (the LIST half of LIST-then-WATCH) and
// force only the active, gate-suppressed phases past the phase gate by clearing
// their phase -- so a restart re-drives a stranded Provisioning/Degraded gateway
// while healthy Running gateways are left to no-op at the gate (no re-provision
// flap), and unphased/Failed gateways reconcile normally.
func TestSeedGateways_ForcesActivePhasesOnly(t *testing.T) {
	lister := &fakeGatewayLister{items: []*pb.Gateway{
		gw("prov", "Provisioning"),
		gw("degraded", "Degraded"),
		gw("running", "Running"),
		gw("failed", "Failed"),
		gw("nophase", ""),
	}}

	sink := newRecordingSink(nil)
	err := seedGateways(context.Background(), lister, sink)
	if err != nil {
		t.Fatalf("seedGateways: %v", err)
	}
	got := sink.enqueued

	if len(got) != 5 {
		t.Fatalf("enqueued %d gateways, want all 5 seeded", len(got))
	}

	// Forced (recoverable) phases must have their phase cleared so the reconcile
	// bypasses the gate; the source payload must not be mutated.
	for _, id := range []string{"prov", "degraded"} {
		if got[id].Resource.GetPhase() != "" {
			t.Errorf("%s: phase = %q, want cleared (forced past gate)", id, got[id].Resource.GetPhase())
		}
	}
	// Non-forced gateways keep their phase (Running/Failed) or remain unphased.
	if got["running"].Resource.GetPhase() != "Running" {
		t.Errorf("running: phase = %q, want Running (not forced)", got["running"].Resource.GetPhase())
	}
	if got["failed"].Resource.GetPhase() != "Failed" {
		t.Errorf("failed: phase = %q, want Failed (not forced)", got["failed"].Resource.GetPhase())
	}

	// Seeding must not corrupt the shared inventory: clearGatewayPhaseForRetry
	// clones, so the lister's originals keep their phase.
	if lister.items[0].GetPhase() != "Provisioning" {
		t.Errorf("source gateway mutated: phase = %q, want Provisioning preserved", lister.items[0].GetPhase())
	}
}

// A gateway inventory larger than one page must be seeded in full.
func TestSeedGateways_Paginates(t *testing.T) {
	var items []*pb.Gateway
	for i := 0; i < gatewaySeedPageSize+7; i++ {
		items = append(items, gw(string(rune('a'+i%26))+string(rune(i)), "Running"))
	}
	lister := &fakeGatewayLister{items: items, pageSize: gatewaySeedPageSize}

	sink := newRecordingSink(nil)
	if err := seedGateways(context.Background(), lister, sink); err != nil {
		t.Fatalf("seedGateways: %v", err)
	}
	if count := len(sink.enqueued); count != len(items) {
		t.Fatalf("seeded %d gateways, want %d (all pages)", count, len(items))
	}
	if lister.calls < 2 {
		t.Fatalf("made %d list calls, want >= 2 (pagination)", lister.calls)
	}
}

// A list failure must propagate so watchLoop backs off and retries the seed,
// rather than proceeding to watch live traffic while recoverable gateways stay
// stranded.
func TestSeedGateways_ListErrorPropagates(t *testing.T) {
	lister := &fakeGatewayLister{err: errors.New("boom")}
	// A tracked key is present so we can assert a failed list never prunes: absence
	// is only trusted after a fully successful list.
	sink := newRecordingSink(map[string]Event[*pb.Gateway]{
		"gw-1": {Type: EventUpdated, ResourceID: "gw-1", Resource: gw("gw-1", "Provisioning")},
	})
	err := seedGateways(context.Background(), lister, sink)
	if err == nil {
		t.Fatal("want an error when ListGateways fails")
	}
	if len(sink.enqueued) != 0 {
		t.Fatalf("enqueued %d gateways on a failed list, want 0", len(sink.enqueued))
	}
	if len(sink.pruned) != 0 {
		t.Fatalf("pruned %v on a failed list, want none (absence not authoritative)", sink.pruned)
	}
}

// A gateway the queue is still tracking but that the authoritative list omits AND
// a point GetGateway confirms is gone (NotFound) was deleted while the stream was
// disconnected: its stale retry must be pruned so the queue stops driving desired
// state for a gateway that no longer exists. A pending delete for an absent
// gateway must be left alone so its teardown still runs.
func TestSeedGateways_PrunesAbsentTrackedGateways(t *testing.T) {
	lister := &fakeGatewayLister{items: []*pb.Gateway{gw("present", "Running")}}

	sink := newRecordingSink(map[string]Event[*pb.Gateway]{
		"present":       {Type: EventUpdated, ResourceID: "present", Resource: gw("present", "Running")},
		"deleted-stale": {Type: EventUpdated, ResourceID: "deleted-stale", Resource: gw("deleted-stale", "Provisioning")},
		"deleting":      {Type: EventDeleted, ResourceID: "deleting", Resource: gw("deleting", "Running")},
	})

	if err := seedGateways(context.Background(), lister, sink); err != nil {
		t.Fatalf("seedGateways: %v", err)
	}

	if len(sink.pruned) != 1 || sink.pruned[0] != "deleted-stale" {
		t.Fatalf("pruned %v, want exactly [deleted-stale]", sink.pruned)
	}
	// Absence was confirmed with a point read before pruning.
	if lister.getCalls != 1 {
		t.Errorf("GetGateway called %d times, want 1 (confirm the one absent id)", lister.getCalls)
	}
	// The still-present gateway is re-enqueued, never pruned.
	if _, ok := sink.enqueued["present"]; !ok {
		t.Fatal("present gateway should be re-enqueued by the seed")
	}
}

// Offset pagination is not a consistent snapshot: a concurrent create/delete can
// shift a still-live gateway across a page boundary so it is missing from the
// union of listed pages. Such a gateway must NOT be pruned -- a point GetGateway
// confirms it still exists, and pruning would cancel the only retry recovering a
// live gateway.
func TestSeedGateways_KeepsListOmittedButLiveGateway(t *testing.T) {
	lister := &fakeGatewayLister{
		items: []*pb.Gateway{gw("present", "Running")},
		// "shifted" exists but the paginated list skipped it (pagination skew). Its
		// current phase (Running) differs from the stale tracked payload below, so we
		// can prove the seed re-enqueues the payload GetGateway returned, not the old
		// tracked one.
		getExtra: map[string]*pb.Gateway{"shifted": gw("shifted", "Running")},
	}

	sink := newRecordingSink(map[string]Event[*pb.Gateway]{
		"present": {Type: EventUpdated, ResourceID: "present", Resource: gw("present", "Running")},
		"shifted": {Type: EventUpdated, ResourceID: "shifted", Resource: gw("shifted", "Provisioning")},
	})

	if err := seedGateways(context.Background(), lister, sink); err != nil {
		t.Fatalf("seedGateways: %v", err)
	}

	if len(sink.pruned) != 0 {
		t.Fatalf("pruned %v, want none (list-omitted gateway is still live)", sink.pruned)
	}
	if lister.getCalls != 1 {
		t.Errorf("GetGateway called %d times, want 1 (confirm the omitted id)", lister.getCalls)
	}
	// The confirmed-live gateway is re-seeded with the current payload GetGateway
	// returned (phase Running), not left as the stale tracked payload
	// (Provisioning): its spec may have changed while disconnected and the list
	// miss means no buffered watch event would correct it.
	got, ok := sink.enqueued["shifted"]
	if !ok {
		t.Fatal("confirmed-live gateway should be re-enqueued with its current state")
	}
	if got.Resource.GetPhase() != "Running" {
		t.Errorf("re-seeded phase = %q, want the current Running from GetGateway (not stale Provisioning)", got.Resource.GetPhase())
	}
}

// If the confirmation GetGateway itself fails with a non-NotFound error (e.g. a
// transient RPC failure), absence is unproven, so the tracked retry must be kept
// rather than pruned; a later seed reconfirms.
func TestSeedGateways_KeepsAbsentWhenConfirmFails(t *testing.T) {
	lister := &fakeGatewayLister{
		items:  []*pb.Gateway{gw("present", "Running")},
		getErr: status.Error(codes.Unavailable, "api server down"),
	}

	sink := newRecordingSink(map[string]Event[*pb.Gateway]{
		"present": {Type: EventUpdated, ResourceID: "present", Resource: gw("present", "Running")},
		"maybe":   {Type: EventUpdated, ResourceID: "maybe", Resource: gw("maybe", "Provisioning")},
	})

	if err := seedGateways(context.Background(), lister, sink); err != nil {
		t.Fatalf("seedGateways: %v", err)
	}

	if len(sink.pruned) != 0 {
		t.Fatalf("pruned %v, want none (absence unproven when confirmation fails)", sink.pruned)
	}
}
