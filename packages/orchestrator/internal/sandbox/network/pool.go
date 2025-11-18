package network

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

const (
	NewSlotsPoolSize    = 32
	ReusedSlotsPoolSize = 100
)

type Pool struct {
	ctx    context.Context
	cancel context.CancelFunc

	newSlots          chan *Slot
	reusedSlots       chan *Slot
	newSlotCounter    metric.Int64UpDownCounter
	reusedSlotCounter metric.Int64UpDownCounter

	slotStorage Storage
}

func NewPool(ctx context.Context, meterProvider metric.MeterProvider, newSlotsPoolSize, reusedSlotsPoolSize int, clientID string, tracer trace.Tracer) (*Pool, error) {
	newSlots := make(chan *Slot, newSlotsPoolSize-1)
	reusedSlots := make(chan *Slot, reusedSlotsPoolSize)

	meter := meterProvider.Meter("orchestrator.network.pool")

	newSlotCounter, err := telemetry.GetUpDownCounter(meter, telemetry.NewNetworkSlotSPoolCounterMeterName)
	if err != nil {
		return nil, fmt.Errorf("failed to create new slot counter: %w", err)
	}

	reusedSlotsCounter, err := telemetry.GetUpDownCounter(meter, telemetry.ReusedNetworkSlotSPoolCounterMeterName)
	if err != nil {
		return nil, fmt.Errorf("failed to create reused slot counter: %w", err)
	}

	slotStorage, err := NewStorage(vrtSlotsSize, clientID, tracer)
	if err != nil {
		return nil, fmt.Errorf("failed to create slot storage: %w", err)
	}

	ctx, cancel := context.WithCancel(ctx)
	pool := &Pool{
		newSlots:          newSlots,
		reusedSlots:       reusedSlots,
		newSlotCounter:    newSlotCounter,
		reusedSlotCounter: reusedSlotsCounter,
		ctx:               ctx,
		cancel:            cancel,
		slotStorage:       slotStorage,
	}

	zap.L().Info("[network slot pool]: Initializing network pool",
		zap.Int("new_slots_size", newSlotsPoolSize),
		zap.Int("reused_slots_size", reusedSlotsPoolSize),
		zap.String("client_id", clientID))

	go func() {
		zap.L().Info("[network slot pool]: Starting populate() goroutine")
		err := pool.populate(ctx)
		if err != nil {
			zap.L().Fatal("error when populating network slot pool", zap.Error(err))
		}

		zap.L().Info("network slot pool populate closed")
	}()

	zap.L().Info("[network slot pool]: Network pool initialized successfully")
	return pool, nil
}

func (p *Pool) acquireSlotID() (*Slot, error) {
	zap.L().Info("[network slot pool]: Acquiring slot ID from storage")
	slot, err := p.slotStorage.Acquire(p.ctx)
	if err != nil {
		zap.L().Error("[network slot pool]: Failed to acquire slot from storage", zap.Error(err))
		return nil, fmt.Errorf("failed to acquire slot: %w", err)
	}
	zap.L().Info("[network slot pool]: Slot ID acquired", zap.String("namespace", slot.NamespaceID()))

	// Don't create network setup here - do it on-demand when actually needed.
	// This prevents the cleanup timer from deleting namespaces we just created.
	return slot, nil
}

func (p *Pool) populate(ctx context.Context) error {
	defer close(p.newSlots)

	for {
		select {
		case <-ctx.Done():
			// Do not return an error here, this is expected on close
			return nil
		default:
			zap.L().Info("[network slot pool]: populate() loop - acquiring slot ID")
			slot, err := p.acquireSlotID()
			if err != nil {
				zap.L().Error("[network slot pool]: failed to acquire slot ID in populate loop", zap.Error(err), zap.String("error_type", fmt.Sprintf("%T", err)))

				continue
			}

			zap.L().Info("[network slot pool]: Successfully acquired slot ID, adding to pool", zap.String("namespace", slot.NamespaceID()))
			p.newSlotCounter.Add(ctx, 1)
			p.newSlots <- slot
			zap.L().Info("[network slot pool]: Slot ID added to pool", zap.String("namespace", slot.NamespaceID()))
		}
	}
}

func (p *Pool) Get(ctx context.Context, tracer trace.Tracer, allowInternet bool) (*Slot, error) {
	var slot *Slot

	select {
	case s := <-p.reusedSlots:
		p.reusedSlotCounter.Add(ctx, -1)
		telemetry.ReportEvent(ctx, "reused network slot")

		slot = s
	default:
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case s := <-p.newSlots:
			p.newSlotCounter.Add(ctx, -1)
			telemetry.ReportEvent(ctx, "new network slot")

			slot = s
		}
	}

	// Check if network setup exists. If not, create it on-demand.
	// This is more efficient than pre-creating (which gets deleted by cleanup timer).
	nsPath := filepath.Join("/var/run/netns", slot.NamespaceID())
	if _, err := os.Stat(nsPath); os.IsNotExist(err) {
		zap.L().Info("[network slot pool]: Creating network setup on-demand",
			zap.String("namespace", slot.NamespaceID()),
			zap.String("path", nsPath))

		// Clean up any dangling resources first (veth devices, iptables rules, etc.)
		// The handle might be open from a previous attempt, so close it first
		if slot.nsHandle != 0 {
			if closeErr := slot.nsHandle.Close(); closeErr != nil {
				zap.L().Warn("[network slot pool]: Failed to close old namespace handle",
					zap.String("namespace", slot.NamespaceID()),
					zap.Error(closeErr))
			}
			slot.nsHandle = 0
		}

		// Close firewall if it exists (from previous use) before recreating network
		// This prevents "firewall is already initialized" error when reusing slots
		if slot.Firewall != nil {
			if closeErr := slot.CloseFirewall(); closeErr != nil {
				zap.L().Warn("[network slot pool]: Failed to close old firewall",
					zap.String("namespace", slot.NamespaceID()),
					zap.Error(closeErr))
			}
		}

		// Clean up dangling network devices and iptables rules
		if cleanupErr := cleanupDanglingNamespace(slot); cleanupErr != nil {
			zap.L().Warn("[network slot pool]: Failed to cleanup dangling namespace resources",
				zap.String("namespace", slot.NamespaceID()),
				zap.Error(cleanupErr))
		}

		// Create the network setup now that we actually need it
		zap.L().Info("[network slot pool]: Creating network setup for slot",
			zap.String("namespace", slot.NamespaceID()))
		if err := slot.CreateNetwork(); err != nil {
			// If creation fails, clean up and return error
			cleanupErr := cleanupDanglingNamespace(slot)
			releaseErr := p.slotStorage.Release(slot)
			return nil, fmt.Errorf("failed to create network for slot %s: %w (cleanup: %v, release: %v)",
				slot.NamespaceID(), err, cleanupErr, releaseErr)
		}
		zap.L().Info("[network slot pool]: Successfully created network setup",
			zap.String("namespace", slot.NamespaceID()))
	} else if err != nil {
		// Some other error checking the namespace file
		return nil, fmt.Errorf("error checking namespace file %s: %w", nsPath, err)
	} else {
		// Namespace exists - ensure firewall is initialized if it's nil
		// This can happen if the namespace was recreated externally or firewall was cleared
		if slot.Firewall == nil {
			zap.L().Info("[network slot pool]: Namespace exists but firewall is nil, initializing firewall",
				zap.String("namespace", slot.NamespaceID()))
			if err := slot.InitializeFirewall(); err != nil {
				return nil, fmt.Errorf("failed to initialize firewall for existing namespace %s: %w", slot.NamespaceID(), err)
			}
		}
	}

	err := slot.ConfigureInternet(ctx, tracer, allowInternet)
	if err != nil {
		return nil, fmt.Errorf("error setting slot internet access: %w", err)
	}

	return slot, nil
}

func (p *Pool) Return(ctx context.Context, tracer trace.Tracer, slot *Slot) error {
	err := slot.ResetInternet(ctx, tracer)
	if err != nil {
		// Cleanup the slot if resetting internet fails
		if cerr := p.cleanup(slot); cerr != nil {
			return fmt.Errorf("reset internet: %v; cleanup: %w", err, cerr)
		}

		return fmt.Errorf("error resetting slot internet access: %w", err)
	}

	select {
	case p.reusedSlots <- slot:
		p.reusedSlotCounter.Add(context.Background(), 1)
	default:
		err := p.cleanup(slot)
		if err != nil {
			return fmt.Errorf("failed to return slot '%d': %w", slot.Idx, err)
		}
	}

	return nil
}

func (p *Pool) cleanup(slot *Slot) error {
	var errs []error

	err := slot.RemoveNetwork()
	if err != nil {
		errs = append(errs, fmt.Errorf("cannot remove network when releasing slot '%d': %w", slot.Idx, err))
	}

	err = p.slotStorage.Release(slot)
	if err != nil {
		errs = append(errs, fmt.Errorf("failed to release slot '%d': %w", slot.Idx, err))
	}

	return errors.Join(errs...)
}

func (p *Pool) Close(_ context.Context) error {
	p.cancel()

	zap.L().Info("Closing network pool")

	for slot := range p.newSlots {
		err := p.cleanup(slot)
		if err != nil {
			return fmt.Errorf("failed to cleanup slot '%d': %w", slot.Idx, err)
		}
	}

	close(p.reusedSlots)
	for slot := range p.reusedSlots {
		err := p.cleanup(slot)
		if err != nil {
			return fmt.Errorf("failed to cleanup slot '%d': %w", slot.Idx, err)
		}
	}

	return nil
}
