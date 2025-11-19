//go:build linux
// +build linux

package network

import (
	"errors"
	"fmt"
	"net"
	"os"
	"runtime"

	"github.com/coreos/go-iptables/iptables"
	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
	"go.uber.org/zap"
)

func (s *Slot) CreateNetwork() error {
	// DETAILED LOGGING: Log network namespace creation start
	zap.L().Info("[network] Starting network namespace creation",
		zap.String("namespace_id", s.NamespaceID()),
		zap.String("veth_name", s.VethName()),
		zap.String("vpeer_name", s.VpeerName()),
	)
	
	// Prevent thread changes so we can safely manipulate with namespaces
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	// Save the original (host) namespace and restore it upon function exit
	hostNS, err := netns.Get()
	if err != nil {
		zap.L().Error("[network] Failed to get current (host) namespace",
			zap.String("namespace_id", s.NamespaceID()),
			zap.Error(err),
		)
		return fmt.Errorf("cannot get current (host) namespace: %w", err)
	}

	defer func() {
		err = netns.Set(hostNS)
		if err != nil {
			zap.L().Error("error resetting network namespace back to the host namespace", zap.Error(err))
		}

		err = hostNS.Close()
		if err != nil {
			zap.L().Error("error closing host network namespace", zap.Error(err))
		}
	}()

	// DETAILED LOGGING: Check /run/netns before creating namespace
	nsPath := fmt.Sprintf("/var/run/netns/%s", s.NamespaceID())
	if _, err := os.Stat("/var/run/netns"); err != nil {
		zap.L().Error("[network] /var/run/netns directory does not exist or is not accessible",
			zap.String("namespace_id", s.NamespaceID()),
			zap.Error(err),
		)
	}
	
	// Create NS for the sandbox
	zap.L().Info("[network] Creating named network namespace",
		zap.String("namespace_id", s.NamespaceID()),
		zap.String("expected_path", nsPath),
	)
	ns, err := netns.NewNamed(s.NamespaceID())
	if err != nil {
		// DETAILED LOGGING: Enhanced error context for namespace creation failures
		zap.L().Error("[network] Failed to create named network namespace",
			zap.String("namespace_id", s.NamespaceID()),
			zap.String("expected_path", nsPath),
			zap.String("error_type", fmt.Sprintf("%T", err)),
			zap.String("error_message", err.Error()),
			zap.Error(err),
			zap.Stack("stack_trace"),
		)
		return fmt.Errorf("cannot create new namespace: %w", err)
	}
	
	// DETAILED LOGGING: Verify namespace file was created
	if _, err := os.Stat(nsPath); err != nil {
		zap.L().Warn("[network] Namespace file not found after creation",
			zap.String("namespace_id", s.NamespaceID()),
			zap.String("path", nsPath),
			zap.Error(err),
		)
	} else {
		zap.L().Info("[network] Namespace file created successfully",
			zap.String("namespace_id", s.NamespaceID()),
			zap.String("path", nsPath),
		)
	}

	// Store the namespace handle in the Slot to keep it alive.
	// DO NOT close it here - it will be closed in RemoveNetwork() when the slot is released.
	// This prevents the namespace from being deleted prematurely in OCI.
	s.nsHandle = ns

	// Create the Veth and Vpeer
	vethAttrs := netlink.NewLinkAttrs()
	vethAttrs.Name = s.VethName()
	veth := &netlink.Veth{
		LinkAttrs: vethAttrs,
		PeerName:  s.VpeerName(),
	}

	err = netlink.LinkAdd(veth)
	if err != nil {
		return fmt.Errorf("error creating veth device: %w", err)
	}

	vpeer, err := netlink.LinkByName(s.VpeerName())
	if err != nil {
		return fmt.Errorf("error finding vpeer: %w", err)
	}

	err = netlink.LinkSetUp(vpeer)
	if err != nil {
		return fmt.Errorf("error setting vpeer device up: %w", err)
	}

	err = netlink.AddrAdd(vpeer, &netlink.Addr{
		IPNet: &net.IPNet{
			IP:   s.VpeerIP(),
			Mask: s.VrtMask(),
		},
	})
	if err != nil {
		return fmt.Errorf("error adding vpeer device address: %w", err)
	}

	// Move Veth device to the host NS
	err = netlink.LinkSetNsFd(veth, int(hostNS))
	if err != nil {
		return fmt.Errorf("error moving veth device to the host namespace: %w", err)
	}

	err = netns.Set(hostNS)
	if err != nil {
		return fmt.Errorf("error setting network namespace: %w", err)
	}

	vethInHost, err := netlink.LinkByName(s.VethName())
	if err != nil {
		return fmt.Errorf("error finding veth: %w", err)
	}

	err = netlink.LinkSetUp(vethInHost)
	if err != nil {
		return fmt.Errorf("error setting veth device up: %w", err)
	}

	err = netlink.AddrAdd(vethInHost, &netlink.Addr{
		IPNet: &net.IPNet{
			IP:   s.VethIP(),
			Mask: s.VrtMask(),
		},
	})
	if err != nil {
		return fmt.Errorf("error adding veth device address: %w", err)
	}

	err = netns.Set(ns)
	if err != nil {
		return fmt.Errorf("error setting network namespace to %s: %w", ns.String(), err)
	}

	// Create Tap device for FC in NS
	tapAttrs := netlink.NewLinkAttrs()
	tapAttrs.Name = s.TapName()
	tapAttrs.Namespace = ns
	tap := &netlink.Tuntap{
		Mode:      netlink.TUNTAP_MODE_TAP,
		LinkAttrs: tapAttrs,
	}

	err = netlink.LinkAdd(tap)
	if err != nil {
		return fmt.Errorf("error creating tap device: %w", err)
	}

	err = netlink.LinkSetUp(tap)
	if err != nil {
		return fmt.Errorf("error setting tap device up: %w", err)
	}

	err = netlink.AddrAdd(tap, &netlink.Addr{
		IPNet: &net.IPNet{
			IP:   s.TapIP(),
			Mask: s.TapCIDR(),
		},
	})
	if err != nil {
		return fmt.Errorf("error setting address of the tap device: %w", err)
	}

	// Set NS lo device up
	lo, err := netlink.LinkByName(loopbackInterface)
	if err != nil {
		return fmt.Errorf("error finding lo: %w", err)
	}

	err = netlink.LinkSetUp(lo)
	if err != nil {
		return fmt.Errorf("error setting lo device up: %w", err)
	}

	// Add NS default route
	err = netlink.RouteAdd(&netlink.Route{
		Scope: netlink.SCOPE_UNIVERSE,
		Gw:    s.VethIP(),
	})
	if err != nil {
		return fmt.Errorf("error adding default NS route: %w", err)
	}

	tables, err := iptables.New()
	if err != nil {
		return fmt.Errorf("error initializing iptables: %w", err)
	}

	// Add NAT routing rules to NS
	err = tables.Append("nat", "POSTROUTING", "-o", s.VpeerName(), "-s", s.NamespaceIP(), "-j", "SNAT", "--to-source", s.HostIPString())
	if err != nil {
		return fmt.Errorf("error creating postrouting rule to vpeer: %w", err)
	}

	err = tables.Append("nat", "PREROUTING", "-d", s.HostIPString(), "-j", "DNAT", "--to-destination", s.NamespaceIP())
	if err != nil {
		return fmt.Errorf("error creating postrouting rule from vpeer: %w", err)
	}

	err = s.InitializeFirewall()
	if err != nil {
		return fmt.Errorf("error initializing slot firewall: %w", err)
	}

	// Go back to original namespace
	err = netns.Set(hostNS)
	if err != nil {
		return fmt.Errorf("error setting network namespace to %s: %w", hostNS.String(), err)
	}

	// Add routing from host to FC namespace
	err = netlink.RouteAdd(&netlink.Route{
		Gw:  s.VpeerIP(),
		Dst: s.HostNet(),
	})
	if err != nil {
		return fmt.Errorf("error adding route from host to FC: %w", err)
	}

	// Add host forwarding rules
	err = tables.Append("filter", "FORWARD", "-i", s.VethName(), "-o", defaultGateway, "-j", "ACCEPT")
	if err != nil {
		return fmt.Errorf("error creating forwarding rule to default gateway: %w", err)
	}

	err = tables.Append("filter", "FORWARD", "-i", defaultGateway, "-o", s.VethName(), "-j", "ACCEPT")
	if err != nil {
		return fmt.Errorf("error creating forwarding rule from default gateway: %w", err)
	}

	// Add host postrouting rules
	err = tables.Append("nat", "POSTROUTING", "-s", s.HostCIDR(), "-o", defaultGateway, "-j", "MASQUERADE")
	if err != nil {
		return fmt.Errorf("error creating postrouting rule: %w", err)
	}

	return nil
}

func (s *Slot) RemoveNetwork() error {
	var errs []error

	err := s.CloseFirewall()
	if err != nil {
		errs = append(errs, fmt.Errorf("error closing firewall: %w", err))
	}

	tables, err := iptables.New()
	if err != nil {
		errs = append(errs, fmt.Errorf("error initializing iptables: %w", err))
	} else {
		// Delete host forwarding rules
		err = tables.Delete("filter", "FORWARD", "-i", s.VethName(), "-o", defaultGateway, "-j", "ACCEPT")
		if err != nil {
			errs = append(errs, fmt.Errorf("error deleting host forwarding rule to default gateway: %w", err))
		}

		err = tables.Delete("filter", "FORWARD", "-i", defaultGateway, "-o", s.VethName(), "-j", "ACCEPT")
		if err != nil {
			errs = append(errs, fmt.Errorf("error deleting host forwarding rule from default gateway: %w", err))
		}

		// Delete host postrouting rules
		err = tables.Delete("nat", "POSTROUTING", "-s", s.HostCIDR(), "-o", defaultGateway, "-j", "MASQUERADE")
		if err != nil {
			errs = append(errs, fmt.Errorf("error deleting host postrouting rule: %w", err))
		}

		// Delete veth output DNAT rule
		err = tables.Delete("nat", "OUTPUT", "-d", s.VethIP().String(), "-j", "DNAT", "--to-destination", s.NamespaceIP())
		if err != nil {
			errs = append(errs, fmt.Errorf("error deleting veth output dnat rule: %w", err))
		}

		if vethPeer := s.VethIP(); vethPeer != nil {
			err = tables.Delete("nat", "OUTPUT", "-d", vethPeer.String(), "-j", "DNAT", "--to-destination", s.NamespaceIP())
			if err != nil {
				errs = append(errs, fmt.Errorf("error deleting veth peer output dnat rule: %w", err))
			}
		}
	}

	// Delete routing from host to FC namespace
	err = netlink.RouteDel(&netlink.Route{
		Gw:  s.VpeerIP(),
		Dst: s.HostNet(),
	})
	if err != nil {
		errs = append(errs, fmt.Errorf("error deleting route from host to FC: %w", err))
	}

	// Delete veth device
	// We explicitly delete the veth device from the host namespace because even though deleting
	// is deleting the device there may be a race condition when creating a new veth device with
	// the same name immediately after deleting the namespace.
	veth, err := netlink.LinkByName(s.VethName())
	if err != nil {
		errs = append(errs, fmt.Errorf("error finding veth: %w", err))
	} else {
		err = netlink.LinkDel(veth)
		if err != nil {
			errs = append(errs, fmt.Errorf("error deleting veth device: %w", err))
		}
	}

	// Close the namespace handle before deleting the namespace
	// This ensures the FD is closed before we try to delete the namespace
	if s.nsHandle != 0 {
		err = s.nsHandle.Close()
		if err != nil {
			errs = append(errs, fmt.Errorf("error closing namespace handle: %w", err))
		}
		s.nsHandle = 0
	}

	err = netns.DeleteNamed(s.NamespaceID())
	if err != nil {
		errs = append(errs, fmt.Errorf("error deleting namespace: %w", err))
	}

	return errors.Join(errs...)
}
