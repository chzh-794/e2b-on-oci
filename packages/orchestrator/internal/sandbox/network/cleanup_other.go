//go:build !linux

package network

func cleanupDanglingNamespace(_ *Slot) error {
	return nil
}
