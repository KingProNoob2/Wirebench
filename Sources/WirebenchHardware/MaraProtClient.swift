import Foundation

/// A MaraProt transport: one request frame out, one response frame back.
public protocol MaraProtTransport: AnyObject {
    func open() throws
    func close()
    func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8]
}

/// USB CDC and RS-485 both arrive as a byte stream; only the way the port is opened differs.
public final class MaraSerialTransport: MaraProtTransport, @unchecked Sendable {
    private let port: SerialPort
    private let path: String
    private let baudRate: Int
    private let parity: SerialPort.Parity

    public init(path: String, baudRate: Int = 115200, parity: SerialPort.Parity = .none) {
        self.port = SerialPort()
        self.path = path
        self.baudRate = baudRate
        self.parity = parity
    }

    public func open() throws {
        try port.open(path: path, baudRate: baudRate, parity: parity)
    }

    public func close() { port.close() }

    public func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        port.discardInput()
        _ = try port.write(data: Data(frame))

        let deadline = Date().addingTimeInterval(timeout)
        var received: [UInt8] = []
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw MaraProtClient.ClientError.timeout
            }
            guard port.waitReadable(timeout: remaining) else { continue }
            if let chunk = try? port.read(maxBytes: 1024), !chunk.isEmpty {
                received.append(contentsOf: chunk)
                if let total = MaraProtFrame.frameLength(from: received), received.count >= total {
                    return Array(received.prefix(total))
                }
            }
        }
    }
}

/// A thin timeout wrapper for an already-open serial port, used when the caller owns the port.
public final class MaraStreamTransport: MaraProtTransport, @unchecked Sendable {
    private let read: (Int, TimeInterval) throws -> [UInt8]
    private let write: ([UInt8]) throws -> Void
    private let closeHandler: () -> Void

    public init(read: @escaping (Int, TimeInterval) throws -> [UInt8],
                write: @escaping ([UInt8]) throws -> Void,
                close: @escaping () -> Void = {}) {
        self.read = read
        self.write = write
        self.closeHandler = close
    }

    public func open() throws {}
    public func close() { closeHandler() }

    public func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        try write(frame)
        var received: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw MaraProtClient.ClientError.timeout }
            let chunk = try read(1024, remaining)
            if chunk.isEmpty { continue }
            received.append(contentsOf: chunk)
            if let total = MaraProtFrame.frameLength(from: received), received.count >= total {
                return Array(received.prefix(total))
            }
        }
    }
}

public final class MaraProtClient: @unchecked Sendable {
    public enum ClientError: Error, LocalizedError, Equatable {
        case timeout
        case malformedResponse(String)
        case status(MaraProt.Status)
        case deviceError(MaraProt.Status)
        case sequenceMismatch(expected: UInt16, got: UInt16)
        case unexpectedOpcode(expected: UInt8, got: UInt8)
        case uploadRejected(String)
        case imageTooLarge(Int)

        public var errorDescription: String? {
            switch self {
            case .timeout: return "The Duino-S did not answer before the timeout."
            case .malformedResponse(let detail): return "The Duino-S sent a malformed response: \(detail)."
            case .status(let status): return "The Duino-S rejected the request: \(status.text)."
            case .deviceError(let status): return "The Duino-S reported an error: \(status.text)."
            case .sequenceMismatch(let expected, let got): return "MaraProt sequence mismatch: expected \(expected), got \(got)."
            case .unexpectedOpcode(let expected, let got): return "MaraProt opcode mismatch: expected \(expected), got \(got)."
            case .uploadRejected(let reason): return "The Duino-S rejected the image: \(reason)."
            case .imageTooLarge(let size): return "The MFLW image is \(size) bytes; the Duino-S accepts at most 28672."
            }
        }
    }

    public struct Info: Equatable, Sendable {
        public var protocolVersion: UInt16
        public var modelId: UInt16
        public var firmwareVersion: UInt32
        public var transport: MaraProt.TransportKind
        public var maxMtuBytes: UInt16
        public var vmState: MaraProt.VMRunState
        public var imageCrc32: UInt32
        public var projectHash: UInt32
        public var modelName: String
    }

    public struct VMStatus: Equatable, Sendable {
        public var runState: MaraProt.VMRunState
        public var eStopActive: Bool
        public var eStopMask: UInt16
        public var scanCount: UInt32
        public var threadActualMicroseconds: [UInt32]
        public var lastFaultCode: UInt16
        public var lastFaultPC: UInt16
    }

    public struct UploadResult: Equatable, Sendable {
        public var payloadCrc32: UInt32
        public var runState: MaraProt.VMRunState
        public var chunks: Int
    }

    public struct WatchUpdate: Equatable, Sendable {
        public var epoch: UInt16
        public var runState: MaraProt.VMRunState
        public var eStopActive: Bool
        /// Only the slots whose value changed since the acknowledged epoch. A poll with a stale epoch
        /// returns the whole subscribed list.
        public var changedSlots: [UInt16: [UInt8]]
    }

    public let transport: MaraProtTransport
    public var stationId: UInt8
    public var timeout: TimeInterval = 2.0
    public private(set) var sequence: UInt16 = 0

    public init(transport: MaraProtTransport, stationId: UInt8 = 0) {
        self.transport = transport
        self.stationId = stationId
    }

    public func connect() throws { try transport.open() }
    public func close() { transport.close() }

    /// The address to use for a point-to-point USB CDC link: 0 (P2P) is what the Duino-S accepts.
    public static let pointToPointStation: UInt8 = 0

    public func ping(echo: UInt32 = 0) throws -> (echo: UInt32, uptimeMilliseconds: UInt32) {
        let payload = try transceive(.ping, le32(echo), timeout: timeout)
        guard payload.count >= 8 else { throw ClientError.malformedResponse("PING returned \(payload.count) bytes") }
        return (readLE32(payload, 0), readLE32(payload, 4))
    }

    public func info() throws -> Info {
        let payload = try transceive(.getInfo, [], timeout: timeout)
        guard payload.count >= 44 else { throw ClientError.malformedResponse("GET_INFO returned \(payload.count) bytes") }
        let nameBytes = Array(payload[20..<44])
        let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
        return Info(protocolVersion: readLE16(payload, 0),
                    modelId: readLE16(payload, 2),
                    firmwareVersion: readLE32(payload, 4),
                    transport: MaraProt.TransportKind(rawValue: payload[8]) ?? .usbCDC,
                    maxMtuBytes: readLE16(payload, 9),
                    vmState: MaraProt.VMRunState(rawValue: payload[11]) ?? .stopped,
                    imageCrc32: readLE32(payload, 12),
                    projectHash: readLE32(payload, 16),
                    modelName: name)
    }

    public func vmStatus() throws -> VMStatus {
        let payload = try transceive(.vmStatus, [], timeout: timeout)
        guard payload.count >= 32 else { throw ClientError.malformedResponse("VM_STATUS returned \(payload.count) bytes") }
        let actual = (0..<5).map { readLE32(payload, 8 + $0 * 4) }
        return VMStatus(runState: MaraProt.VMRunState(rawValue: payload[0]) ?? .stopped,
                        eStopActive: payload[1] != 0,
                        eStopMask: readLE16(payload, 2),
                        scanCount: readLE32(payload, 4),
                        threadActualMicroseconds: actual,
                        lastFaultCode: readLE16(payload, 28),
                        lastFaultPC: readLE16(payload, 30))
    }

    public func controlVM(_ action: UInt8) throws -> MaraProt.VMRunState {
        let payload = try transceive(.vmControl, [action], timeout: timeout)
        guard let state = payload.first.flatMap(MaraProt.VMRunState.init(rawValue:)) else {
            throw ClientError.malformedResponse("VM_CONTROL returned \(payload.count) bytes")
        }
        return state
    }

    /// Replaces the device's watch list with `slotIds`, chunked to the frame limit. Returns the epoch
    /// the next poll must acknowledge.
    @discardableResult
    public func watchSubscribe(_ slotIds: [UInt16]) throws -> UInt16 {
        var epoch: UInt16 = 1
        var offset = 0
        repeat {
            let count = min(250, slotIds.count - offset)
            var request: [UInt8] = [offset == 0 ? 0 : 1]
            request += le16(UInt16(count))
            for index in 0..<count { request += le16(slotIds[offset + index]) }
            let reply = try transceive(.watchSubscribe, request, timeout: timeout)
            guard reply.count >= 4 else {
                throw ClientError.malformedResponse("WATCH_SUBSCRIBE returned \(reply.count) bytes")
            }
            epoch = readLE16(reply, 2)
            offset += count
        } while offset < slotIds.count
        return epoch
    }

    /// Polls the subscribed slots. Pass the epoch returned by the previous call (or 0 for a full snapshot).
    public func watchPoll(ackEpoch: UInt16) throws -> WatchUpdate {
        let reply = try transceive(.watchPoll, le16(ackEpoch), timeout: timeout)
        guard reply.count >= 6 else {
            throw ClientError.malformedResponse("WATCH_POLL returned \(reply.count) bytes")
        }
        let epoch = readLE16(reply, 0)
        let state = MaraProt.VMRunState(rawValue: reply[2]) ?? .stopped
        let count = Int(readLE16(reply, 4))
        var changed: [UInt16: [UInt8]] = [:]
        var position = 6
        for _ in 0..<count {
            guard position + 2 <= reply.count else { break }
            let slot = readLE16(reply, position)
            position += 2
            let size = Self.slotSize(slot)
            guard size > 0, position + size <= reply.count else { break }
            changed[slot] = Array(reply[position..<(position + size)])
            position += size
        }
        return WatchUpdate(epoch: epoch, runState: state, eStopActive: reply[3] != 0, changedSlots: changed)
    }

    /// Reads a set of slots in one or more batches, for a one-shot watch snapshot.
    public func readSlots(_ slotIds: [UInt16]) throws -> [UInt16: [UInt8]] {
        var result: [UInt16: [UInt8]] = [:]
        var offset = 0
        while offset < slotIds.count {
            var count = 0
            var bytes = 2
            while offset + count < slotIds.count {
                let next = Self.slotSize(slotIds[offset + count])
                if count > 0 && bytes + 2 + next > 500 { break }
                bytes += 2 + next
                count += 1
            }
            if count == 0 { break }
            var request = le16(UInt16(count))
            for index in 0..<count { request += le16(slotIds[offset + index]) }
            let reply = try transceive(.slotReadBatch, request, timeout: timeout)
            guard reply.count >= 2 else { throw ClientError.malformedResponse("SLOT_READ_BATCH returned \(reply.count) bytes") }
            let emitted = Int(readLE16(reply, 0))
            var position = 2
            for _ in 0..<emitted {
                guard position + 2 <= reply.count else { break }
                let slot = readLE16(reply, position)
                position += 2
                let size = Self.slotSize(slot)
                guard size > 0, position + size <= reply.count else { break }
                result[slot] = Array(reply[position..<(position + size)])
                position += size
            }
            offset += count
        }
        return result
    }

    /// Writes a set of slots, for a Watch/Force control.
    @discardableResult
    public func writeSlots(_ values: [UInt16: [UInt8]]) throws -> Int {
        let entries = values.sorted { $0.key < $1.key }
        var offset = 0
        var applied = 0
        while offset < entries.count {
            var count = 0
            var bytes = 2
            while offset + count < entries.count {
                let (slot, raw) = entries[offset + count]
                if count > 0 && bytes + 2 + raw.count > 500 { break }
                bytes += 2 + raw.count
                count += 1
            }
            if count == 0 { break }
            var request = le16(UInt16(count))
            for index in 0..<count {
                request += le16(entries[offset + index].key)
                request += entries[offset + index].value
            }
            let reply = try transceive(.slotWriteBatch, request, timeout: timeout)
            guard reply.count >= 2 else { throw ClientError.malformedResponse("SLOT_WRITE_BATCH returned \(reply.count) bytes") }
            applied += Int(readLE16(reply, 0))
            offset += count
        }
        return applied
    }

    /// The byte width of a type-tagged slot.
    public static func slotSize(_ slot: UInt16) -> Int {
        switch (slot >> 14) & 0x3 {
        case 0: return 1
        case 1: return 4
        case 2: return 8
        default: return 4
        }
    }

    /// Uploads a complete MFLW image. The image itself carries its payload CRC in its header; the
    /// handshake also sends the CRC of the whole image, which is what the device verifies at commit.
    @discardableResult
    public func uploadImage(_ image: [UInt8], autoStart: Bool,
                            progress: ((Double) -> Void)? = nil) throws -> UploadResult {
        guard image.count <= 28_672 else { throw ClientError.imageTooLarge(image.count) }
        guard image.count >= 72 else { throw ClientError.uploadRejected("image is shorter than the 72-byte header") }
        let fullCRC = MaraProtFrame.crc32(image)
        // Commit answers with the MFLW header's payload CRC (from byte 72), while BEGIN takes the CRC
        // of the whole image: the firmware checks the latter and reports the former.
        let payloadCRC = UInt32(image[12]) | (UInt32(image[13]) << 8)
            | (UInt32(image[14]) << 16) | (UInt32(image[15]) << 24)
        var begin = le32(UInt32(image.count))
        begin += le32(fullCRC)
        let beginReply = try transceive(.uploadBegin, begin, timeout: timeout)
        guard beginReply.count >= 2 else {
            throw ClientError.malformedResponse("UPLOAD_BEGIN returned \(beginReply.count) bytes")
        }
        let maxChunk = max(1, Int(readLE16(beginReply, 0)))
        var offset = 0
        var chunks = 0
        while offset < image.count {
            let count = min(maxChunk, image.count - offset)
            var request = le32(UInt32(offset))
            request += image[offset..<(offset + count)]
            let reply = try transceive(.uploadChunk, request, timeout: max(timeout, 3.0))
            guard reply.count >= 4 else {
                throw ClientError.malformedResponse("UPLOAD_CHUNK returned \(reply.count) bytes")
            }
            let next = Int(readLE32(reply, 0))
            guard next == offset + count || next == offset else {
                throw ClientError.uploadRejected("chunk \(chunks) ended at \(next), expected \(offset + count)")
            }
            offset = next == offset ? offset + count : next
            chunks += 1
            progress?(Double(offset) / Double(image.count))
        }
        let commit = try transceive(.uploadCommit, [autoStart ? 1 : 0], timeout: max(timeout, 3.0))
        guard commit.count >= 5 else {
            throw ClientError.malformedResponse("UPLOAD_COMMIT returned \(commit.count) bytes")
        }
        let imageCRC = readLE32(commit, 0)
        let state = MaraProt.VMRunState(rawValue: commit[4]) ?? .stopped
        guard imageCRC == payloadCRC else {
            throw ClientError.uploadRejected("commit payload CRC \(imageCRC) does not match \(payloadCRC)")
        }
        progress?(1)
        return UploadResult(payloadCrc32: imageCRC, runState: state, chunks: chunks)
    }

    @discardableResult
    private func transceive(_ opcode: MaraProt.Opcode, _ payload: [UInt8],
                            timeout: TimeInterval) throws -> [UInt8] {
        sequence &+= 1
        let request = MaraProtFrame(sequence: sequence, stationId: stationId,
                                    opcode: opcode.rawValue, payload: payload)
        let bytes = try request.encoded()
        let replyBytes = try transport.exchange(bytes, timeout: timeout)
        let reply = try MaraProtFrame.decode(replyBytes)
        guard reply.sequence == sequence else {
            throw ClientError.sequenceMismatch(expected: sequence, got: reply.sequence)
        }
        guard reply.opcode == opcode.rawValue else {
            throw ClientError.unexpectedOpcode(expected: opcode.rawValue, got: reply.opcode)
        }
        if reply.status != 0 || reply.isError {
            throw ClientError.deviceError(MaraProt.Status(rawValue: reply.status) ?? .parameter)
        }
        return reply.payload
    }

    private func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
    }

    private func readLE16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
