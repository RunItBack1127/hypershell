package watcher

import (
	"context"
	"log"
	"sync"
	"time"

	"k8s.io/client-go/util/workqueue"
)

// Gateway reconcile retry tuning. A failed reconcile is requeued with capped
// exponential backoff and retried indefinitely -- until the watcher context ends
// or a newer desired state supersedes it. The gateway watch stream does not
// replay state on (re)connect, so the queue is the only mechanism that re-drives
// a reconcile that failed without a subsequent spec change; a finite attempt
// budget would reintroduce the permanent-stranded-gateway bug once the budget was
// spent during a long outage.
const (
	gatewayRequeueBaseDelay = 2 * time.Second
	gatewayRequeueMaxDelay  = 30 * time.Second
	// gatewayReconcileWorkers bounds how many *distinct* gateways reconcile
	// concurrently. The queue serializes work per gateway regardless (a key in
	// flight is never handed to a second worker), so this only caps cross-gateway
	// parallelism -- keeping one slow provision (which blocks on a multi-minute
	// TLS-secret wait) from stalling every other gateway behind it, as the old
	// synchronous Recv loop did.
	gatewayReconcileWorkers = 4
)

// reconcileQueue serializes and durably retries reconciliations per resource,
// replacing the fire-and-forget requeue goroutine that could race the reconciler.
//
// It is a thin wrapper over client-go's rate-limiting workqueue plus a map of the
// latest event seen per resource. Every observed event calls enqueue, which
// records the latest payload and Adds the resource key. Worker goroutines pull
// keys and invoke the handler with the *latest* payload for that key. This gives
// three properties the previous requeuer lacked:
//
//   - Per-resource serialization: the workqueue never hands the same key to two
//     workers at once, so a retry can never run concurrently with a live event
//     for the same gateway. There is no nil-result cancellation to get wrong: a
//     successful (or legitimately phase-gated) reconcile simply Forgets the key,
//     and only a returned error requeues it.
//   - Coalescing to latest desired state: a retry reconciles the newest observed
//     payload, not a frozen original. A gateway un-routed after a failed
//     provisioning attempt is therefore torn down on retry, never resurrected.
//   - Indefinite capped-backoff recovery: AddRateLimited retries forever (bounded
//     delay), so a transient failure recovers whenever the dependency does,
//     without a finite budget that could expire mid-outage.
//
// The retryTransform hook lets a caller adjust the payload used *only* on retries
// (NumRequeues > 0). Gateways use it to clear the phase the reconciler itself
// stamps (Provisioning) before doing its work: that self-write coalesces into the
// latest payload, so a retry that reused it verbatim would hit the phase gate and
// silently no-op, re-stranding the very gateway the retry exists to recover. The
// first attempt of a freshly observed event runs untransformed so the phase gate
// still governs ordinary create/update traffic.
type reconcileQueue[T any] struct {
	baseCtx        context.Context
	handler        Handler[T]
	kind           string
	workers        int
	retryTransform func(Event[T]) Event[T]

	queue workqueue.TypedRateLimitingInterface[string]

	mu       sync.Mutex
	latest   map[string]Event[T]
	wg       sync.WaitGroup
	stopOnce sync.Once
	stopCh   chan struct{}
}

// queueOption customizes a reconcileQueue before its workers start.
type queueOption[T any] func(*reconcileQueue[T])

// withRetryTransform sets the payload transform applied on retry attempts.
func withRetryTransform[T any](f func(Event[T]) Event[T]) queueOption[T] {
	return func(q *reconcileQueue[T]) { q.retryTransform = f }
}

// withRateLimiter overrides the queue's rate limiter (used by tests to shorten
// backoff).
func withRateLimiter[T any](l workqueue.TypedRateLimiter[string]) queueOption[T] {
	return func(q *reconcileQueue[T]) {
		q.queue = workqueue.NewTypedRateLimitingQueue(l)
	}
}

// withWorkers overrides the worker count (used by tests).
func withWorkers[T any](n int) queueOption[T] {
	return func(q *reconcileQueue[T]) { q.workers = n }
}

// newReconcileQueue builds and starts a reconcile queue. Workers run on baseCtx
// (the watcher lifetime), not any per-stream context, so retries survive a stream
// reconnect. Call stop to drain and shut down.
func newReconcileQueue[T any](baseCtx context.Context, kind string, handler Handler[T], opts ...queueOption[T]) *reconcileQueue[T] {
	q := &reconcileQueue[T]{
		baseCtx: baseCtx,
		handler: handler,
		kind:    kind,
		workers: gatewayReconcileWorkers,
		queue: workqueue.NewTypedRateLimitingQueue(
			workqueue.NewTypedItemExponentialFailureRateLimiter[string](gatewayRequeueBaseDelay, gatewayRequeueMaxDelay),
		),
		latest: make(map[string]Event[T]),
		stopCh: make(chan struct{}),
	}
	for _, opt := range opts {
		opt(q)
	}
	// Shut the queue down when the watcher context ends so blocked workers wake and
	// exit even if stop is never reached; stopCh does the same for an explicit stop
	// (baseCtx may be context.Background, whose Done never fires). ShutDown is
	// idempotent, so both paths are safe.
	q.wg.Add(1)
	go func() {
		defer q.wg.Done()
		select {
		case <-baseCtx.Done():
		case <-q.stopCh:
		}
		q.queue.ShutDown()
	}()
	q.start()
	return q
}

// enqueue records the latest payload for a resource and schedules it for
// reconciliation, coalescing with any pending work for the same resource.
func (q *reconcileQueue[T]) enqueue(ev Event[T]) {
	q.mu.Lock()
	q.latest[ev.ResourceID] = ev
	q.mu.Unlock()
	q.queue.Add(ev.ResourceID)
}

func (q *reconcileQueue[T]) start() {
	for i := 0; i < q.workers; i++ {
		q.wg.Add(1)
		go func() {
			defer q.wg.Done()
			for q.processNext() {
			}
		}()
	}
}

// processNext reconciles one key. It returns false only when the queue is shut
// down, so workers loop on it until then.
func (q *reconcileQueue[T]) processNext() bool {
	id, shutdown := q.queue.Get()
	if shutdown {
		return false
	}
	defer q.queue.Done(id)

	q.mu.Lock()
	ev, ok := q.latest[id]
	q.mu.Unlock()
	if !ok {
		// No payload recorded (e.g. a delete already reconciled and pruned it).
		q.queue.Forget(id)
		return true
	}

	// A requeued attempt is out-of-band recovery for an earlier failure; let the
	// caller adapt the payload (gateways clear the phase so recovery bypasses the
	// phase gate). First attempts run untransformed so the gate still governs
	// ordinary create/update traffic.
	if q.retryTransform != nil && q.queue.NumRequeues(id) > 0 {
		ev = q.retryTransform(ev)
	}

	if err := q.handler.Handle(q.baseCtx, ev); err != nil {
		log.Printf("WARN %s %s reconcile failed; requeueing with backoff: %v", q.kind, id, err)
		q.queue.AddRateLimited(id)
		return true
	}

	// Success or a legitimate phase-gated no-op: stop retrying. If a newer event
	// arrived while we worked, Add already re-dirtied the key so it is processed
	// again with the latest payload.
	q.queue.Forget(id)

	// Prune a fully-handled delete so the latest map does not retain entries for
	// gateways that no longer exist -- but only if no newer event coalesced in.
	if ev.Type == EventDeleted {
		q.mu.Lock()
		if cur, ok := q.latest[id]; ok && cur.Type == EventDeleted {
			delete(q.latest, id)
		}
		q.mu.Unlock()
	}
	return true
}

// stop shuts the queue down and waits for all workers (and the context watcher)
// to exit. Safe to call more than once.
func (q *reconcileQueue[T]) stop() {
	q.stopOnce.Do(func() { close(q.stopCh) })
	q.queue.ShutDown()
	q.wg.Wait()
}
