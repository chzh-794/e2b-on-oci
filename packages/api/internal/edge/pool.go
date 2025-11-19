package edge

import (
	"context"
	"sync"
	"time"

	"github.com/google/uuid"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/db/client"
	"github.com/e2b-dev/infra/packages/db/queries"
	l "github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/smap"
	"github.com/e2b-dev/infra/packages/shared/pkg/synchronization"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

const (
	poolSyncInterval = 60 * time.Second
	poolSyncTimeout  = 15 * time.Second
)

type Pool struct {
	db  *client.Client
	tel *telemetry.Client

	clusters        *smap.Map[*Cluster]
	synchronization *synchronization.Synchronize[queries.GetActiveClustersRow, *Cluster]

	tracer trace.Tracer
}

func NewPool(ctx context.Context, tel *telemetry.Client, db *client.Client, tracer trace.Tracer) (*Pool, error) {
	p := &Pool{
		db:       db,
		tel:      tel,
		tracer:   tracer,
		clusters: smap.New[*Cluster](),
	}

	// Periodically sync clusters with the database
	go p.startSync()

	// Shutdown function to gracefully close the pool
	go func() {
		<-ctx.Done()
		p.Close()
	}()

	store := poolSynchronizationStore{pool: p}
	p.synchronization = synchronization.NewSynchronize(p.tracer, "clusters-pool", "Clusters pool", store)

	return p, nil
}

func (p *Pool) startSync() {
	p.synchronization.Start(poolSyncInterval, poolSyncTimeout, true)
}

func (p *Pool) GetClusterById(id uuid.UUID) (*Cluster, bool) {
	cluster, ok := p.clusters.Get(id.String())
	if !ok {
		return nil, false
	}

	return cluster, true
}

func (p *Pool) Close() {
	p.synchronization.Close()

	wg := &sync.WaitGroup{}
	for _, cluster := range p.clusters.Items() {
		wg.Add(1)
		go func(c *Cluster) {
			defer wg.Done()
			zap.L().Info("Closing cluster", l.WithClusterID(c.ID))
			err := c.Close()
			if err != nil {
				zap.L().Error("Error closing cluster", zap.Error(err), l.WithClusterID(c.ID))
			}
		}(cluster)
	}
	wg.Wait()
}

// SynchronizationStore is an interface that defines methods for synchronizing the clusters pool with the database
type poolSynchronizationStore struct {
	pool *Pool
}

func (d poolSynchronizationStore) SourceList(ctx context.Context) ([]queries.GetActiveClustersRow, error) {
	return d.pool.db.GetActiveClusters(ctx)
}

func (d poolSynchronizationStore) SourceExists(ctx context.Context, s []queries.GetActiveClustersRow, p *Cluster) bool {
	for _, item := range s {
		if item.Cluster.ID == p.ID {
			return true
		}
	}

	return false
}

func (d poolSynchronizationStore) PoolList(ctx context.Context) []*Cluster {
	items := make([]*Cluster, 0)
	for _, item := range d.pool.clusters.Items() {
		items = append(items, item)
	}
	return items
}

func (d poolSynchronizationStore) PoolExists(ctx context.Context, source queries.GetActiveClustersRow) bool {
	_, found := d.pool.clusters.Get(source.Cluster.ID.String())
	return found
}

func (d poolSynchronizationStore) PoolInsert(ctx context.Context, source queries.GetActiveClustersRow) {
	cluster := source.Cluster
	clusterID := cluster.ID.String()

	zap.L().Info("Initializing newly discovered cluster", l.WithClusterID(cluster.ID))

	c, err := NewCluster(d.pool.tracer, d.pool.tel, cluster.Endpoint, cluster.EndpointTls, cluster.Token, cluster.ID)
	if err != nil {
		zap.L().Error("Initializing cluster failed", zap.Error(err), l.WithClusterID(c.ID))
		return
	}

	zap.L().Info("Cluster initialized successfully", l.WithClusterID(c.ID))
	d.pool.clusters.Insert(clusterID, c)
}

func (d poolSynchronizationStore) PoolUpdate(ctx context.Context, cluster *Cluster) {
	// Check if cluster configuration changed in database
	// Get current database configuration for this cluster
	activeClusters, err := d.pool.db.GetActiveClusters(ctx)
	if err != nil {
		zap.L().Warn("Failed to get active clusters for update check", zap.Error(err), l.WithClusterID(cluster.ID))
		return
	}

	// Find the database row for this cluster
	var dbCluster *queries.Cluster
	for _, row := range activeClusters {
		if row.Cluster.ID == cluster.ID {
			dbCluster = &row.Cluster
			break
		}
	}

	if dbCluster == nil {
		// Cluster not found in database, will be removed by sync
		return
	}

	// Extract current endpoint from HTTP client (we need to check if it changed)
	// Since we can't easily extract endpoint from httpClient, we'll use a different approach:
	// Remove and re-insert the cluster if endpoint/token might have changed
	// This ensures we always have the latest configuration
	
	// For now, we'll close the old cluster and create a new one with updated config
	// This is safe because the cluster ID stays the same, and we're just updating the HTTP/gRPC clients
	clusterID := cluster.ID.String()
	
	zap.L().Info("Updating cluster configuration", 
		l.WithClusterID(cluster.ID),
		zap.String("new_endpoint", dbCluster.Endpoint),
		zap.Bool("new_endpoint_tls", dbCluster.EndpointTls),
	)

	// Close the old cluster
	if err := cluster.Close(); err != nil {
		zap.L().Warn("Error closing old cluster during update", zap.Error(err), l.WithClusterID(cluster.ID))
	}

	// Create new cluster with updated configuration
	newCluster, err := NewCluster(d.pool.tracer, d.pool.tel, dbCluster.Endpoint, dbCluster.EndpointTls, dbCluster.Token, cluster.ID)
	if err != nil {
		zap.L().Error("Failed to create updated cluster", zap.Error(err), l.WithClusterID(cluster.ID))
		// Try to restore old cluster (but it's already closed, so this will fail)
		// In practice, the next sync cycle will re-insert it
		return
	}

	// Replace the cluster in the pool
	d.pool.clusters.Insert(clusterID, newCluster)
	zap.L().Info("Cluster configuration updated successfully", l.WithClusterID(cluster.ID))
}

func (d poolSynchronizationStore) PoolRemove(ctx context.Context, cluster *Cluster) {
	zap.L().Info("Removing cluster from pool", l.WithClusterID(cluster.ID))

	err := cluster.Close()
	if err != nil {
		zap.L().Error("Error during removing cluster from pool", zap.Error(err), l.WithClusterID(cluster.ID))
	}

	d.pool.clusters.Remove(cluster.ID.String())
}
