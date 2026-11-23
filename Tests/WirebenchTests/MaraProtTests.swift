import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import WirebenchHardware

#if !canImport(Darwin)
@_silgen_name("posix_openpt") private func posix_openpt(_ flags: Int32) -> Int32
@_silgen_name("grantpt") private func grantpt(_ fd: Int32) -> Int32
@_silgen_name("unlockpt") private func unlockpt(_ fd: Int32) -> Int32
@_silgen_name("ptsname") private func ptsname(_ fd: Int32) -> UnsafeMutablePointer<CChar>?
#endif

@Suite("MaraProt v1")
struct MaraProtTests {
    @Test("CRC-16 and CRC-32 match their published check values")
    func checksums() {
        let digits = Array("123456789".utf8)
        #expect(MaraProtFrame.crc16(digits) == 0x29B1)
        #expect(MaraProtFrame.crc32(digits) == 0xCBF4_3926)
    }

    @Test("A request frame round-trips with its sequence, station and payload")
    func frameRoundTrip() throws {
        let frame = MaraProtFrame(sequence: 0x1234, stationId: 0, opcode: MaraProt.Opcode.ping.rawValue,
                                  payload: [0x01, 0x02, 0x03, 0x04])
        let encoded = try frame.encoded()
        #expect(encoded.count == 10 + 4 + 2)
        #expect(encoded[0] == 0x4D && encoded[1] == 0x50)
        #expect(MaraProtFrame.frameLength(from: encoded) == encoded.count)
        let decoded = try MaraProtFrame.decode(encoded)
        #expect(decoded.sequence == 0x1234)
        #expect(decoded.stationId == 0)
        #expect(decoded.opcode == MaraProt.Opcode.ping.rawValue)
        #expect(decoded.payload == [0x01, 0x02, 0x03, 0x04])
        #expect(!decoded.isResponse)
    }

    @Test("A corrupted frame is rejected")
    func corruptFrame() throws {
        var encoded = try MaraProtFrame(sequence: 1, stationId: 0, opcode: 0x01, payload: [1]).encoded()
        encoded[encoded.count - 1] ^= 0xFF
        #expect(throws: MaraProtFrame.FrameError.self) {
            try MaraProtFrame.decode(encoded)
        }
    }

    @Test("Truncated watch and slot replies are rejected instead of becoming partial state")
    func truncatedSlotReplies() throws {
        let watch = MaraProtClient(transport: PayloadTransport(payload: [1, 0, 0, 0, 1, 0, 0, 0]))
        #expect(throws: MaraProtClient.ClientError.self) {
            _ = try watch.watchPoll(ackEpoch: 0)
        }
        let read = MaraProtClient(transport: PayloadTransport(payload: [1, 0, 0, 0]))
        #expect(throws: MaraProtClient.ClientError.self) {
            _ = try read.readSlots([0])
        }
    }

    @Test("A slot snapshot cannot omit a requested slot")
    func missingSlotSnapshot() throws {
        let client = MaraProtClient(transport: PayloadTransport(payload: [0, 0]))
        #expect(throws: MaraProtClient.ClientError.self) {
            _ = try client.readSlots([0x4001])
        }
    }

    @Test("Slot writes reject wrong-width values and partially applied batches")
    func invalidSlotWrites() throws {
        let wrongWidth = MaraProtClient(transport: PayloadTransport(payload: [0, 0]))
        #expect(throws: MaraProtClient.ClientError.self) {
            _ = try wrongWidth.writeSlots([0x4001: [1, 0]])
        }
        let partial = MaraProtClient(transport: PayloadTransport(payload: [0, 0]))
        #expect(throws: MaraProtClient.ClientError.self) {
            _ = try partial.writeSlots([0: [1], 0x4001: [42, 0, 0, 0]])
        }
    }

    @Test("The Ethernet transport carries a frame over TCP and back")
    func ethernetTransport() throws {
        let server = try FakeTCPServer()
        defer { server.stop() }
        let transport = MaraTCPTransport(host: "127.0.0.1", port: server.port)
        let client = MaraProtClient(transport: transport)
        try client.connect()
        defer { client.close() }
        let ping = try client.ping(echo: 0xA1B2C3D4)
        #expect(ping.echo == 0xA1B2C3D4)
        #expect(ping.uptimeMilliseconds == 77)
    }

    @Test("The USB CDC transport carries a frame over a serial port and back")
    func serialTransport() throws {
        let device = try FakeSerialDuino()
        defer { device.stop() }
        let transport = MaraSerialTransport(path: device.slavePath)
        let client = MaraProtClient(transport: transport)
        try client.connect()
        defer { client.close() }
        let ping = try client.ping(echo: 0x01020304)
        #expect(ping.echo == 0x01020304)
        #expect(ping.uptimeMilliseconds == 99)
    }

    @Test("An mDNS query asks for each known hostname with the unicast-response bit")
    func mdnsQueryCodec() {
        let query = MaraDiscovery.mdnsQuery(hostnames: ["duinos", "lwip"])
        #expect(query.count == 46)
        #expect(query[4] == 0 && query[5] == 2) // two questions
        #expect(Array(query[12...18]) == [6] + Array("duinos".utf8))
        #expect(Array(query[19...24]) == [5] + Array("local".utf8))
        #expect(Array(query[26...29]) == [0x00, 0x01, 0x80, 0x01]) // A record, IN class + QU
        #expect(Array(query[30...34]) == [4] + Array("lwip".utf8))
        #expect(Array(query[35...40]) == [5] + Array("local".utf8))
        #expect(Array(query[42...45]) == [0x00, 0x01, 0x80, 0x01])
        // The default query covers the current firmware hostname and the earlier name.
        let defaults = MaraDiscovery.mdnsQuery()
        #expect(defaults[5] == 3) // three questions: duinos, f407plc, lwip
        #expect(Array(defaults[12...18]) == [6] + Array("duinos".utf8))
        #expect(Array(defaults[30...37]) == [7] + Array("f407plc".utf8))
    }

    @Test("An mDNS response yields the A records from its answer and additional sections")
    func mdnsResponseParsing() {
        // One question "duino-s.local", one answer with a compressed name, one additional record.
        var response = MaraDiscovery.mdnsQuery(hostnames: ["duino-s"])
        response[2] = 0x84; response[3] = 0x00 // authoritative answer
        response[6] = 0x00; response[7] = 0x01 // one answer
        response[8] = 0x00; response[9] = 0x01 // one additional record
        response += [0xC0, 0x0C,             // name: pointer to the question
                     0x00, 0x01, 0x00, 0x01, // type A, class IN
                     0x00, 0x00, 0x00, 0x78, // TTL
                     0x00, 0x04, 192, 168, 1, 50,
                     0xC0, 0x0C,
                     0x00, 0x01, 0x00, 0x01,
                     0x00, 0x00, 0x00, 0x78,
                     0x00, 0x04, 10, 0, 0, 7]
        #expect(MaraDiscovery.mdnsAddresses(in: response) == ["192.168.1.50", "10.0.0.7"])
        #expect(MaraDiscovery.mdnsAddresses(in: [0, 1, 2]) == [])
    }

    @Test("mDNS discovery validates an answering board through GET_INFO")
    func mdnsDiscovery() throws {
        let responder = try FakeMdnsResponder()
        defer { responder.stop() }
        let server = try FakeTCPServer()
        defer { server.stop() }
        let devices = MaraDiscovery.discoverViaMdns(port: server.port, probeTimeout: 0.5, mdnsTimeout: 1,
                                                    destination: ("127.0.0.1", responder.port))
        #expect(devices.count == 1)
        #expect(devices.first?.endpoint == "127.0.0.1")
        #expect(devices.first?.info.modelId == 0x0407)
        #expect(responder.answered)
    }

    @Test("mDNS discovery with no answers finds nothing without falling back to a scan")
    func mdnsDiscoverySilent() {
        // Nothing listens on this port, so no board answers and the mDNS stage returns empty.
        let devices = MaraDiscovery.discoverViaMdns(port: 5020, probeTimeout: 0.2, mdnsTimeout: 0.3,
                                                    destination: ("127.0.0.1", 54399))
        #expect(devices.isEmpty)
    }

    @Test("A loopback scan finds a Duino-S by its GET_INFO identity")
    func discoveryProbe() throws {
        let server = try FakeTCPServer()
        defer { server.stop() }
        let network = MaraDiscovery.IPv4Network(interfaceName: "loopback", address: "127.0.0.1",
                                                netmask: "255.255.255.255", prefixLength: 32,
                                                hosts: ["127.0.0.1"])
        let found = MaraDiscovery.scanLocalNetwork(port: server.port, timeout: 0.5, networks: [network])
        #expect(found.count == 1)
        #expect(found.first?.info.modelId == 0x0407)
        #expect(found.first?.endpoint == "127.0.0.1")
    }

    @Test("Discovery does not claim a different TCP service as a Duino-S")
    func discoveryRejectsOtherDevice() throws {
        let server = try FakeTCPServer(modelID: 0x1234, modelName: "Other")
        defer { server.stop() }
        #expect(MaraDiscovery.probe(host: "127.0.0.1", port: server.port) == nil)
    }

    @Test("The client reads and sets the RTC, scans 1-Wire and enters ROM DFU")
    func rtcOneWireDfu() throws {
        let device = FakeDuino()
        let client = MaraProtClient(transport: device)
        try client.connect()
        #expect(try client.rtcGet() == 1_735_689_000)
        try client.rtcSet(unixSeconds: 1_700_000_000)
        #expect(device.rtcSetSeconds == 1_700_000_000)
        let roms = try client.oneWireScan(dioPin: 7)
        #expect(device.oneWirePin == 7)
        #expect(roms == [0x2801_2345_6789_ABCD, 0x28FF_AABB_CCDD_EEFF])
        try client.enterROMDFU()
        #expect(device.dfuMagic == 0xDF00B007)
    }

    @Test("The client performs PING, GET_INFO and a chunked image upload")
    func clientOperations() throws {
        let device = FakeDuino()
        let client = MaraProtClient(transport: device)
        try client.connect()
        let ping = try client.ping(echo: 0xDEADBEEF)
        #expect(ping.echo == 0xDEADBEEF)
        #expect(ping.uptimeMilliseconds == 1234)

        let info = try client.info()
        #expect(info.modelId == 0x0407)
        #expect(info.modelName == "Duino - S")
        #expect(info.maxMtuBytes == 520)

        let status = try client.vmStatus()
        #expect(status.scanCount == 7)
        #expect(status.threadActualMicroseconds == [1, 2, 3, 4, 5])

        var progress: [Double] = []
        let image = [UInt8](repeating: 0x5A, count: 200)
        let upload = try client.uploadImage(image, autoStart: true, progress: { progress.append($0) })
        #expect(upload.chunks == 4)
        #expect(upload.runState == .running)
        #expect(device.receivedChunks == 200)
        #expect(progress.last == 1)
        #expect(device.started)

        let epoch = try client.watchSubscribe([0, 0x4001])
        let snapshot = try client.watchPoll(ackEpoch: 0)
        #expect(snapshot.changedSlots.count == 2)
        _ = try client.writeSlots([0: [1], 0x4001: [42, 0, 0, 0]])
        let update = try client.watchPoll(ackEpoch: epoch)
        #expect(update.changedSlots[0] == [1])
        #expect(update.changedSlots[0x4001]?.count == 4)
        let read = try client.readSlots([0, 0x4001])
        #expect(read[0] == [1])
        #expect(read[0x4001] == [42, 0, 0, 0])
    }
}

/// A one-connection TCP server for the Ethernet transport test.
private final class FakeTCPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private var running = true
    private let modelID: UInt16
    private let modelName: String

    init(modelID: UInt16 = 0x0407, modelName: String = "Duino - S") throws {
        self.modelID = modelID
        self.modelName = modelName
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }
        listener = socketFD
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 1) == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actual = sockaddr_in()
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() { running = false; _ = close(listener) }

    private func serve() {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { _ = close(connection) }
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while running {
            let count = read(connection, &buffer, buffer.count)
            if count <= 0 { return }
            pending += buffer.prefix(count)
            while let total = MaraProtFrame.frameLength(from: pending), pending.count >= total {
                guard let request = try? MaraProtFrame.decode(Array(pending.prefix(total))) else { return }
                pending.removeFirst(total)
                let payload: [UInt8]
                switch MaraProt.Opcode(rawValue: request.opcode) {
                case .ping:
                    payload = request.payload + [77, 0, 0, 0]
                case .getInfo:
                    var info = [UInt8](repeating: 0, count: 44)
                    info[0] = 1
                    info[2] = UInt8(truncatingIfNeeded: modelID)
                    info[3] = UInt8(truncatingIfNeeded: modelID >> 8)
                    info[8] = MaraProt.TransportKind.tcpIP.rawValue
                    info[9] = 0x08; info[10] = 0x02
                    let name = Array(modelName.utf8)
                    info.replaceSubrange(20..<(20 + min(24, name.count)), with: name.prefix(24))
                    payload = info
                default:
                    payload = []
                }
                let reply = MaraProtFrame(sequence: request.sequence, stationId: request.stationId,
                                          opcode: request.opcode, payload: payload, isResponse: true)
                guard let bytes = try? reply.encoded() else { return }
                _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, bytes.count) }
            }
        }
    }
}

/// The Duino-S end of a pty pair: complete MaraProt frames in, PING replies out.
private final class FakeSerialDuino: @unchecked Sendable {
    let slavePath: String
    private let master: Int32
    private var running = true

    init() throws {
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else { throw POSIXError(.EIO) }
        master = m
        slavePath = String(cString: name)
        _ = fcntl(m, F_SETFL, fcntl(m, F_GETFL) | O_NONBLOCK)
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() { running = false; _ = close(master) }

    private func serve() {
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while running {
            let n = read(master, &buffer, buffer.count)
            if n > 0 { pending += buffer.prefix(n) } else { usleep(500) }
            while let total = MaraProtFrame.frameLength(from: pending), pending.count >= total {
                let request = try? MaraProtFrame.decode(Array(pending.prefix(total)))
                pending.removeFirst(total)
                guard let request, request.opcode == MaraProt.Opcode.ping.rawValue else { continue }
                let reply = MaraProtFrame(sequence: request.sequence, stationId: request.stationId,
                                          opcode: request.opcode,
                                          payload: request.payload + [99, 0, 0, 0],
                                          isResponse: true)
                if let bytes = try? reply.encoded() {
                    _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, bytes.count) }
                }
            }
        }
    }
}

private final class PayloadTransport: MaraProtTransport {
    let payload: [UInt8]
    init(payload: [UInt8]) { self.payload = payload }
    func open() throws {}
    func close() {}
    func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        let request = try MaraProtFrame.decode(frame)
        return try MaraProtFrame(sequence: request.sequence, stationId: request.stationId,
                                 opcode: request.opcode, payload: payload, isResponse: true).encoded()
    }
}

/// A synchronous Duino-S stand-in at the frame level.
private final class FakeDuino: MaraProtTransport {
    var receivedChunks = 0
    var started = false
    var rtcSetSeconds: Int64?
    var oneWirePin: UInt8?
    var dfuMagic: UInt32?
    private var watchSlots: [UInt16] = []
    private var watchEpoch: UInt16 = 0
    private var changed: Set<UInt16> = []
    private var slotValues: [UInt16: [UInt8]] = [:]
    private var beginCRC: UInt32 = 0
    private var expectedLength = 0
    private var bytes: [UInt8] = []

    func open() throws {}
    func close() {}

    func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        let request = try MaraProtFrame.decode(frame)
        let opcode = MaraProt.Opcode(rawValue: request.opcode)
        let payload: [UInt8]
        var status: UInt8 = 0
        switch opcode {
        case .ping:
            payload = request.payload + [0xD2, 0x04, 0x00, 0x00]
        case .getInfo:
            var info = [UInt8](repeating: 0, count: 44)
            info[0] = 1; info[1] = 0
            info[2] = 0x07; info[3] = 0x04
            info[8] = MaraProt.TransportKind.usbCDC.rawValue
            info[9] = 0x08; info[10] = 0x02
            info[11] = MaraProt.VMRunState.stopped.rawValue
            let name = Array("Duino - S".utf8)
            info.replaceSubrange(20..<(20 + name.count), with: name)
            payload = info
        case .vmStatus:
            var statusBytes = [UInt8](repeating: 0, count: 32)
            statusBytes[0] = MaraProt.VMRunState.running.rawValue
            statusBytes[4] = 7
            for index in 0..<5 { statusBytes[8 + index * 4] = UInt8(index + 1) }
            payload = statusBytes
        case .uploadBegin:
            expectedLength = Int(request.payload[0]) | (Int(request.payload[1]) << 8)
                | (Int(request.payload[2]) << 16) | (Int(request.payload[3]) << 24)
            beginCRC = UInt32(request.payload[4]) | (UInt32(request.payload[5]) << 8)
                | (UInt32(request.payload[6]) << 16) | (UInt32(request.payload[7]) << 24)
            bytes = []
            payload = [0x40, 0x00] // 64-byte chunks
        case .uploadChunk:
            let offset = Int(request.payload[0]) | (Int(request.payload[1]) << 8)
                | (Int(request.payload[2]) << 16) | (Int(request.payload[3]) << 24)
            let chunk = Array(request.payload[4...])
            if offset == bytes.count {
                bytes += chunk
                receivedChunks += chunk.count
            }
            let next = UInt32(bytes.count)
            payload = [UInt8(truncatingIfNeeded: next), UInt8(truncatingIfNeeded: next >> 8),
                       UInt8(truncatingIfNeeded: next >> 16), UInt8(truncatingIfNeeded: next >> 24)]
        case .uploadCommit:
            started = request.payload.first != 0
            let crc = bytes.count >= 72 ? UInt32(bytes[12]) | (UInt32(bytes[13]) << 8)
                | (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 24) : 0
            payload = [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8),
                       UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 24),
                       started ? MaraProt.VMRunState.running.rawValue : MaraProt.VMRunState.stopped.rawValue]
        case .watchSubscribe:
            let append = request.payload.first == 1
            if !append { watchSlots.removeAll() }
            let count = Int(request.payload[1]) | (Int(request.payload[2]) << 8)
            var position = 3
            for _ in 0..<count {
                let slot = UInt16(request.payload[position]) | (UInt16(request.payload[position + 1]) << 8)
                watchSlots.append(slot)
                position += 2
            }
            watchEpoch &+= 1
            changed = Set(watchSlots)
            payload = [UInt8(truncatingIfNeeded: watchSlots.count), UInt8(truncatingIfNeeded: watchSlots.count >> 8),
                       UInt8(truncatingIfNeeded: watchEpoch), UInt8(truncatingIfNeeded: watchEpoch >> 8)]
        case .watchPoll:
            let acknowledged = UInt16(request.payload[0]) | (UInt16(request.payload[1]) << 8)
            let emit = acknowledged == 0 || acknowledged != watchEpoch ? Set(watchSlots) : changed
            changed.removeAll()
            var body: [UInt8] = []
            for slot in emit.sorted() {
                let value = slotValues[slot] ?? [UInt8](repeating: 0, count: MaraProtClient.slotSize(slot))
                body += [UInt8(truncatingIfNeeded: slot), UInt8(truncatingIfNeeded: slot >> 8)]
                body += value
            }
            payload = [UInt8(truncatingIfNeeded: watchEpoch), UInt8(truncatingIfNeeded: watchEpoch >> 8),
                       MaraProt.VMRunState.running.rawValue, 0,
                       UInt8(truncatingIfNeeded: emit.count), UInt8(truncatingIfNeeded: emit.count >> 8)] + body
        case .slotReadBatch:
            let count = Int(request.payload[0]) | (Int(request.payload[1]) << 8)
            var body: [UInt8] = []
            var position = 2
            for _ in 0..<count {
                let slot = UInt16(request.payload[position]) | (UInt16(request.payload[position + 1]) << 8)
                position += 2
                body += [UInt8(truncatingIfNeeded: slot), UInt8(truncatingIfNeeded: slot >> 8)]
                body += slotValues[slot] ?? [UInt8](repeating: 0, count: MaraProtClient.slotSize(slot))
            }
            payload = [UInt8(truncatingIfNeeded: count), UInt8(truncatingIfNeeded: count >> 8)] + body
        case .slotWriteBatch:
            let count = Int(request.payload[0]) | (Int(request.payload[1]) << 8)
            var position = 2
            for _ in 0..<count {
                let slot = UInt16(request.payload[position]) | (UInt16(request.payload[position + 1]) << 8)
                position += 2
                let size = MaraProtClient.slotSize(slot)
                slotValues[slot] = Array(request.payload[position..<(position + size)])
                changed.insert(slot)
                position += size
            }
            payload = [UInt8(truncatingIfNeeded: count), UInt8(truncatingIfNeeded: count >> 8)]
        case .rtcGet:
            let seconds = UInt64(bitPattern: 1_735_689_000)
            payload = (0..<8).map { UInt8(truncatingIfNeeded: seconds >> ($0 * 8)) }
        case .rtcSet:
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(request.payload[index]) << (index * 8) }
            rtcSetSeconds = Int64(bitPattern: value)
            payload = []
        case .oneWireScan:
            oneWirePin = request.payload.first ?? 13
            var roms: [UInt8] = [2]
            for rom in [UInt64(0x2801_2345_6789_ABCD), UInt64(0x28FF_AABB_CCDD_EEFF)] {
                roms += (0..<8).map { UInt8(truncatingIfNeeded: rom >> ($0 * 8)) }
            }
            payload = roms
        case .enterRomDfu:
            let magic = UInt32(request.payload[0]) | (UInt32(request.payload[1]) << 8)
                | (UInt32(request.payload[2]) << 16) | (UInt32(request.payload[3]) << 24)
            dfuMagic = magic
            payload = [magic == 0xDF00B007 ? 1 : 0]
        default:
            status = MaraProt.Status.opcode.rawValue
            payload = []
        }
        _ = beginCRC
        let reply = MaraProtFrame(sequence: request.sequence, stationId: request.stationId,
                                  opcode: request.opcode, payload: payload,
                                  isResponse: true, isError: status != 0, status: status)
        return try reply.encoded()
    }
}

/// A stand-in lwIP mDNS responder: answers any query with an A record for 127.0.0.1, sent
/// unicast to the querier the way the QU bit asks.
private final class FakeMdnsResponder: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private var running = true
    private(set) var answered = false

    init() throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }
        fd = socketFD
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actual = sockaddr_in()
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() { running = false; _ = close(fd) }

    private func serve() {
        var buffer = [UInt8](repeating: 0, count: 1500)
        var source = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let received = withUnsafeMutablePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
            }
        }
        guard received >= 12 else { return }
        answered = true
        // Keep the question section, mark the packet an authoritative answer with one A record.
        var response = Array(buffer.prefix(received))
        response[2] = 0x84; response[3] = 0x00
        response[6] = 0x00; response[7] = 0x01
        response += [0xC0, 0x0C,             // name: pointer to the question
                     0x00, 0x01, 0x00, 0x01, // type A, class IN
                     0x00, 0x00, 0x00, 0x78, // TTL
                     0x00, 0x04, 127, 0, 0, 1]
        _ = withUnsafePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                response.withUnsafeBytes { bytes in
                    sendto(fd, bytes.baseAddress, response.count, 0, address, length)
                }
            }
        }
    }
}
