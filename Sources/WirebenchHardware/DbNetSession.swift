import Foundation

/// One DbNet exchange: a request frame out, a reply frame back.
///
/// Recovered from `TBaseDbnMaster.DbnTransaction` (0x41E114), which builds the body, hands it to the
/// transport's first vtable slot, then parses the reply. The transport is abstracted here for the
/// same reason `DbNetFrame` is separable from `SerialPort`: the framing and the byte stream are
/// different problems, and only one of them needs hardware.
public protocol DbNetTransport: AnyObject {
    /// Sends a frame and returns the reply frame.
    ///
    /// The reply may be shorter than a whole frame if the link fails; the caller validates it.
    func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8]
}

public enum DbNetError: Error, Equatable {
    /// The payload must be at least 3 bytes; `DbnTransaction` rejects anything shorter
    /// (`cmpl $0x3, %ebx; jl`, 0x41E126).
    case payloadTooShort
    /// The payload length must fit the single length byte.
    case payloadTooLong
    /// The peer returned the `0x1111` wait notice on every attempt
    /// (`cmpw $0x1111, 0x161(%ebx)`, 0x41BE94).
    case peerBusy
    case malformedReply(DbNetFrame.ParseFailure)
    /// The reply's sequence did not match the request's (`cmpl 0x298(%ebx)`, 0x41BEC5).
    case sequenceMismatch(expected: UInt32, got: UInt32)
    /// A write carried a value size the operation does not support.
    case badValueSize(expected: [Int], got: Int)
    /// A write reply was shorter than the three bytes the checks read.
    case shortReply
    /// The PLC's reply named a different operation than the one sent
    /// (`cmpb -0x1(%ebp), %al`, 0x41E9DE / 0x41E5BC).
    case unexpectedReplyType(expected: UInt8, got: UInt8)
    /// A reply on the serial link failed the frame's own checks.
    case malformedSerialReply(DbNetFrame.SerialError)
}

/// A DbNet master: keeps the transaction sequence and turns payloads into replies.
public final class DbNetSession {
    /// The address put in the frame's `0x06` field — the PLC address from *Unit config*
    /// (`PLC Address`, 1 in the user's configuration).
    public var address: UInt32

    /// The transaction counter at frame offset `0x00`. `SendReceive` increments it per attempt
    /// (`incl 0x298(%ebx)`), which is why a retry is not a repeat of the same bytes.
    public private(set) var sequence: UInt32 = 0

    /// How many times to re-send when the peer answers with the wait notice.
    public var maxAttempts = 8

    /// `0x9C4` = 2500 ms — the timeout the uploader uses (`cmpl $0x9c4, %eax`, 0x431B9D).
    public var timeout: TimeInterval = 2.5

    public let transport: DbNetTransport

    public init(transport: DbNetTransport, address: UInt32) {
        self.transport = transport
        self.address = address
    }

    /// Sends one payload and returns the reply's payload.
    ///
    /// A 14-byte reply carrying the `0x1111` flag is not an answer: `SendReceive` copies the address
    /// field back into the request and jumps to the top of the retry loop, so the message is sent
    /// again with an **incremented** sequence (0x41BE94 → 0x41BDE7).
    @discardableResult
    public func perform(_ payload: [UInt8]) throws -> [UInt8] {
        guard payload.count >= 3 else { throw DbNetError.payloadTooShort }
        guard payload.count <= 255 else { throw DbNetError.payloadTooLong }

        for _ in 0..<maxAttempts {
            sequence = sequence &+ 1
            guard let frame = DbNetFrame.encode(sequence: sequence, address: address, payload: payload) else {
                throw DbNetError.payloadTooLong
            }
            let reply = try transport.exchange(frame, timeout: timeout)

            // The wait notice: 14 bytes with flag 0x1111. Not an answer — ask again.
            if reply.count == DbNetFrame.retryFrameLength, DbNetFrame.flag(of: reply) == DbNetFrame.retryFlag {
                continue
            }
            switch DbNetFrame.parse(reply) {
            case .success(let decoded):
                guard decoded.sequence == sequence else {
                    throw DbNetError.sequenceMismatch(expected: sequence, got: decoded.sequence)
                }
                return decoded.payload
            case .failure(let reason):
                throw DbNetError.malformedReply(reason)
            }
        }
        throw DbNetError.peerBusy
    }
}

/// A `DbNetTransport` over a `SerialPort`.
///
/// The read follows the frame's own arithmetic: the length field at `0x0E` says how many bytes
/// follow the 15-byte header (`length + 6`), because the receiver requires
/// `bytesReceived == length + 0x15` (0x41BEAC). So a reader reads the header, then knows exactly how
/// much more to expect — no delimiter search needed.
public final class SerialDbNetTransport: DbNetTransport {
    private let port: SerialPort

    public init(port: SerialPort) {
        self.port = port
    }

    /// How many bytes the reply in `bytes` will have, once that can be told. A serial frame says so in its first
    /// bytes — `10 DA SA FCB CS 16` is six, `68 L L 68 …` is `L + 6` — and a reply is complete the moment that many
    /// have arrived. Waiting for the UDP station's 15-byte header instead meant no serial reply ever completed,
    /// and every exchange ran out its whole timeout (2.5 s each, 22 s for a 640-byte upload).
    static func serialFrameLength(of bytes: [UInt8]) -> Int? {
        guard let marker = bytes.first else { return nil }
        switch marker {
        case 0x10: return 6
        case 0x68:
            guard bytes.count >= 4 else { return nil }
            // `68 L L 68`: a header that does not repeat itself is noise; read on to the timeout.
            guard bytes[1] == bytes[2], bytes[3] == 0x68 else { return nil }
            return Int(bytes[1]) + 6
        default: return nil
        }
    }

    public func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        port.discardInput()
        _ = try port.write(data: Data(frame))

        let deadline = Date().addingTimeInterval(timeout)
        var received: [UInt8] = []

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard port.waitReadable(timeout: remaining) else { continue }
            if let chunk = try? port.read(maxBytes: 256), !chunk.isEmpty {
                received.append(contentsOf: chunk)
                // A serial frame is judged by its own length rules only; the UDP station's below would misread it.
                if received[0] == 0x10 || received[0] == 0x68 {
                    if let total = Self.serialFrameLength(of: received), received.count >= total {
                        return Array(received.prefix(total))
                    }
                    continue
                }
                // Enough for the header? Then the length field tells us the total.
                if received.count >= DbNetFrame.Offset.payload {
                    let lengthField = Int(received[DbNetFrame.Offset.length])
                    let total = lengthField + DbNetFrame.overhead
                    if received.count >= total {
                        return Array(received.prefix(total))
                    }
                }
                // The wait notice is only 14 bytes, shorter than a header plus payload.
                if received.count >= DbNetFrame.retryFrameLength,
                   DbNetFrame.flag(of: received) == DbNetFrame.retryFlag {
                    return Array(received.prefix(DbNetFrame.retryFrameLength))
                }
            }
        }
        return received
    }
}

// MARK: - The write operations the uploader uses

extension DbNetSession {
    /// The fixed byte both operation payloads carry after the station address, pushed as a constant
    /// by `WriteVariable` (0x41E55C) and `WriteMemory` (0x41E957).
    private static let operationMarker: UInt8 = 0x45

    /// The result of a write, as both operations read it back.
    ///
    /// `WriteMemory` (0x41E9CE-0x41E9EA) and `WriteVariable` (0x41E5AC-0x41E5C8) check the reply
    /// identically: the form must be `0x10` on the body, the byte after the one-byte form marker must
    /// equal the operation's type, and `status & 0xCF` must be zero — so only bits `0x30` may be set,
    /// in any combination.
    public struct WriteStatus: Equatable, Sendable {
        public var raw: UInt8
        /// `testb $0xCF` requires everything outside `0x30` to be clear, so any combination of bits
        /// 4 and 5 is accepted — `0x00`, `0x10`, `0x20`, `0x30` — and every other bit is not.
        public var isOK: Bool { raw & 0xCF == 0 }
    }

    /// `TBaseDbnMaster.WriteVariable` (0x41E534).
    ///
    /// The payload after the operation type, station address and `0x45` marker is
    /// `[2][sizeSelector][id: UInt16][value]`, with the value **2 or 4 bytes**: the routine sets the
    /// size to 2 when its third argument is zero and 4 otherwise (`movl $0x2, %edi` / `movl $0x4`,
    /// 0x41E54B / 0x41E552). There is no 8-byte case here, which is worth knowing before assuming a
    /// 64-bit value can be sent this way.
    ///
    /// - Parameters:
    ///   - type: the operation type byte (`ecx` at entry), echoed back by the PLC for checking.
    ///   - sizeSelector: the routine's third argument; it only decides 2 versus 4 bytes.
    ///   - id: the 16-bit variable id (`movzwl 0xc(%ebp)`, 0x41E573).
    @discardableResult
    public func writeVariable(type: UInt8, sizeSelector: UInt8, id: UInt16,
                              value: [UInt8], station: UInt8) throws -> WriteStatus {
        guard value.count == 2 || value.count == 4 else {
            throw DbNetError.badValueSize(expected: [2, 4], got: value.count)
        }
        let payload: [UInt8] = [
            type,
            station,
            Self.operationMarker,
            2,                                  // the payload's own first byte (0x41E56C)
            sizeSelector,
            UInt8(truncatingIfNeeded: id),
            UInt8(truncatingIfNeeded: id >> 8),
        ] + value
        return try status(from: try perform(payload), type: type)
    }

    /// `TBaseDbnMaster.WriteMemory` (0x41E93C).
    ///
    /// The payload after the type, station address and marker is
    /// `[4][memory: UInt16][offset: UInt16][length: UInt16][data]` — which is exactly the pair the
    /// uploader logs as `"%d ms Write Memory %.4X:%.4X"` (0x433314).
    ///
    /// No chunking is done here, and deliberately: the routine itself does not chunk. The 192-byte
    /// (`0xC0`) limit lives in the uploader (`cmpl $0xc0, %ebx`, 0x4334D7), so it belongs to whoever
    /// splits the image up.
    @discardableResult
    public func writeMemory(type: UInt8, memory: UInt16, offset: UInt16,
                            data: [UInt8], station: UInt8) throws -> WriteStatus {
        guard data.count <= 0xFFFF else { throw DbNetError.payloadTooLong }
        let length = UInt16(data.count)
        let payload: [UInt8] = [
            type,
            station,
            Self.operationMarker,
            4,                                  // the payload's own first byte (0x41E96A)
            UInt8(truncatingIfNeeded: memory), UInt8(truncatingIfNeeded: memory >> 8),
            UInt8(truncatingIfNeeded: offset), UInt8(truncatingIfNeeded: offset >> 8),
            UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8),
        ] + data
        return try status(from: try perform(payload), type: type)
    }

    /// The shared reply check.
    ///
    /// One index shifts between the disassembly and this API: the routines read the reply from its
    /// **body** start, so their `reply[0]` is the `0x10` form marker and their `reply[2]` is the type.
    /// `perform` has already consumed the form marker (that is what it means to return a payload), so
    /// here the type is `payload[1]` and the status `payload[2]`.
    private func status(from payload: [UInt8], type: UInt8) throws -> WriteStatus {
        guard payload.count >= 3 else { throw DbNetError.shortReply }
        guard payload[1] == type else {
            throw DbNetError.unexpectedReplyType(expected: type, got: payload[1])
        }
        return WriteStatus(raw: payload[2])
    }
}

// MARK: - The matrix operations the section transfer uses

extension DbNetSession {
    /// `TBaseDbnMaster.WriteVariableMtx` (0x41E694) — the bulk send behind every section.
    ///
    /// The payload after the seven-byte header is
    /// `[2][sizeSelector][w][w][w][length][w][data]`, so five 16-bit words precede the data. Only one
    /// is identified: the **fourth** word is the data length, loaded from the same stack slot the
    /// routine also passes as the transfer size (`movzwl 0x14(%ebp), %eax` at 0x41E6B7, stored at
    /// `-0xf9(%ebp)` at 0x41E723, pushed as the length at 0x41E6E1). The other four are carried
    /// through as parameters rather than guessed at.
    ///
    /// `L = data.count + 15` (`leal 0xf(%edi), %edx`, 0x41E750), the transport is handed `L + 6`, and
    /// the reply is checked exactly as the single-value writes are: form `0x10`, the byte after the
    /// marker equal to the type, and `status & 0xCF == 0` (0x41E77C-0x41E791).
    ///
    /// The routine range-checks the transfer against `0xF0` (0x41E6C5) — the same 240-byte ceiling
    /// the section helper clamps to.
    @discardableResult
    public func writeVariableMtx(type: UInt8, sizeSelector: UInt8, data: [UInt8],
                                 words: (UInt16, UInt16, UInt16, UInt16),
                                 station: UInt8) throws -> WriteStatus {
        guard data.count <= 0xF0 else { throw DbNetError.payloadTooLong }
        let length = UInt16(data.count)
        var payload: [UInt8] = [
            type, station, Self.operationMarker,
            2, sizeSelector,
        ]
        for word in [words.0, words.1, words.2, length, words.3] {
            payload.append(UInt8(truncatingIfNeeded: word))
            payload.append(UInt8(truncatingIfNeeded: word >> 8))
        }
        payload.append(contentsOf: data)
        return try status(from: try perform(payload), type: type)
    }

    /// The reply `ReadSmallVariableMtx` (0x41E410) expects, decoded.
    ///
    /// This operation answers in the **long** form, so `perform` has already removed the `0x68` marker
    /// and the length; the four indices the routine checks (`0x41E4D8`-0x41E50F) are therefore
    /// shifted by four. It requires, on the body: `0x68`, a length of `count + 4`, then the type,
    /// a byte `0x08`, and a byte `0x81` — and then copies `count` bytes out.
    public static func decodeMtxRead(_ payload: [UInt8], type: UInt8) -> [UInt8]? {
        // payload[0] is the type, payload[1] must be 0x08, payload[2] must be 0x81.
        guard payload.count >= 3 else { return nil }
        guard payload[0] == type, payload[1] == 0x08, payload[2] == 0x81 else { return nil }
        return Array(payload.dropFirst(3))
    }
}

// MARK: - Run/stop control

extension DbNetSession {
    /// The PLC's run/stop register, recovered from both control sites in the uploader.
    ///
    /// `sub_0043267C` writes it twice: `pushl $0x3C0` with the value 1 before *"Program stop request"*
    /// (0x432752 / 0x432773), and `pushl $0x3C0` with the value 0 before *"Program start"*
    /// (0x432B2E / 0x432B4F). So the register holds a **stop flag**: 1 stops, 0 runs.
    ///
    /// Both writes pass `ecx = 0`, which `WriteVariable` turns into a two-byte value (0x41E54B), and
    /// the same device-config type byte (`movzbl 0x16(%eax), %edx` off `self[0x94]`) that the section
    /// helper uses.
    public static let runStopVariable: UInt16 = 0x3C0

    /// Stops the PLC — `WriteVariable(0x3C0, 1)`, then the uploader waits 500 ms (`movl $0x1f4`,
    /// 0x432790). The stop path also checks `GetStatus` (0x41EB14) first, at 0x432749.
    @discardableResult
    public func requestStop(type: UInt8, station: UInt8) throws -> WriteStatus {
        try writeVariable(type: type, sizeSelector: 0, id: Self.runStopVariable,
                          value: [0x01, 0x00], station: station)
    }

    /// Starts the PLC — `WriteVariable(0x3C0, 0)`, then a 200 ms wait (`movl $0xc8`, 0x432B5F).
    @discardableResult
    public func requestStart(type: UInt8, station: UInt8) throws -> WriteStatus {
        try writeVariable(type: type, sizeSelector: 0, id: Self.runStopVariable,
                          value: [0x00, 0x00], station: station)
    }
}

// MARK: - The serial path

extension DbNetSession {
    /// Sends one serial frame and returns the reply's data.
    ///
    /// This is the path the PLC is actually reached on. `perform(_:)` builds the *UDP* station's frame
    /// — 15-byte header, sequence, scramble — which is what `TDbNetIpStation.SendReceive` describes and
    /// what the early rounds recovered. The captured RS485 traffic shows the on-wire frame is the body
    /// alone: `68 L L 68 DA SA FCB <data> CS 16`.
    public func performSerial(destination: UInt8, source: UInt8, function: UInt8,
                              data: [UInt8]) throws -> [UInt8] {
        let frame = DbNetFrame.encodeSerial(destination: destination, source: source,
                                            function: function, data: data)
        let reply = try transport.exchange(frame, timeout: timeout)
        switch DbNetFrame.parseSerial(reply) {
        case .success(let parsed):
            return parsed.data
        case .failure(let why):
            throw DbNetError.malformedSerialReply(why)
        }
    }

    /// The captured writes: `[type][station][0x45]` in the frame header, then `[2][selector][id][value]`
    /// in the data. The capture is explicit that the first byte is the destination (the PLC, address 1)
    /// and the second the source (the PC, address 31) — so the pair is `(destination, source)`, not the
    /// other way round.
    @discardableResult
    public func writeVariableSerial(destination: UInt8, source: UInt8, function: UInt8 = 0x45,
                                    selector: UInt8, id: UInt16, value: [UInt8]) throws -> [UInt8] {
        guard value.count == 2 || value.count == 4 else {
            throw DbNetError.badValueSize(expected: [2, 4], got: value.count)
        }
        let data: [UInt8] = [
            2, selector,
            UInt8(truncatingIfNeeded: id), UInt8(truncatingIfNeeded: id >> 8),
        ] + value
        return try performSerial(destination: destination, source: source,
                                 function: function, data: data)
    }

    /// The captured run/stop writes: variable 960, value 1 to stop and 0 to run.
    @discardableResult
    public func requestStopSerial(destination: UInt8 = 1, source: UInt8) throws -> [UInt8] {
        try writeVariableSerial(destination: destination, source: source, selector: 0,
                                id: Self.runStopVariable, value: [0x01, 0x00])
    }

    @discardableResult
    public func requestStartSerial(destination: UInt8 = 1, source: UInt8) throws -> [UInt8] {
        try writeVariableSerial(destination: destination, source: source, selector: 0,
                                id: Self.runStopVariable, value: [0x00, 0x00])
    }

    /// `GetStatus` — the alive check the capture opens with. A short frame with no data: `10 01 1F 49 69 16`.
    /// The reply is the three-byte ACK, `10 1F 01 00 20 16`.
    @discardableResult
    public func getStatusSerial(destination: UInt8 = 1, source: UInt8) throws -> [UInt8] {
        try performSerial(destination: destination, source: source, function: 0x49, data: [])
    }

    /// `ReadVariable` on the run/stop register, sent after the stop write. The capture shows
    /// `4D 01 00 C0 03`, and the reply `08 81 02 00`, whose data is the register's value, 2. What 2 means
    /// is not established; the uploader sends the read and does not branch on it.
    @discardableResult
    public func readRunStopSerial(destination: UInt8 = 1, source: UInt8) throws -> [UInt8] {
        try performSerial(destination: destination, source: source, function: 0x4D,
                          data: [0x01, 0x00,
                                 UInt8(truncatingIfNeeded: Self.runStopVariable),
                                 UInt8(truncatingIfNeeded: Self.runStopVariable >> 8)])
    }

    /// A table frame: the captured second frame is `Col = 8, NCols = 4, NRows = 8`, byte 128 at a
    /// 16-byte stride.
    @discardableResult
    public func writeMatrixSerial(destination: UInt8, source: UInt8, payload: [UInt8],
                                  function: UInt8 = 0x45) throws -> [UInt8] {
        try performSerial(destination: destination, source: source, function: function, data: payload)
    }
}

/// A transport that tells a callback about every frame that crosses it, for an upload log.
///
/// The callback receives `(direction, bytes)`: `"→"` for a request, `"←"` for the reply, and `"✗"` with the error
/// text as bytes-less detail when the exchange throws.
public final class LoggingDbNetTransport: DbNetTransport {
    private let inner: DbNetTransport
    private let log: (String, [UInt8]) -> Void

    public init(wrapping inner: DbNetTransport, log: @escaping (String, [UInt8]) -> Void) {
        self.inner = inner
        self.log = log
    }

    public func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        log("→", frame)
        do {
            let reply = try inner.exchange(frame, timeout: timeout)
            log("←", reply)
            return reply
        } catch {
            log("✗ \(error)", [])
            throw error
        }
    }
}
