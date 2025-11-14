package storage

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/google/uuid"
	"golang.org/x/sync/semaphore"
)

const (
	// snapshotCacheDir is a tmpfs directory mounted on the host.
	// This is used for speed optimization as the final diff is copied to the persistent storage.
	snapshotCacheDir = "/mnt/snapshot-cache"

	maxParallelMemfileSnapshotting = 8
)

var snapshotCacheQueue = semaphore.NewWeighted(maxParallelMemfileSnapshotting)

type TemporaryMemfile struct {
	path    string
	closeFn func()
}

func AcquireTmpMemfile(
	ctx context.Context,
	buildID string,
) (*TemporaryMemfile, error) {
	randomID, err := uuid.NewRandom()
	if err != nil {
		return nil, fmt.Errorf("failed to generate identifier: %w", err)
	}

	err = snapshotCacheQueue.Acquire(ctx, 1)
	if err != nil {
		return nil, fmt.Errorf("failed to acquire cache: %w", err)
	}
	releaseOnce := sync.OnceFunc(func() {
		snapshotCacheQueue.Release(1)
	})

	if err := os.MkdirAll(snapshotCacheDir, 0o755); err != nil {
		releaseOnce()
		return nil, fmt.Errorf("failed to prepare snapshot cache dir: %w", err)
	}

	path := cacheMemfileFullSnapshotPath(buildID, randomID.String())

	tmpFile, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
	if err != nil {
		releaseOnce()
		return nil, fmt.Errorf("failed to create snapshot memfile %s: %w", path, err)
	}
	if closeErr := tmpFile.Close(); closeErr != nil {
		releaseOnce()
		_ = os.Remove(path)
		return nil, fmt.Errorf("failed to close snapshot memfile %s: %w", path, closeErr)
	}

	return &TemporaryMemfile{
		path:    path,
		closeFn: releaseOnce,
	}, nil
}

func (f *TemporaryMemfile) Path() string {
	return f.path
}

func (f *TemporaryMemfile) Close() error {
	defer f.closeFn()

	return os.RemoveAll(f.path)
}

func cacheMemfileFullSnapshotPath(buildID string, randomID string) string {
	name := fmt.Sprintf("%s-%s-%s.full", buildID, MemfileName, randomID)

	return filepath.Join(snapshotCacheDir, name)
}
