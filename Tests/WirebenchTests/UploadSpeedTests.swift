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
// glibc declares the pseudo-terminal calls behind `_XOPEN_SOURCE`, which its Swift module does not set.
@_silgen_name("posix_openpt") private func posix_openpt(_ flags: Int32) -> Int32
@_silgen_name("grantpt") private func grantpt(_ fd: Int32) -> Int32
@_silgen_name("unlockpt") private func unlockpt(_ fd: Int32) -> Int32
@_silgen_name("ptsname") private func ptsname(_ fd: Int32) -> UnsafeMutablePointer<CChar>?
#endif

/// How long an upload takes over a real (pseudo-)terminal: a thread on the other end answers every request the way
/// the PLC does, with an acknowledgement, and the clock runs from the first byte to the last.
@Suite("Upload speed", .serialized)
struct UploadSpeedTests {
    /// The PLC's end of a pty pair. Answers each complete serial request with the short acknowledgement.
    final class FakePLC: @unchecked Sendable {
        let slavePath: String
        private let master: Int32
        private var running = true
        private(set) var requests = 0

        init() throws {
            // The slave is opened by path, as the app does, so only the master is held here.
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
            var buffer = [UInt8](repeating: 0, count: 512)
            while running {
                let n = read(master, &buffer, buffer.count)
                if n > 0 { pending += buffer.prefix(n) } else { usleep(500) }
                while let total = Self.length(of: pending), pending.count >= total {
                    let request = Array(pending.prefix(total))
                    pending.removeFirst(total)
                    requests += 1
                    let ack = DbNetFrame.encodeSerial(destination: request[request[0] == 0x10 ? 2 : 5],
                                                      source: request[request[0] == 0x10 ? 1 : 4], function: 0)
                    _ = ack.withUnsafeBytes { write(master, $0.baseAddress, ack.count) }
                }
            }
        }

        static func length(of bytes: [UInt8]) -> Int? {
            guard let first = bytes.first else { return nil }
            if first == 0x10 { return 6 }
            if first == 0x68, bytes.count >= 2 { return Int(bytes[1]) + 6 }
            return nil
        }
    }

    @Test("A 640-byte upload finishes in well under a second")
    func uploadIsQuick() throws {
        let plc = try FakePLC()
        defer { plc.stop() }
        let port = SerialPort()
        try port.open(path: plc.slavePath, baudRate: 57600, parity: .even)
        let session = DbNetSession(transport: SerialDbNetTransport(port: port), address: 1)
        let uploader = PLCUploader(session: session)
        let table = try PLCProgramTable(bytes: [UInt8](repeating: 0x5A, count: 640))

        let start = Date()
        let frames = try uploader.upload(table: table)
        let seconds = Date().timeIntervalSince(start)
        print("UPLOAD frames=\(frames) requests=\(plc.requests) seconds=\(seconds)")
        #expect(frames == 5)
        #expect(plc.requests == 3 + 5 + 1)
        #expect(seconds < 0.5, "took \(seconds) s")
    }
}

@Suite("Serial reply framing")
struct SerialReplyFramingTests {
    @Test("A reply is complete as soon as its own length says so")
    func lengths() {
        let ack = DbNetFrame.encodeSerial(destination: 31, source: 1, function: 0)
        #expect(ack.count == 6 && SerialDbNetTransport.serialFrameLength(of: ack) == 6)
        let long = DbNetFrame.encodeSerial(destination: 31, source: 1, function: 0x08, data: [0x81, 0x02, 0x00])
        #expect(SerialDbNetTransport.serialFrameLength(of: Array(long.prefix(3))) == nil, "not known before the header is in")
        #expect(SerialDbNetTransport.serialFrameLength(of: Array(long.prefix(4))) == long.count)
        #expect(SerialDbNetTransport.serialFrameLength(of: [0x68, 0x07, 0x09, 0x68]) == nil, "a header that disagrees is noise")
    }
}
