package watcher

import (
	"context"
	"log"
	"sync"
	"time"
)

// Gateway reconcile requeue tuning. Retries use capped exponential backoff; the
// attempt budget spans roughly gatewayRequeueBaseDelay .. gatewayRequeueMaxDelay
// per step, so the defaults cover a multi-minute API-server blip before giving
// up and leaving recovery to the next genuine event.
const (
	gatewayRequeueBaseDelay   = 2 * time.Second
	gatewayRequeueMaxDelay    = 30 * time.Second
	gatewayRequeueMaxAttempts = 8
)

// requeuer retries failed gateway reconciliations out-of-band so a transient
// failure recovers without waiting for an external event.
//
// The gateway watch stream carries only live create/update/delete events -- it
// does not replay current state on (re)connect -- so a reconcile that fails is
// never re-driven on its own. That is fatal for the case where an API-server
// outage both fails the reconcile and prevents recording a Failed phase: the
// persisted Provisioning phase then blocks later events and no snapshot ever
// re-emits the gateway. The requeuer closes that gap by re-invoking the handler
// with the original event after a backoff, until it succeeds or the attempt
// budget is exhausted.
//
// Retries run on the watcher's lifetime context (not the per-connection stream
// context) so a stream disconnect does not abandon in-flight recovery. A newer
// event for the same gateway supersedes any pending retry: the Recv loop calls
// schedule on failure and cancel on success, and a fresh failure reschedules
// from the start. The handler must be safe for concurrent invocation (the
// gateway reconciler dedups in-flight work per resource), since a retry can run
// while the Recv loop delivers other events.
type requeuer[T any] struct {
	baseCtx  context.Context
	handler  Handler[T]
	kind     string
	base     time.Duration
	max      time.Duration
	attempts int

	mu      sync.Mutex
	pending map[string]*retry
	wg      sync.WaitGroup
}

// retry is the handle for one gateway's in-flight backoff loop, used to cancel it
// and to detect (by identity) whether it is still the current retry for its ID.
type retry struct {
	cancel context.CancelFunc
}

func newRequeuer[T any](ctx context.Context, kind string, handler Handler[T]) *requeuer[T] {
	return &requeuer[T]{
		baseCtx:  ctx,
		handler:  handler,
		kind:     kind,
		base:     gatewayRequeueBaseDelay,
		max:      gatewayRequeueMaxDelay,
		attempts: gatewayRequeueMaxAttempts,
		pending:  make(map[string]*retry),
	}
}

// schedule (re)starts the retry backoff for a failed event, superseding any
// pending retry for the same resource.
func (q *requeuer[T]) schedule(ev Event[T]) {
	rctx, cancel := context.WithCancel(q.baseCtx)
	h := &retry{cancel: cancel}

	q.mu.Lock()
	if prev, ok := q.pending[ev.ResourceID]; ok {
		prev.cancel()
	}
	q.pending[ev.ResourceID] = h
	q.wg.Add(1)
	q.mu.Unlock()

	go q.run(rctx, ev, h)
}

// cancel stops any pending retry for a resource (called when a fresh event for it
// is handled successfully, so recovery is no longer needed).
func (q *requeuer[T]) cancel(resourceID string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if h, ok := q.pending[resourceID]; ok {
		h.cancel()
		delete(q.pending, resourceID)
	}
}

// stop cancels all pending retries and waits for their goroutines to exit.
func (q *requeuer[T]) stop() {
	q.mu.Lock()
	for _, h := range q.pending {
		h.cancel()
	}
	q.mu.Unlock()
	q.wg.Wait()
}

func (q *requeuer[T]) run(ctx context.Context, ev Event[T], h *retry) {
	defer q.wg.Done()
	defer q.finish(ev.ResourceID, h)

	delay := q.base
	for attempt := 1; attempt <= q.attempts; attempt++ {
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}

		err := q.handler.Handle(ctx, ev)
		if err == nil {
			log.Printf("INFO %s %s reconcile recovered on retry %d/%d", q.kind, ev.ResourceID, attempt, q.attempts)
			return
		}
		log.Printf("WARN %s %s reconcile retry %d/%d failed: %v", q.kind, ev.ResourceID, attempt, q.attempts, err)

		delay *= 2
		if delay > q.max {
			delay = q.max
		}
	}
	log.Printf("WARN %s %s exhausted %d reconcile retries; awaiting next event", q.kind, ev.ResourceID, q.attempts)
}

// finish removes this retry from the pending set, but only if it is still the
// current one -- a newer schedule may already have replaced it.
func (q *requeuer[T]) finish(resourceID string, h *retry) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if cur, ok := q.pending[resourceID]; ok && cur == h {
		delete(q.pending, resourceID)
	}
}
