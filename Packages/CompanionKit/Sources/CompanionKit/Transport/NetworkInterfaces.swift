import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The machine's own IP addresses, classified by network path.
public struct InterfaceAddress: Hashable, Sendable {
    public var interface: String
    public var address: String
    public var isIPv6: Bool
    public var path: NetworkPath

    public init(interface: String, address: String, isIPv6: Bool, path: NetworkPath) {
        self.interface = interface
        self.address = address
        self.isIPv6 = isIPv6
        self.path = path
    }
}

public enum NetworkInterfaces {
    /// Every usable address: LAN IPv4 addresses and tailnet addresses (v4 and
    /// v6). Loopback, link-local, and other IPv6 addresses are left out — they
    /// either don't leave the machine or need a scope id a QR code can't carry.
    public static func current() -> [InterfaceAddress] {
        var results: [InterfaceAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let socketAddress = entry.pointee.ifa_addr else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(socketAddress.pointee.sa_len)
            guard getnameinfo(socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: entry.pointee.ifa_name)

            if let classified = classify(address: address, interface: name, isIPv6: family == AF_INET6) {
                results.append(classified)
            }
        }
        // Stable order: LAN first, then Tailscale; IPv4 before IPv6.
        return results.sorted {
            ($0.path == .lan ? 0 : 1, $0.isIPv6 ? 1 : 0, $0.address) < ($1.path == .lan ? 0 : 1, $1.isIPv6 ? 1 : 0, $1.address)
        }
    }

    public static func classify(address: String, interface: String, isIPv6: Bool) -> InterfaceAddress? {
        if isIPv6 {
            let lower = address.lowercased()
            guard lower.hasPrefix("fd7a:115c:a1e0:") else { return nil }
            return InterfaceAddress(interface: interface, address: address, isIPv6: true, path: .tailscale)
        }
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        if octets[0] == 169 && octets[1] == 254 { return nil }
        // 100.64.0.0/10 — carrier-grade NAT space, which Tailscale uses.
        if octets[0] == 100 && (64...127).contains(octets[1]) {
            return InterfaceAddress(interface: interface, address: address, isIPv6: false, path: .tailscale)
        }
        return InterfaceAddress(interface: interface, address: address, isIPv6: false, path: .lan)
    }

    /// Whether this device currently has a tailnet address — on the phone, the
    /// only available sign that the Tailscale VPN is connected.
    public static var hasTailnetAddress: Bool {
        current().contains { $0.path == .tailscale }
    }
}
