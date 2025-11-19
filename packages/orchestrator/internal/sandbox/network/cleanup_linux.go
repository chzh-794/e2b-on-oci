//go:build linux
// +build linux

package network

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
	"go.uber.org/zap"
)

func cleanupDanglingNamespace(slot *Slot) error {
	if slot == nil {
		return nil
	}

	logger := zap.L().With(
		zap.String("namespace", slot.NamespaceID()),
		zap.String("veth", slot.VethName()),
	)

	// Always try to clean up veth devices, even if namespace file doesn't exist
	// This handles cases where namespace was deleted but veth device remains
	if link, err := netlink.LinkByName(slot.VethName()); err == nil {
		zap.L().Info("[network cleanup]: Removing dangling veth device",
			zap.String("veth", slot.VethName()),
			zap.String("namespace", slot.NamespaceID()))
		if delErr := netlink.LinkDel(link); delErr != nil {
			logger.Warn("failed to delete dangling veth link", zap.Error(delErr))
		} else {
			zap.L().Info("[network cleanup]: Successfully removed dangling veth device",
				zap.String("veth", slot.VethName()))
		}
	}

	// Close the namespace handle if it exists (e.g., if CreateNetwork() failed partway through)
	if slot.nsHandle != 0 {
		if closeErr := slot.nsHandle.Close(); closeErr != nil {
			logger.Warn("failed to close namespace handle during cleanup", zap.Error(closeErr))
		}
		slot.nsHandle = 0
	}

	// Only try to delete namespace if the namespace file exists
	nsPath := filepath.Join(netNamespacesDir, slot.NamespaceID())
	if _, statErr := os.Stat(nsPath); !errors.Is(statErr, os.ErrNotExist) {
		if err := netns.DeleteNamed(slot.NamespaceID()); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("failed to delete dangling namespace %s: %w", slot.NamespaceID(), err)
		}
	}

	return nil
}
