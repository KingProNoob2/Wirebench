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
/// The firmware starts lwIP with DHCP but does **not** enable `LWIP_MDNS_RESPONDER` or
/// `LWIP_NETBIOS_RESPONDER` (both default to 0 in `lwipopts.h`), and its netif hostname is 0. There
/// is therefore no broadcast discovery service to ask. What the board does expose is the MaraProt
/// `GET_INFO` opcode on TCP 5020, whose model ID is `0x0407` and model name `"Duino - S"`.
/// Discovery scans the local IPv4 subnets for open 5020 sockets and accepts only that identity.
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

    /// Scans every local IPv4 subnet that is small enough to probe. The scan runs in parallel and is
    /// expected to be called off the main thread.
    public static func scanLocalNetwork(port: UInt16 = defaultPort,
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
