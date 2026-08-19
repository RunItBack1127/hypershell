package reconciler

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openshift-online/hypershell/components/control-plane/internal/exposure"
)

// scriptedExposure returns a readiness/err drawn from a per-call script,
// clamping to the last entry so a "ready" or "error" state persists.
type scriptedExposure struct {
	steps []exposure.Readiness
	err   error
	calls int32
}

func (s *scriptedExposure) ResolveAddress(context.Context, exposure.Request) (string, error) {
	return "", nil
}

func (s *scriptedExposure) ObserveReadiness(context.Context, exposure.Request) (exposure.Readiness, error) {
	i := int(atomic.AddInt32(&s.calls, 1)) - 1
	if s.err != nil && i == 0 {
		// First observation errors; subsequent ones fall through to the script.
		return exposure.Readiness{}, s.err
	}
	if i >= len(s.steps) {
		i = len(s.steps) - 1
	}
	return s.steps[i], nil
}

func TestPollRouteReady(t *testing.T) {
	notReady := exposure.Readiness{Ready: false, Reason: "gateway not programmed: Pending"}
	ready := exposure.Readiness{Ready: true}

	t.Run("ready on first observation returns true", func(t *testing.T) {
		exp := &scriptedExposure{steps: []exposure.Readiness{ready}}
		r := &GatewayReconciler{exposure: exp}
		if !r.pollRouteReady(t.Context(), "ns", time.Millisecond, time.Second) {
			t.Fatal("expected route to be observed ready")
		}
		if got := atomic.LoadInt32(&exp.calls); got != 1 {
			t.Errorf("expected exactly 1 observation, got %d", got)
		}
	})

	t.Run("becomes ready after polling returns true", func(t *testing.T) {
		exp := &scriptedExposure{steps: []exposure.Readiness{notReady, notReady, ready}}
		r := &GatewayReconciler{exposure: exp}
		if !r.pollRouteReady(t.Context(), "ns", time.Millisecond, time.Second) {
			t.Fatal("expected route to become ready after polling")
		}
		if got := atomic.LoadInt32(&exp.calls); got < 3 {
			t.Errorf("expected at least 3 observations, got %d", got)
		}
	})

	t.Run("retries past a transient error", func(t *testing.T) {
		exp := &scriptedExposure{steps: []exposure.Readiness{ready}, err: context.DeadlineExceeded}
		r := &GatewayReconciler{exposure: exp}
		if !r.pollRouteReady(t.Context(), "ns", time.Millisecond, time.Second) {
			t.Fatal("expected route to become ready after a transient error")
		}
	})

	t.Run("window elapses without readiness returns false", func(t *testing.T) {
		exp := &scriptedExposure{steps: []exposure.Readiness{notReady}}
		r := &GatewayReconciler{exposure: exp}
		if r.pollRouteReady(t.Context(), "ns", time.Millisecond, 20*time.Millisecond) {
			t.Fatal("expected timeout to report not ready")
		}
	})

	t.Run("cancelled context returns false", func(t *testing.T) {
		exp := &scriptedExposure{steps: []exposure.Readiness{notReady}}
		r := &GatewayReconciler{exposure: exp}
		ctx, cancel := context.WithCancel(t.Context())
		cancel()
		if r.pollRouteReady(ctx, "ns", time.Millisecond, time.Minute) {
			t.Fatal("expected cancelled context to report not ready")
		}
	})
}
