package sandbox

import (
	"net"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/network"
)

func peerIP(ip net.IP) net.IP {
	if ip == nil {
		return nil
	}

	ip4 := ip.To4()
	if ip4 == nil {
		return nil
	}

	peer := make(net.IP, len(ip4))
	copy(peer, ip4)
	peer[len(peer)-1] ^= 0x01

	return peer
}

func slotVethPair(slot *network.Slot) (net.IP, net.IP) {
	if slot == nil {
		return nil, nil
	}

	host := slot.VethIP()
	guest := peerIP(host)

	return host, guest
}

func resolveInterfaceIPs(slot *network.Slot) []net.IP {
	ips := make([]net.IP, 0, 3)
	if slot == nil {
		return ips
	}

	hostVeth, guestVeth := slotVethPair(slot)
	if hostVeth != nil {
		ips = append(ips, hostVeth)
	}
	if guestVeth != nil {
		ips = append(ips, guestVeth)
	}
	if host := slot.HostIP(); host != nil {
		ips = append(ips, host)
	}

	return dedupeIPs(ips)
}

func envdTargetIP(slot *network.Slot) net.IP {
	if slot == nil {
		return nil
	}

	if host := slot.HostIP(); host != nil {
		return host
	}

	hostVeth, guestVeth := slotVethPair(slot)
	if guestVeth != nil {
		return guestVeth
	}
	if hostVeth != nil {
		return hostVeth
	}

	return nil
}

func ipsToStrings(ips []net.IP) []string {
	out := make([]string, 0, len(ips))
	for _, ip := range ips {
		if ip == nil {
			continue
		}
		out = append(out, ip.String())
	}
	return out
}

func dedupeIPs(ips []net.IP) []net.IP {
	seen := make(map[string]struct{}, len(ips))
	result := make([]net.IP, 0, len(ips))

	for _, ip := range ips {
		if ip == nil {
			continue
		}
		key := ip.String()
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, ip)
	}

	return result
}
