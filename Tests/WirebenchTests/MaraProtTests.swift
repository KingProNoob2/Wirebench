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

/// A synchronous Duino-S stand-in at the frame level.
private final class FakeDuino: MaraProtTransport {
    var receivedChunks = 0
    var started = false
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
