import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A Duino-S found on the local network or a serial port.
public struct MaraDiscoveredDevice: Identifiable, Sendable, Equatable {
    /// Stable for a UI list: the TCP host, or the serial device path.
    public var id: String { endpoint }
    public var endpoint: String
    public var port: UInt16
    public var info: MaraProtClient.Info
    public var latencyMilliseconds: Int

    public var isEthernet: Bool { !endpoint.hasPrefix("/dev/") }
    public var displayName: String {
        "\(info.modelName) — \(endpoint)" + (isEthernet ? ":\(port)" : "")
    }
}

/// Finds Duino-S boards without requiring the IP to be typed.
///
/// Since the 2026-11-20 firmware the board runs lwIP's mDNS responder: `MX_LWIP_Init` registers
/// the hostname `duino-s` (lwIP's stock build answers `lwip`), and A-record queries for
/// `<hostname>.local` are answered with the board's IP. Discovery sends one multicast query — each
/// question carries the unicast-response (QU) bit, so the reply comes directly back to the sender
/// instead of multicast port 5353, which this process may not bind (mDNSResponder holds it on
/// macOS) — and validates every answer with the MaraProt `GET_INFO` identity (`0x0407`,
/// `"Duino - S"`). Only when no mDNS answer validates does discovery fall back to scanning the
/// local IPv4 subnets port by port, which is what older firmware (or a different hostname) needs.
public enum MaraDiscovery {
    /// A local IPv4 network to scan.
    public struct IPv4Network: Sendable, Equatable {
        public var interfaceName: String
        public var address: String
        public var netmask: String
        public var prefixLength: Int
        /// Every usable host address (`network + 1 ... broadcast - 1`), excluding this machine.
        public var hosts: [String]
    }

    public static let defaultPort: UInt16 = 5020
    /// Scans larger than this are skipped: a /24 is 254 probes, and a few hundred per interface is
    /// already enough for a bench network.
    public static let maxHostsPerNetwork = 1_024

    /// Probes one endpoint and returns it only if it identifies as a Duino-S.
    public static func probe(host: String, port: UInt16 = defaultPort,
                             timeout: TimeInterval = 0.35) -> MaraDiscoveredDevice? {
        let start = Date()
        let transport = MaraTCPTransport(host: host, port: port)
        transport.connectTimeout = timeout
        let client = MaraProtClient(transport: transport,
                                    stationId: MaraProtClient.pointToPointStation)
        client.timeout = timeout
        do {
            try client.connect()
            defer { client.close() }
            _ = try client.ping()
            let info = try client.info()
            guard isDuino(info) else { return nil }
            return MaraDiscoveredDevice(endpoint: host, port: port, info: info,
                                        latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            return nil
        }
    }

    /// Probes serial ports in order and returns those whose GET_INFO says Duino-S.
    public static func probeSerialPorts(_ paths: [String], timeout: TimeInterval = 0.8) -> [MaraDiscoveredDevice] {
        paths.compactMap { path in
            let start = Date()
            let client = MaraProtClient(transport: MaraSerialTransport(path: path),
                                        stationId: MaraProtClient.pointToPointStation)
            client.timeout = timeout
            do {
                try client.connect()
                defer { client.close() }
                _ = try client.ping()
                let info = try client.info()
                guard isDuino(info) else { return nil }
                return MaraDiscoveredDevice(endpoint: path, port: 0, info: info,
                                            latencyMilliseconds: Int(Date().timeIntervalSince(start) * 1000))
            } catch {
                return nil
            }
        }
    }

    public static func isDuino(_ info: MaraProtClient.Info) -> Bool {
        info.modelId == 0x0407 || info.modelName.lowercased().contains("duino")
    }

    /// Scans the network for Duino-S boards. mDNS answers are tried first; the subnet scan is the
    /// fallback for firmware without a responder. Runs in parallel; call off the main thread.
    public static func scanLocalNetwork(port: UInt16 = defaultPort,
                                        timeout: TimeInterval = 0.35,
                                        networks: [IPv4Network]? = nil) -> [MaraDiscoveredDevice] {
        let devices = discoverViaMdns(port: port, probeTimeout: timeout, mdnsTimeout: max(timeout, 0.6),
                                      destination: ("224.0.0.251", 5353))
        if !devices.isEmpty { return devices }
        return subnetScan(port: port, timeout: timeout, networks: networks)
    }

    /// The mDNS stage: collect A-record answers for the known hostnames and keep only those whose
    /// GET_INFO identifies as a Duino-S. `destination` is injectable for tests.
    static func discoverViaMdns(port: UInt16, probeTimeout: TimeInterval, mdnsTimeout: TimeInterval,
                                hostnames: [String] = mdnsHostnames,
                                destination: (host: String, port: UInt16)) -> [MaraDiscoveredDevice] {
        let candidates = mdnsCandidates(hostnames: hostnames, timeout: mdnsTimeout, destination: destination)
        guard !candidates.isEmpty else { return [] }
        let list = Array(Set(candidates))
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var found: [MaraDiscoveredDevice] = []
        }
        let collector = Collector()
        DispatchQueue.concurrentPerform(iterations: list.count) { index in
            guard let device = probe(host: list[index], port: port, timeout: probeTimeout) else { return }
            collector.lock.lock()
            collector.found.append(device)
            collector.lock.unlock()
        }
        return collector.found.sorted {
            ($0.latencyMilliseconds, $0.endpoint) < ($1.latencyMilliseconds, $1.endpoint)
        }
    }

    /// Scans every local IPv4 subnet that is small enough to probe. The scan runs in parallel and is
    /// expected to be called off the main thread.
    static func subnetScan(port: UInt16 = defaultPort,
                           timeout: TimeInterval = 0.35,
                           networks: [IPv4Network]? = nil) -> [MaraDiscoveredDevice] {
        let candidates = networks ?? localIPv4Networks()
        var hosts: [(String, UInt16)] = []
        var seen: Set<String> = []
        for network in candidates {
            for host in network.hosts where seen.insert(host).inserted {
                hosts.append((host, port))
            }
        }
        guard !hosts.isEmpty else { return [] }

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var found: [MaraDiscoveredDevice] = []
        }
        let collector = Collector()
        let scanHosts = hosts
        DispatchQueue.concurrentPerform(iterations: scanHosts.count) { index in
            guard let device = probe(host: scanHosts[index].0, port: scanHosts[index].1, timeout: timeout) else { return }
            collector.lock.lock()
            collector.found.append(device)
            collector.lock.unlock()
        }
        return collector.found.sorted {
            ($0.latencyMilliseconds, $0.endpoint) < ($1.latencyMilliseconds, $1.endpoint)
        }
    }

    // MARK: - mDNS

    /// mDNS hostnames the firmware answers A-record queries for. `duinos` is what
    /// `init_mdns_netbios_cb` in `lwip.c` registers; `f407plc` was the name in the first
    /// responder build; `lwip` is the stock lwIP default for a build that never sets one.
    static let mdnsHostnames = ["duinos", "f407plc", "lwip"]

    /// One mDNS query packet asking for an A record on every known hostname. Each question sets
    /// the unicast-response (QU) bit so the board answers directly to the sender instead of
    /// multicast 5353, which this process may not be allowed to bind (mDNSResponder holds it).
    static func mdnsQuery(hostnames: [String] = mdnsHostnames) -> [UInt8] {
        var query: [UInt8] = [0, 0, 0, 0, 0, UInt8(clamping: hostnames.count), 0, 0, 0, 0, 0, 0]
        for hostname in hostnames {
            for label in "\(hostname).local".split(separator: ".") {
                query.append(UInt8(clamping: label.count))
                query.append(contentsOf: label.lowercased().utf8)
            }
            query.append(0)
            query.append(contentsOf: [0x00, 0x01, 0x80, 0x01]) // A record, IN class + QU bit
        }
        return query
    }

    /// IPv4 addresses from the answer, authority and additional sections of an mDNS response.
    static func mdnsAddresses(in response: [UInt8]) -> [String] {
        guard response.count >= 12 else { return [] }
        func read16(_ offset: Int) -> Int { (Int(response[offset]) << 8) | Int(response[offset + 1]) }
        // Skips a possibly compressed name; a compression pointer always terminates it.
        func skipName(_ offset: Int) -> Int? {
            var position = offset
            for _ in 0..<32 {
                guard position < response.count else { return nil }
                let length = Int(response[position])
                if length == 0 { return position + 1 }
                if length & 0xC0 == 0xC0 { return position + 2 }
                position += 1 + length
            }
            return nil
        }
        var position = 12
        for _ in 0..<read16(4) { // questions
            guard let end = skipName(position) else { return [] }
            position = end + 4
        }
        var addresses: [String] = []
        for _ in 0..<(read16(6) + read16(8) + read16(10)) {
            guard let end = skipName(position), end + 10 <= response.count else { break }
            let type = read16(end)
            let length = read16(end + 8)
            position = end + 10
            guard position + length <= response.count else { break }
            if type == 1 && length == 4 {
                addresses.append("\(response[position]).\(response[position + 1])"
                             + ".\(response[position + 2]).\(response[position + 3])")
            }
            position += length
        }
        return addresses
    }

    /// Sends the mDNS query to `destination` and collects the unique A-record addresses that
    /// answer within `timeout`.
    static func mdnsCandidates(hostnames: [String] = mdnsHostnames, timeout: TimeInterval = 0.6,
                               destination: (host: String, port: UInt16) = ("224.0.0.251", 5353)) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { _ = close(fd) }
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(destination.port).bigEndian
        target.sin_addr = in_addr(s_addr: inet_addr(destination.host))
        let query = mdnsQuery(hostnames: hostnames)
        let sent = query.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        var addresses: Set<String> = []
        var buffer = [UInt8](repeating: 0, count: 1500)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(max(1, remaining * 1000)))
            if ready == 0 { break }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { continue }
            addresses.formUnion(mdnsAddresses(in: Array(buffer.prefix(count))))
        }
        return addresses.sorted()
    }

    /// The IPv4 interface list and the usable host addresses of each subnet.
    public static func localIPv4Networks() -> [IPv4Network] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var result: [IPv4Network] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addressPointer = current.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPointer = current.pointee.ifa_netmask else { continue }
            let address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard mask != 0 else { continue }
            let network = address & mask
            let broadcast = network | ~mask
            let count = Int64(broadcast) - Int64(network) - 1
            guard count > 0, count <= Int64(maxHostsPerNetwork) else { continue }
            var hosts: [String] = []
            hosts.reserveCapacity(Int(count))
            var candidate = network &+ 1
            while candidate < broadcast {
                if candidate != address { hosts.append(ipv4String(candidate)) }
                candidate &+= 1
            }
            let name = String(cString: current.pointee.ifa_name)
            result.append(IPv4Network(interfaceName: name,
                                      address: ipv4String(address),
                                      netmask: ipv4String(mask),
                                      prefixLength: mask.nonzeroBitCount,
                                      hosts: hosts))
        }
        return result
    }

    private static func ipv4String(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}
