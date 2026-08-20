package watcher

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// countingHandler records how many times Handle was invoked and fails the first
// failUntil calls, so tests can drive the backoff to success or exhaustion.
type countingHandler struct {
	mu        sync.Mutex
	calls     int
	failUntil int
}

func (h *countingHandler) Handle(context.Context, Event[string]) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.calls++
	if h.calls <= h.failUntil {
		return errors.New("boom")
	}
	return nil
}

func (h *countingHandler) count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.calls
}

// waitForCount polls until the handler has been invoked want times, failing the
// test if that does not happen within the deadline.
func waitForCount(t *testing.T, h *countingHandler, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if h.count() >= want {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("handler called %d times, want %d", h.count(), want)
}

func newTestRequeuer(ctx context.Context, h Handler[string], attempts int, base time.Duration) *requeuer[string] {
	q := newRequeuer(ctx, "Test", h)
	q.attempts = attempts
	q.base = base
	q.max = base
	return q
}

// A reconcile that fails transiently must be retried until it succeeds, then stop
// -- this is the durable recovery the gateway watch stream cannot provide itself.
func TestRequeuer_RetriesUntilSuccess(t *testing.T) {
	h := &countingHandler{failUntil: 2}
	q := newTestRequeuer(context.Background(), h, 8, time.Millisecond)
	defer q.stop()

	q.schedule(Event[string]{ResourceID: "gw-1"})

	waitForCount(t, h, 3) // 2 failures + 1 success
	time.Sleep(20 * time.Millisecond)
	if got := h.count(); got != 3 {
		t.Fatalf("handler called %d times, want exactly 3 (stops after success)", got)
	}
	if q.pendingLen() != 0 {
		t.Fatalf("pending retries = %d, want 0 after success", q.pendingLen())
	}
}

// A reconcile that keeps failing must stop after the attempt budget rather than
// retrying forever, so a genuinely broken gateway cannot spin indefinitely.
func TestRequeuer_StopsAfterMaxAttempts(t *testing.T) {
	h := &countingHandler{failUntil: 1000}
	q := newTestRequeuer(context.Background(), h, 3, time.Millisecond)
	defer q.stop()

	q.schedule(Event[string]{ResourceID: "gw-1"})

	waitForCount(t, h, 3)
	time.Sleep(20 * time.Millisecond)
	if got := h.count(); got != 3 {
		t.Fatalf("handler called %d times, want exactly 3 (attempt budget)", got)
	}
	if q.pendingLen() != 0 {
		t.Fatalf("pending retries = %d, want 0 after exhaustion", q.pendingLen())
	}
}

// A fresh successful event supersedes a pending retry: canceling before the first
// backoff elapses must prevent the handler from ever running.
func TestRequeuer_CancelStopsPendingRetry(t *testing.T) {
	h := &countingHandler{failUntil: 1000}
	// A long base delay guarantees the cancel lands during the initial backoff,
	// before run() first invokes the handler.
	q := newTestRequeuer(context.Background(), h, 8, 200*time.Millisecond)
	defer q.stop()

	q.schedule(Event[string]{ResourceID: "gw-1"})
	q.cancel("gw-1")

	time.Sleep(120 * time.Millisecond)
	if got := h.count(); got != 0 {
		t.Fatalf("handler called %d times after cancel, want 0", got)
	}
	if q.pendingLen() != 0 {
		t.Fatalf("pending retries = %d, want 0 after cancel", q.pendingLen())
	}
}

// Re-scheduling the same resource must supersede the prior retry, not accumulate
// concurrent backoff loops for it.
func TestRequeuer_ScheduleSupersedes(t *testing.T) {
	h := &countingHandler{failUntil: 1000}
	q := newTestRequeuer(context.Background(), h, 8, 200*time.Millisecond)
	defer q.stop()

	q.schedule(Event[string]{ResourceID: "gw-1"})
	q.schedule(Event[string]{ResourceID: "gw-1"})

	if got := q.pendingLen(); got != 1 {
		t.Fatalf("pending retries = %d, want 1 (second schedule supersedes first)", got)
	}
}

// stop must cancel outstanding retries and return only once their goroutines have
// exited, so the watcher can shut down cleanly.
func TestRequeuer_StopCancelsAndWaits(t *testing.T) {
	h := &countingHandler{failUntil: 1000}
	q := newTestRequeuer(context.Background(), h, 8, 200*time.Millisecond)

	q.schedule(Event[string]{ResourceID: "gw-1"})
	q.schedule(Event[string]{ResourceID: "gw-2"})
	q.stop()

	if got := q.pendingLen(); got != 0 {
		t.Fatalf("pending retries = %d, want 0 after stop", got)
	}
}

// pendingLen reports the number of tracked in-flight retries (test-only helper).
func (q *requeuer[T]) pendingLen() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.pending)
}
