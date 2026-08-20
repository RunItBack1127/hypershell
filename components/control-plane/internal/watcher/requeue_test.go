package watcher

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"k8s.io/client-go/util/workqueue"
)

// recordingHandler records every payload it is invoked with and can fail the
// first failUntil calls, so tests can drive retry, coalescing, and serialization
// behavior. An optional block channel lets a test hold a call in-flight.
type recordingHandler struct {
	mu        sync.Mutex
	calls     int
	failUntil int
	seen      []string
	inFlight  int
	maxInFl   int
	enter     chan struct{}
	release   chan struct{}
	onCall    func() // invoked inside Handle, e.g. to simulate a self-status event
}

func (h *recordingHandler) Handle(_ context.Context, ev Event[string]) error {
	h.mu.Lock()
	h.calls++
	h.inFlight++
	if h.inFlight > h.maxInFl {
		h.maxInFl = h.inFlight
	}
	h.seen = append(h.seen, ev.Resource)
	fail := h.calls <= h.failUntil
	enter, release, onCall := h.enter, h.release, h.onCall
	h.mu.Unlock()

	if onCall != nil {
		onCall()
	}

	if enter != nil {
		enter <- struct{}{}
		<-release
	}

	h.mu.Lock()
	h.inFlight--
	h.mu.Unlock()

	if fail {
		return errors.New("boom")
	}
	return nil
}

func (h *recordingHandler) count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.calls
}

func (h *recordingHandler) lastSeen() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.seen) == 0 {
		return ""
	}
	return h.seen[len(h.seen)-1]
}

func (h *recordingHandler) maxConcurrent() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.maxInFl
}

// waitForCount polls until the handler has been invoked want times, failing the
// test if that does not happen within the deadline.
func waitForCount(t *testing.T, h *recordingHandler, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if h.count() >= want {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("handler called %d times, want >= %d", h.count(), want)
}

// fastLimiter is a short-backoff rate limiter so retry tests run quickly.
func fastLimiter() workqueue.TypedRateLimiter[string] {
	return workqueue.NewTypedItemExponentialFailureRateLimiter[string](time.Millisecond, 5*time.Millisecond)
}

// A reconcile that fails transiently must be retried until it succeeds, then stop
// -- this is the durable recovery the gateway watch stream cannot provide itself.
func TestReconcileQueue_RetriesUntilSuccess(t *testing.T) {
	h := &recordingHandler{failUntil: 2}
	q := newReconcileQueue(context.Background(), "Test", h,
		withRateLimiter[string](fastLimiter()), withWorkers[string](1))
	defer q.stop()

	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "v1"})

	waitForCount(t, h, 3) // 2 failures + 1 success
	time.Sleep(30 * time.Millisecond)
	if got := h.count(); got != 3 {
		t.Fatalf("handler called %d times, want exactly 3 (stops after success)", got)
	}
	if got := q.queue.NumRequeues("gw-1"); got != 0 {
		t.Fatalf("NumRequeues = %d, want 0 after success (Forget)", got)
	}
}

// A reconcile that keeps failing must be retried indefinitely (capped backoff),
// never abandoned after a fixed budget -- the watch stream does not replay state,
// so giving up would re-strand the gateway. This is the key fix over the previous
// finite-attempt requeuer.
func TestReconcileQueue_RetriesIndefinitely(t *testing.T) {
	h := &recordingHandler{failUntil: 1 << 30}
	q := newReconcileQueue(context.Background(), "Test", h,
		withRateLimiter[string](fastLimiter()), withWorkers[string](1))
	defer q.stop()

	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "v1"})

	// Far more than the old 8-attempt budget: proves retries do not stop.
	waitForCount(t, h, 20)
}

// The reconciler's own phase-status writes emit watch events that re-enqueue (and
// mark dirty) the key while it is being processed. client-go would then re-queue
// it for immediate handling on Done, bypassing the retry backoff and spinning --
// re-hammering the API server and Keycloak. The backoff floor must survive those
// dirty re-adds: a persistently failing key that re-enqueues itself on every call
// must still be handled at the backoff cadence, not in a tight loop.
func TestReconcileQueue_PreservesBackoffAgainstDirtyReadds(t *testing.T) {
	h := &recordingHandler{failUntil: 1 << 30}
	// base 25ms backoff; a spin would produce hundreds of calls in the window below.
	limiter := workqueue.NewTypedItemExponentialFailureRateLimiter[string](25*time.Millisecond, 50*time.Millisecond)
	q := newReconcileQueue(context.Background(), "Test", h,
		withRateLimiter[string](limiter), withWorkers[string](1))
	defer q.stop()
	// Each Handle re-enqueues the same key, simulating the reconciler's self-status
	// write marking the key dirty during processing.
	h.mu.Lock()
	h.onCall = func() { q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "v1"}) }
	h.mu.Unlock()

	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "v1"})

	time.Sleep(200 * time.Millisecond)
	// ~200ms / 25-50ms backoff => a handful of calls. Well under any spin, but more
	// than one (proves it still retries).
	got := h.count()
	if got < 2 {
		t.Fatalf("handler called %d times, want >= 2 (must keep retrying)", got)
	}
	if got > 15 {
		t.Fatalf("handler called %d times in 200ms: backoff bypassed by dirty re-adds (spin)", got)
	}
}

// Version-aware coalescing must keep the newest observed payload regardless of
// enqueue order: a stale seed/resync snapshot (lower version) must not clobber a
// newer live event, and a buffered out-of-order live event must not clobber a
// newer seed. This is what lets a one-shot seed coexist with live traffic.
func TestReconcileQueue_VersionCoalescingKeepsNewest(t *testing.T) {
	h := &recordingHandler{
		enter:   make(chan struct{}),
		release: make(chan struct{}),
	}
	version := func(ev Event[string]) int64 {
		v := map[string]int64{"old": 1, "new": 2}
		return v[ev.Resource]
	}
	q := newReconcileQueue(context.Background(), "Test", h,
		withRateLimiter[string](fastLimiter()), withWorkers[string](1),
		withVersion(version))
	defer q.stop()

	// Hold a first reconcile in-flight so later enqueues coalesce into latest.
	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "new"})
	<-h.enter
	// A stale snapshot (lower version) arrives while the newer payload is pending.
	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "old"})
	h.release <- struct{}{} // first reconcile ("new") completes

	// If a second reconcile runs at all, it must not be the stale "old" payload.
	select {
	case <-h.enter:
		got := h.lastSeen()
		h.release <- struct{}{}
		if got == "old" {
			t.Fatalf("reconciled stale payload %q; version coalescing must keep the newest", got)
		}
	case <-time.After(50 * time.Millisecond):
		// No second reconcile: the stale enqueue was dropped entirely. Correct.
	}
}

// A pending (not-yet-processed) delete is terminal: a non-delete event -- e.g. a
// stale seed snapshot or a buffered out-of-order live update -- must not overwrite
// it and resurrect a resource whose deletion has not been reconciled.
func TestReconcileQueue_PendingDeleteNotResurrected(t *testing.T) {
	h := &recordingHandler{
		enter:   make(chan struct{}),
		release: make(chan struct{}),
	}
	version := func(ev Event[string]) int64 {
		// The resurrecting update even claims a *higher* version, to prove the delete
		// wins on type, not on version.
		if ev.Resource == "resurrect" {
			return 100
		}
		return 1
	}
	q := newReconcileQueue(context.Background(), "Test", h,
		withRateLimiter[string](fastLimiter()), withWorkers[string](1),
		withVersion(version))
	defer q.stop()

	// Occupy the single worker so the delete stays pending in latest while the
	// resurrecting update is enqueued.
	q.enqueue(Event[string]{ResourceID: "blocker", Resource: "x"})
	<-h.enter

	q.enqueue(Event[string]{Type: EventDeleted, ResourceID: "gw-1", Resource: "gone"})
	q.enqueue(Event[string]{Type: EventUpdated, ResourceID: "gw-1", Resource: "resurrect"})

	// The pending payload for gw-1 must still be the delete.
	q.mu.Lock()
	got := q.latest["gw-1"]
	q.mu.Unlock()
	if got.Type != EventDeleted {
		t.Fatalf("gw-1 pending event = %v (%q), want the delete to stay terminal", got.Type, got.Resource)
	}

	h.release <- struct{}{} // release blocker
	// Drain any remaining processing so stop() is clean.
	go func() {
		for {
			select {
			case <-h.enter:
				h.release <- struct{}{}
			case <-time.After(100 * time.Millisecond):
				return
			}
		}
	}()
	time.Sleep(120 * time.Millisecond)
}

// A retry must reconcile the latest observed payload, not the one that failed:
// coalescing to newest desired state is what prevents a stale (e.g. still-routed)
// payload from being replayed after the resource changed.
func TestReconcileQueue_CoalescesToLatestPayload(t *testing.T) {
	h := &recordingHandler{
		failUntil: 1, // fail the first attempt so a retry happens
		enter:     make(chan struct{}),
		release:   make(chan struct{}),
	}
	q := newReconcileQueue(context.Background(), "Test", h,
		withRateLimiter[string](fastLimiter()), withWorkers[string](1))
	defer q.stop()

	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "v1"})

	<-h.enter // first attempt is in-flight with "v1"
	// A newer event arrives while the first attempt runs.
	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "v2"})
	h.release <- struct{}{} // first attempt fails -> requeued

	<-h.enter // retry is in-flight; it must carry the latest payload
	got := h.lastSeen()
	h.release <- struct{}{}
	if got != "v2" {
		t.Fatalf("retry reconciled %q, want the latest payload %q", got, "v2")
	}
}

// The retry transform must be applied only to retries, never to the first attempt,
// so ordinary create/update traffic is reconciled verbatim while recovery gets the
// adjusted (e.g. phase-cleared) payload.
func TestReconcileQueue_RetryTransformOnlyOnRetry(t *testing.T) {
	h := &recordingHandler{failUntil: 1} // first attempt fails, forcing one retry
	transform := func(ev Event[string]) Event[string] {
		ev.Resource = "transformed"
		return ev
	}
	q := newReconcileQueue(context.Background(), "Test", h,
		withRateLimiter[string](fastLimiter()), withWorkers[string](1),
		withRetryTransform(transform))
	defer q.stop()

	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "original"})

	waitForCount(t, h, 2)
	time.Sleep(20 * time.Millisecond)

	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.seen) < 2 {
		t.Fatalf("want at least 2 calls, got %d", len(h.seen))
	}
	if h.seen[0] != "original" {
		t.Fatalf("first attempt saw %q, want the untransformed %q", h.seen[0], "original")
	}
	if h.seen[1] != "transformed" {
		t.Fatalf("retry saw %q, want the transformed payload", h.seen[1])
	}
}

// The queue must never run two reconciles for the same resource concurrently, so a
// retry can never race a live event for that resource.
func TestReconcileQueue_SerializesPerResource(t *testing.T) {
	h := &recordingHandler{
		enter:   make(chan struct{}),
		release: make(chan struct{}),
	}
	q := newReconcileQueue(context.Background(), "Test", h,
		withRateLimiter[string](fastLimiter()), withWorkers[string](4))
	defer q.stop()

	// Two events for the same key; with 4 workers they could run concurrently if the
	// queue did not serialize per key.
	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "a"})
	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "b"})

	<-h.enter
	h.release <- struct{}{}
	// A second processing happens only if a newer payload coalesced in; drain it if
	// present so stop() is clean.
	select {
	case <-h.enter:
		h.release <- struct{}{}
	case <-time.After(50 * time.Millisecond):
	}

	if got := h.maxConcurrent(); got > 1 {
		t.Fatalf("max concurrent reconciles for one key = %d, want 1", got)
	}
}

// stop must drain the workers and return, after which no further reconciles run.
func TestReconcileQueue_StopDrainsWorkers(t *testing.T) {
	h := &recordingHandler{}
	q := newReconcileQueue(context.Background(), "Test", h,
		withRateLimiter[string](fastLimiter()), withWorkers[string](2))

	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "v1"})
	waitForCount(t, h, 1)
	q.stop()

	before := h.count()
	q.enqueue(Event[string]{ResourceID: "gw-2", Resource: "v1"}) // ignored: queue shut down
	time.Sleep(20 * time.Millisecond)
	if got := h.count(); got != before {
		t.Fatalf("handler called %d times after stop, want %d (no work after shutdown)", got, before)
	}
}

// Canceling the watcher context must shut the queue down even without an explicit
// stop, so workers never leak past the watcher's lifetime.
func TestReconcileQueue_ContextCancelShutsDown(t *testing.T) {
	h := &recordingHandler{}
	ctx, cancel := context.WithCancel(context.Background())
	q := newReconcileQueue(ctx, "Test", h,
		withRateLimiter[string](fastLimiter()), withWorkers[string](2))

	q.enqueue(Event[string]{ResourceID: "gw-1", Resource: "v1"})
	waitForCount(t, h, 1)

	cancel()
	// stop should return promptly because the context watcher already shut the queue
	// down; a leaked worker would hang this.
	done := make(chan struct{})
	go func() { q.stop(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stop did not return after context cancel; workers leaked")
	}
}
