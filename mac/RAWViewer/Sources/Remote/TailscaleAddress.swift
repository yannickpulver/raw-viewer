import Darwin

/// The Mac's address on the tailnet: an IPv4 in Tailscale's 100.64.0.0/10 range on a `utun`
/// interface. The server binds to it, so only tailnet devices can reach it.
enum TailscaleAddress {
    static func ipv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("utun"), let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let octets = withUnsafeBytes(of: raw) { Array($0) }
            if isTailscale(octets) { return octets.map(String.init).joined(separator: ".") }
        }
        return nil
    }

    static func isTailscale(_ octets: [UInt8]) -> Bool {
        octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}
