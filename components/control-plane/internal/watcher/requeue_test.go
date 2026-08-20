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
	enter, release := h.enter, h.release
	h.mu.Unlock()

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
