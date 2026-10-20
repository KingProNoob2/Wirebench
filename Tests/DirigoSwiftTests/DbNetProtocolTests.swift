import Testing
import Foundation
@testable import DirigoHardware
import DirigoLibrary

/// Two kinds of test here, and the difference matters:
///
/// * **Independent** — the type-code test reads the real `.pcc` files on this machine and checks
///   every `TYPE` attribute against the recovered table. That is the decompilation and the real file
///   format agreeing, which no amount of reading assembly can establish on its own.
/// * **Regression pins** — the checksum, mix and scramble tests pin behaviour I read out of the
///   disassembly. They cannot prove the reading is right; they stop it drifting silently later.
@Suite("DbNet protocol")
struct DbNetProtocolTests {

    // MARK: - The type table

    @Test("The recovered type table matches what real projects put in TYPE attributes")
    func typeCodesMatchRealProjects() throws {
        var files: [URL] = []
        // The workspace's own projects, then the user's Dirigo folder when it is there.
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for dir in [here] + TestCorpus.directories {
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            files.append(contentsOf: contents.filter { $0.pathExtension.lowercased() == "pcc" })
        }
        try #require(!files.isEmpty, "no .pcc files found to check against")

        var seen: [Character: Int] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: /<[A-Z_]*PIN\b[^>]*\bTYPE="([^"]*)"/) {
                let code = String(match.1)
                guard let character = code.first, code.count == 1 else {
                    Issue.record("\(file.lastPathComponent) has a multi-character TYPE \(code)")
                    continue
                }
                seen[character, default: 0] += 1
            }
        }
        try #require(!seen.isEmpty, "none of the \(files.count) projects carries a TYPE attribute")

        for (code, count) in seen {
            let type = PLCDataType(code: code)
            #expect(type != nil, "TYPE=\"\(code)\" (\(count) pins) is not one of the recovered types")
            if let type {
                #expect(type.size > 0)
            }
        }
        print("checked \(seen.values.reduce(0, +)) pin types across \(files.count) projects:",
              seen.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }

    @Test("The sizes are the ones GetDataSize returns")
    func sizesMatchTheRecoveredTable() {
        // GetDataSize (0x47E4E8) jump table, index 0…10.
        #expect(PLCDataType.allCases.map(\.size) == [1, 1, 2, 4, 8, 1, 2, 4, 4, 8, 10])
        // Extended at 10 bytes is the x86 80-bit type — a check that the table was read right.
        #expect(PLCDataType.extended.size == 10)
        #expect(PLCDataType.allCases.count == 11, "the code table at 0x485478 has 12 entries, one unused")
    }

    @Test("Every type's code round-trips")
    func codesRoundTrip() {
        for type in PLCDataType.allCases {
            #expect(PLCDataType(code: type.code) == type)
        }
        #expect(PLCDataType(code: "Z") == nil)
    }

    // MARK: - Values

    @Test("A pin value keeps its type byte and 8-byte payload")
    func valueLayout() {
        // ZeroPinValue (0x47D474): the type byte at 0, zeros at 1…8.
        #expect(PLCValue(type: .longint).bytes.count == 1 + PLCValue.payloadSize)
        #expect(PLCValue(type: .longint).bytes[0] == PLCDataType.longint.rawValue)

        // SmallIntPinValue (0x47D488) writes type 2 and a word; LongIntPinValue (0x47D490) type 3
        // and a dword. Those type bytes are the same enum indices as the table above.
        let small = PLCValue(type: .smallint, payload: [0x34, 0x12])
        #expect(small.intValue == 0x1234)
        let long = PLCValue(type: .longint, payload: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(long.intValue == -1)
        let single = PLCValue(type: .single, payload: [0x00, 0x00, 0x80, 0x3F])
        #expect(single.doubleValue == 1.0)
    }

    // MARK: - Frame primitives

    @Test("The checksum uses an end-around carry, not a plain sum")
    func checksumHasEndAroundCarry() {
        #expect(DbNetFrame.checksum([]) == 0x00)
        #expect(DbNetFrame.checksum([0x01]) == 0x01)
        // A plain sum of FF+01 is 0x100, which truncates to 0x00. The recovered routine folds the
        // carry back in, giving 1 — so this case tells the two algorithms apart.
        #expect(DbNetFrame.checksum([0xFF, 0x01]) == 0x01)
        #expect(DbNetFrame.checksum([0xFF, 0x02]) == 0x02)
        #expect(DbNetFrame.checksum([0x80, 0x80]) == 0x01)
        // Order must not matter for a sum.
        #expect(DbNetFrame.checksum([0x10, 0x20, 0x30]) == DbNetFrame.checksum([0x30, 0x20, 0x10]))
    }

    @Test("mix is deterministic and depends on both arguments")
    func mixDependsOnBoth() {
        #expect(DbNetFrame.mix(1, 2) == DbNetFrame.mix(1, 2))
        #expect(DbNetFrame.mix(1, 2) != DbNetFrame.mix(2, 1))
        #expect(DbNetFrame.mix(0x1234, 0x5678) != 0)
        // a == 0 is replaced by 1 before the first multiply, but the return still adds `a` itself,
        // so mix(0, b) is not mix(1, b).
        #expect(DbNetFrame.mix(0, 7) != DbNetFrame.mix(1, 7))
    }

    @Test("Scrambling is its own inverse, and keys the first words differently")
    func scrambleIsInvolutive() {
        let original = (0..<32).map { UInt8($0 &* 7 &+ 1) }
        var bytes = original
        DbNetFrame.scramble(&bytes, length: UInt8(32 - DbNetFrame.Offset.payload), sequence: 0x99, address: 0x1234)
        #expect(bytes != original, "a non-zero key must change something")

        DbNetFrame.scramble(&bytes, length: UInt8(32 - DbNetFrame.Offset.payload), sequence: 0x99, address: 0x1234)
        #expect(bytes == original, "XOR with the same key twice restores the input")

        // The first two words use ~sequence, the rest use sequence — so with a non-zero sequence the
        // pattern cannot be a plain repeating key.
        var a = original, b = original
        DbNetFrame.scramble(&a, length: UInt8(32 - DbNetFrame.Offset.payload), sequence: 0x1, address: 0x20)
        DbNetFrame.scramble(&b, length: UInt8(32 - DbNetFrame.Offset.payload), sequence: 0x2, address: 0x20)
        #expect(a != b)
    }

    @Test("The frame's shape is the one the receiver demands")
    func frameShapeIsTheReceivers() {
        #expect(DbNetFrame.overhead == 0x15, "bytesReceived == length + 0x15 (0x41BEAC)")
        #expect(DbNetFrame.terminator == 0x16)
        #expect(DbNetFrame.retryFlag == 0x1111)
        #expect(DbNetFrame.retryFrameLength == 14)
        #expect(DbNetFrame.maxPayload == 0xC0)
        #expect(DbNetFrame.Offset.payload == 0x0F)
        #expect(DbNetFrame.Offset.length == 0x0E)
        #expect(DbNetFrame.Offset.checksum == 0x0A)
    }

    // MARK: - Replies

    @Test("Replies parse as DbnTransaction parses them")
    func repliesParse() {
        // 0x10: a three-byte body, data at +1.
        let short = DbNetFrame.reply(from: [0x10, 0xAA, 0xBB])
        #expect(short?.command == .short)
        #expect(short?.payload == [0xAA, 0xBB])

        // 0x68: the count at +1, data at +4.
        let long = DbNetFrame.reply(from: [0x68, 0x02, 0x00, 0x00, 0x11, 0x22])
        #expect(long?.command == .long)
        #expect(long?.payload == [0x11, 0x22])

        // Anything else fails, and a short body must not read past its end.
        #expect(DbNetFrame.reply(from: []) == nil)
        #expect(DbNetFrame.reply(from: [0x42, 0x00]) == nil)
        #expect(DbNetFrame.reply(from: [0x10, 0x01]) == nil)
        #expect(DbNetFrame.reply(from: [0x68, 0x05]) == nil)
    }

    // MARK: - Assembling frames

    @Test("The short form is 0x10, the payload, a checksum and 0x16")
    func shortBody() throws {
        let payload: [UInt8] = [0xAA, 0xBB, 0xCC]
        let body = try #require(DbNetFrame.body(for: payload))
        #expect(body == [0x10, 0xAA, 0xBB, 0xCC, DbNetFrame.checksum(payload), 0x16])
        #expect(body.count == 6, "DbnTransaction returns 6 for this form (0x41E15D)")

        // Fewer than three bytes is rejected outright: `cmpl $0x3, %ebx; jl` (0x41E126).
        #expect(DbNetFrame.body(for: []) == nil)
        #expect(DbNetFrame.body(for: [1, 2]) == nil)
    }

    @Test("The long form is 68 LL LL 68, the payload, a checksum and 0x16")
    func longBody() throws {
        let payload: [UInt8] = [1, 2, 3, 4]
        let body = try #require(DbNetFrame.body(for: payload))
        #expect(Array(body.prefix(4)) == [0x68, 4, 4, 0x68], "sub_0041E210 writes the length twice")
        #expect(body.count == payload.count + 6, "DbnTransaction returns payload + 6 (0x41E192)")
        #expect(Array(body.suffix(2)) == [DbNetFrame.checksum(payload), 0x16])
    }

    @Test("A frame is the length field plus 21 bytes, which is what the receiver demands")
    func frameLengthMatchesTheReceiver() throws {
        for count in [3, 4, 16, 192] {
            let payload = (0..<count).map { UInt8($0 & 0xFF) }
            let frame = try #require(DbNetFrame.encode(sequence: 7, address: 0x1234, payload: payload))
            // `bytesReceived == length + 0x15` (0x41BEAC) is the rule the receiver enforces.
            let lengthField = Int(frame[DbNetFrame.Offset.length])
            #expect(frame.count == lengthField + DbNetFrame.overhead)
            if count == 3 {
                // The short form does not count its three bytes: sub_0041618C (0x416190-0x4161A3)
                // stores 0 in the length field when the command is 0x10, so a three-byte payload
                // frame is 21 bytes like a zero-length one, not 24.
                #expect(lengthField == 0)
                #expect(frame.count == DbNetFrame.overhead)
            } else {
                #expect(lengthField == count)
                #expect(frame.count == count + DbNetFrame.overhead)
            }
        }
    }

    /// Reads a frame that is expected to be valid, failing the test with the reason if it is not.
    private func parseOK(_ bytes: [UInt8]) throws -> DbNetFrame.Decoded {
        switch DbNetFrame.parse(bytes) {
        case .success(let decoded): return decoded
        case .failure(let failure): throw failure
        }
    }

    private func parseFailure(_ bytes: [UInt8]) -> DbNetFrame.ParseFailure? {
        if case .failure(let failure) = DbNetFrame.parse(bytes) { return failure }
        return nil
    }

    @Test("A frame parses back to what was encoded, and damage is caught by name")
    func frameRoundTrip() throws {
        let payload: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55]
        let frame = try #require(DbNetFrame.encode(sequence: 42, address: 0x00AB, payload: payload, flag: 0))
        let decoded = try parseOK(frame)
        #expect(decoded.payload == payload)
        #expect(decoded.sequence == 42)
        #expect(decoded.address == 0x00AB)

        // A flipped payload byte must fail the checksum, and say so.
        var damaged = frame
        damaged[DbNetFrame.Offset.payload + 5] ^= 0xFF
        #expect(parseFailure(damaged) == .badChecksum)

        // A wrong length field must fail the receiver's arithmetic.
        var wrongLength = frame
        wrongLength[DbNetFrame.Offset.length] = 9
        if case .lengthMismatch = parseFailure(wrongLength) {} else {
            Issue.record("a wrong length field must be reported as a length mismatch")
        }

        // And an unknown command must be rejected, naming the byte. The body is scrambled, so the
        // command byte has to be changed after unscrambling and then scrambled back — writing 0x42
        // straight into the frame would only change ciphertext.
        var badCommand = frame
        let seq = try parseOK(frame).sequence
        let lengthField = badCommand[DbNetFrame.Offset.length]
        DbNetFrame.scramble(&badCommand, length: lengthField, sequence: seq, address: 0x00AB)
        badCommand[DbNetFrame.Offset.payload] = 0x42
        DbNetFrame.scramble(&badCommand, length: lengthField, sequence: seq, address: 0x00AB)
        #expect(parseFailure(badCommand) == .unknownCommand(0x42))

        // Encoding is deterministic, and the sequence is part of the result rather than decoration.
        #expect(DbNetFrame.encode(sequence: 42, address: 0x00AB, payload: payload, flag: 0) == frame)
        #expect(DbNetFrame.encode(sequence: 43, address: 0x00AB, payload: payload, flag: 0) != frame)
        #expect(DbNetFrame.encode(sequence: 42, address: 0x00AC, payload: payload, flag: 0) != frame)
    }

    @Test("A three-byte payload frame carries the short command once unscrambled")
    func shortFrameParses() throws {
        let payload: [UInt8] = [9, 8, 7]
        let frame = try #require(DbNetFrame.encode(sequence: 1, address: 2, payload: payload))
        #expect(frame.count == DbNetFrame.overhead, "the short form leaves the length field at 0")
        let decoded = try parseOK(frame)
        #expect(decoded.payload == payload)
    }

    // MARK: - The transaction layer

    /// A transport that answers the way the PLC would, so the session can be exercised with no
    /// hardware: the reply echoes the request's sequence and address, which is what the real
    /// receiver checks (`cmpl 0x298(%ebx)`, 0x41BEC5).
    private final class ScriptedTransport: DbNetTransport {
        private(set) var sent: [[UInt8]] = []
        var busyCount = 0
        var replyPayload: [UInt8] = [0xAA, 0xBB, 0xCC]
        var replyLength: Int?

        func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
            sent.append(frame)
            guard case .success(let request) = DbNetFrame.parse(frame) else { return [] }
            if busyCount > 0 {
                busyCount -= 1
                // The wait notice: 14 bytes, flag 0x1111 (`cmpw $0x1111`, 0x41BE94).
                var notice = [UInt8](repeating: 0, count: DbNetFrame.retryFrameLength)
                for i in 0..<4 { notice[i] = UInt8(truncatingIfNeeded: request.sequence >> (8 * i)) }
                notice[DbNetFrame.Offset.flag] = 0x11
                notice[DbNetFrame.Offset.flag + 1] = 0x11
                return notice
            }
            var reply = DbNetFrame.encode(sequence: request.sequence, address: request.address,
                                          payload: replyPayload) ?? []
            if let wanted = replyLength, wanted <= reply.count {
                reply = Array(reply.prefix(wanted))
            }
            return reply
        }
    }

    @Test("A transaction sends one frame and returns the reply's payload")
    func transactionRoundTrip() throws {
        let transport = ScriptedTransport()
        let session = DbNetSession(transport: transport, address: 1)
        let reply = try session.perform([0x11, 0x22, 0x33, 0x44])

        #expect(reply == transport.replyPayload)
        #expect(transport.sent.count == 1)
        let sent = try parseOK(transport.sent[0])
        #expect(sent.address == 1, "the address comes from the configuration (PLC Address 1)")
        #expect(sent.sequence == 1, "the counter starts at zero and is incremented before sending")
        #expect(sent.payload == [0x11, 0x22, 0x33, 0x44])
    }

    @Test("The wait notice is retried with an incremented sequence")
    func waitNoticeIsRetried() throws {
        let transport = ScriptedTransport()
        transport.busyCount = 2
        let session = DbNetSession(transport: transport, address: 1)
        _ = try session.perform([1, 2, 3, 4])

        // Two notices, then the answer.
        #expect(transport.sent.count == 3)
        let sequences = try transport.sent.map { try parseOK($0).sequence }
        #expect(sequences == [1, 2, 3], "a retry is a new transaction, not a repeat of the same bytes")
        #expect(Set(transport.sent.map { $0.description }).count == 3,
                "and the bytes really do differ, because the sequence keys the scramble")
    }

    @Test("A peer that is always busy ends as peerBusy rather than looping")
    func alwaysBusyGivesUp() throws {
        let transport = ScriptedTransport()
        transport.busyCount = 100
        let session = DbNetSession(transport: transport, address: 1)
        session.maxAttempts = 3
        #expect(throws: DbNetError.peerBusy) { try session.perform([1, 2, 3, 4]) }
        #expect(transport.sent.count == 3)
    }

    @Test("A truncated reply is reported as malformed, not accepted")
    func truncatedReplyIsRejected() throws {
        let transport = ScriptedTransport()
        transport.replyLength = 12
        let session = DbNetSession(transport: transport, address: 1)
        #expect(throws: (any Error).self) { try session.perform([1, 2, 3, 4]) }
    }

    @Test("A payload below the protocol's minimum is refused before anything is sent")
    func shortPayloadIsRefused() throws {
        let transport = ScriptedTransport()
        let session = DbNetSession(transport: transport, address: 1)
        #expect(throws: DbNetError.payloadTooShort) { try session.perform([1, 2]) }
        #expect(transport.sent.isEmpty, "nothing should reach the wire")
    }

    // MARK: - The write operations

    @Test("WriteVariable builds the payload DbnMaster builds")
    func writeVariablePayload() throws {
        let transport = ScriptedTransport()
        transport.replyPayload = [0x00, 0x07, 0x00]
        let session = DbNetSession(transport: transport, address: 1)

        let status = try session.writeVariable(type: 0x07, sizeSelector: 0, id: 0x1234,
                                               value: [0xAA, 0xBB], station: 1)
        #expect(status.isOK)

        let sent = try parseOK(transport.sent[0])
        // [type][station][0x45][2][sizeSelector][id lo][id hi][value...]
        #expect(sent.payload == [0x07, 0x01, 0x45, 0x02, 0x00, 0x34, 0x12, 0xAA, 0xBB])
        // L = valueSize + 7, and the same number is the checksum range (0x41E588).
        #expect(Int(transport.sent[0][DbNetFrame.Offset.length]) == 2 + 7)
    }

    @Test("WriteMemory builds the payload DbnMaster builds, with memory:offset")
    func writeMemoryPayload() throws {
        let transport = ScriptedTransport()
        transport.replyPayload = [0x00, 0x09, 0x30]
        let session = DbNetSession(transport: transport, address: 1)

        let status = try session.writeMemory(type: 0x09, memory: 0x0200, offset: 0x0040,
                                             data: [0xDE, 0xAD, 0xBE, 0xEF], station: 1)
        #expect(status.isOK, "0x30 is one of the two values the checksum mask allows")

        let sent = try parseOK(transport.sent[0])
        // [type][station][0x45][4][memory][offset][length][data...]
        #expect(sent.payload == [0x09, 0x01, 0x45, 0x04,
                                 0x00, 0x02,   // memory 0x0200, little-endian
                                 0x40, 0x00,   // offset 0x0040
                                 0x04, 0x00,   // length 4
                                 0xDE, 0xAD, 0xBE, 0xEF])
        // L = dataLen + 10 (0x41E9A0).
        #expect(Int(transport.sent[0][DbNetFrame.Offset.length]) == 4 + 10)
    }

    @Test("A status may only set bits 4 and 5")
    func writeStatusMask() throws {
        let session = DbNetSession(transport: ScriptedTransport(), address: 1)
        let send: (UInt8) throws -> DbNetSession.WriteStatus = { status in
            let transport = ScriptedTransport()
            transport.replyPayload = [0x00, 0x09, status]
            let session = DbNetSession(transport: transport, address: 1)
            return try session.writeMemory(type: 0x09, memory: 0, offset: 0, data: [1], station: 1)
        }
        // testb $0xCF requires everything outside 0x30 to be clear, so any combination of bits 4 and
        // 5 is fine and every other bit is not.
        for allowed in [UInt8(0x00), 0x10, 0x20, 0x30] {
            #expect(try send(allowed).isOK, "0x\(String(allowed, radix: 16)) should be accepted")
        }
        for refused in [UInt8(0x01), 0x04, 0x40, 0x80, 0x0F] {
            #expect(try !send(refused).isOK, "0x\(String(refused, radix: 16)) should be refused")
        }
        _ = session
    }

    @Test("A reply naming a different operation is refused")
    func writeReplyTypeMismatch() throws {
        let transport = ScriptedTransport()
        transport.replyPayload = [0x00, 0x08, 0x00]
        let session = DbNetSession(transport: transport, address: 1)
        #expect(throws: DbNetError.unexpectedReplyType(expected: 0x09, got: 0x08)) {
            try session.writeMemory(type: 0x09, memory: 0, offset: 0, data: [1], station: 1)
        }
    }

    @Test("A value that is neither 2 nor 4 bytes never reaches the wire")
    func writeVariableSize() throws {
        let transport = ScriptedTransport()
        let session = DbNetSession(transport: transport, address: 1)
        #expect(throws: DbNetError.badValueSize(expected: [2, 4], got: 8)) {
            try session.writeVariable(type: 1, sizeSelector: 1, id: 1,
                                      value: [UInt8](repeating: 0, count: 8), station: 1)
        }
        #expect(transport.sent.isEmpty)
    }

    // MARK: - The matrix operations

    @Test("WriteVariableMtx builds the payload, with the length as the fourth word")
    func writeVariableMtxPayload() throws {
        let transport = ScriptedTransport()
        transport.replyPayload = [0x00, 0x4D, 0x00]
        let session = DbNetSession(transport: transport, address: 1)

        let status = try session.writeVariableMtx(type: 0x4D, sizeSelector: 1,
                                                  data: [0xAA, 0xBB, 0xCC],
                                                  words: (0x1111, 0x2222, 0x3333, 0x4444),
                                                  station: 1)
        #expect(status.isOK)
        let sent = try parseOK(transport.sent[0])
        #expect(sent.payload == [0x4D, 0x01, 0x45,      // type, station, marker
                                 0x02, 0x01,             // 2, sizeSelector
                                 0x11, 0x11,             // word from 0x20(%ebp)
                                 0x22, 0x22,             // word from 0x1c(%ebp)
                                 0x33, 0x33,             // word from 0x18(%ebp)
                                 0x03, 0x00,             // the data length, from 0x14(%ebp)
                                 0x44, 0x44,             // word from 0x10(%ebp)
                                 0xAA, 0xBB, 0xCC])
        // L = data.count + 15 (0x41E750), and the transport gets L + 6.
        #expect(Int(transport.sent[0][DbNetFrame.Offset.length]) == 3 + 15)
    }

    @Test("WriteVariableMtx refuses more than the 0xF0 the routine range-checks")
    func writeVariableMtxLimit() throws {
        let transport = ScriptedTransport()
        let session = DbNetSession(transport: transport, address: 1)
        #expect(throws: DbNetError.payloadTooLong) {
            try session.writeVariableMtx(type: 1, sizeSelector: 0,
                                         data: [UInt8](repeating: 0, count: 0xF1),
                                         words: (0, 0, 0, 0), station: 1)
        }
        #expect(transport.sent.isEmpty)
    }

    @Test("An Mtx read reply is checked and its data extracted")
    func mtxReadReply() {
        // After the 0x68 marker: [type][0x08][0x81][data...]
        #expect(DbNetSession.decodeMtxRead([0x09, 0x08, 0x81, 0xAA, 0xBB], type: 0x09) == [0xAA, 0xBB])
        #expect(DbNetSession.decodeMtxRead([0x09, 0x08, 0x81], type: 0x09) == [], "no data is still valid")
        #expect(DbNetSession.decodeMtxRead([0x08, 0x08, 0x81, 0xAA], type: 0x09) == nil,
                "an unexpected type must be refused")
        #expect(DbNetSession.decodeMtxRead([0x09, 0x07, 0x81], type: 0x09) == nil,
                "the fixed 0x08 byte must be there")
        #expect(DbNetSession.decodeMtxRead([0x09, 0x08, 0x82], type: 0x09) == nil,
                "the fixed 0x81 byte must be there")
        #expect(DbNetSession.decodeMtxRead([0x09], type: 0x09) == nil)
    }

    @Test("Run and stop are writes of 1 and 0 to variable 960")
    func runStopControl() throws {
        #expect(DbNetSession.runStopVariable == 960, "0x3C0, the id both control sites push")

        let stopTransport = ScriptedTransport()
        stopTransport.replyPayload = [0x00, 0x1F, 0x00]
        let stopSession = DbNetSession(transport: stopTransport, address: 1)
        #expect(try stopSession.requestStop(type: 0x1F, station: 1).isOK)
        let stopSent = try parseOK(stopTransport.sent[0])
        #expect(stopSent.payload == [0x1F, 0x01, 0x45, 0x02, 0x00, 0xC0, 0x03, 0x01, 0x00],
                "type, station, marker, 2, selector, id 0x03C0, value 1")

        let startTransport = ScriptedTransport()
        startTransport.replyPayload = [0x00, 0x1F, 0x00]
        let startSession = DbNetSession(transport: startTransport, address: 1)
        #expect(try startSession.requestStart(type: 0x1F, station: 1).isOK)
        let startSent = try parseOK(startTransport.sent[0])
        #expect(startSent.payload == [0x1F, 0x01, 0x45, 0x02, 0x00, 0xC0, 0x03, 0x00, 0x00],
                "the same id, value 0")
    }

    // MARK: - The serial frame, against captured traffic

    /// Every frame captured from a real upload to the PLC (`message.txt`). These are the bytes that
    /// actually went down the wire, so passing them is the only test in this suite that cannot be
    /// satisfied by a self-consistent misreading.
    /// Every frame captured from a real upload to the PLC (`message.txt`). These are the bytes that
    /// actually went down the wire, so a round trip through them cannot be satisfied by a
    /// self-consistent misreading.
    static let capturedHex: [String] = [
        "10 01 1F 49 69 16",
        "10 1F 01 02 22 16",
        "68 09 09 68 01 1F 45 02 00 C0 03 01 00 2C 16",
        "10 1F 01 00 20 16",
        "68 07 07 68 01 1F 4D 01 00 C0 03 32 16",
        "68 06 06 68 1F 01 08 81 02 00 AB 16",
        "68 09 09 68 01 1F 45 02 00 C0 03 00 00 2B 16",
        "68 8F 8F 68 01 1F 45 02 20 0D 02 00 00 00 00 08 00 08 00 00 00 01 00 07 00 01 01 00 00 00 00 00 00 00 00 08 00 00 00 00 00 00 00 00 00 03 00 D9 8D 00 00 00 00 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 09 80 00 10 13 C4 00 00 00 01 01 00 14 C4 01 00 00 02 01 01 51 A0 02 C3 70 C0 02 10 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 73 16",
        "68 4F 4F 68 01 1F 45 02 20 0D 02 08 00 00 00 04 00 08 00 00 00 00 00 FF FF 00 00 00 00 00 00 00 00 00 01 D0 00 D0 00 53 79 62 61 73 20 43 6F 6E 74 72 6F 6C 20 50 33 20 20 20 20 20 20 20 20 20 20 20 20 20 20 20 20 00 00 00 00 00 00 00 00 00 00 00 00 FA 16",
    ]

    static func bytes(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    @Test("Every captured frame parses, and re-encodes to the identical bytes")
    func capturedFramesRoundTrip() throws {
        for hex in Self.capturedHex {
            let bytes = Self.bytes(hex)
            let frame = try parseSerialOK(bytes)
            let reencoded = DbNetFrame.encodeSerial(destination: frame.destination,
                                                    source: frame.source,
                                                    function: frame.function,
                                                    data: frame.data)
            #expect(reencoded == bytes, "\(hex.prefix(24))... should round-trip")
            #expect(frame.destination == 1 || frame.destination == 31,
                    "addresses are the configured PLC 1 and PC 31")
        }
    }

    @Test("The captured 143-byte matrix write decodes to the tool's annotations")
    func capturedMatrixWrite() throws {
        let hex = Self.capturedHex[7]
        let bytes = Self.bytes(hex)
        #expect(bytes.count == 149)

        let frame = try parseSerialOK(bytes)
        #expect(frame.destination == 1 && frame.source == 31 && frame.function == 0x45)
        let data = frame.data
        #expect(data[0] == 0x02 && data[1] == 0x20)
        #expect(data[2] == 0x0D && data[3] == 0x02, "WID 525, little-endian")
        #expect(data[4] == 0 && data[5] == 0, "Col 0")
        #expect(data[6] == 0 && data[7] == 0, "Row 0")
        #expect(data[8] == 8 && data[9] == 0, "NCols 8")
        #expect(data[10] == 8 && data[11] == 0, "NRows 8")
        #expect(data.count == 12 + 128, "NCols x NRows x 2 = 128 bytes, the tool's DataLen")
        // The 525 section's own bytes follow, starting with had.dmp's first eight.
        #expect(Array(data[12..<20]) == [UInt8](arrayLiteral: 0x00, 0x00, 0x01, 0x00, 0x07, 0x00, 0x01, 0x01))
    }

    @Test("Damaged serial frames are refused with a reason")
    func damagedSerialFrames() {
        var bad: [UInt8] = [0x10, 0x01, 0x1F, 0x49, 0x69, 0x16]
        bad[4] = 0x68
        if case .failure(let why) = DbNetFrame.parseSerial(bad) {
            #expect(why == .badChecksum(expected: 0x69, got: 0x68))
        } else { Issue.record("a bad checksum must be reported") }

        var noTerm: [UInt8] = [0x10, 0x01, 0x1F, 0x49, 0x69, 0x00]
        if case .failure(let why) = DbNetFrame.parseSerial(noTerm) {
            #expect(why == .badTerminator(0x00))
        } else { Issue.record("a missing terminator must be reported") }
        noTerm[5] = 0x16

        #expect(DbNetFrame.parseSerial([]) == .failure(.tooShort))
        #expect(DbNetFrame.parseSerial([0x99, 0x01]) == .failure(.badMarker(0x99)))

        // A long frame shorter than its own header is rejected outright.
        let short: [UInt8] = [0x68, 0x09, 0x09, 0x68, 0x01, 0x1F, 0x45]
        #expect(DbNetFrame.parseSerial(short) == .failure(.tooShort))

        // And one long enough to have a header, but claiming more data than it carries, is a length
        // failure — the case a reader has to catch rather than reading past the end.
        var truncated = Self.bytes("68 09 09 68 01 1F 45 02 00 C0")
        if case .failure(let why) = DbNetFrame.parseSerial(truncated) {
            if case .badLength = why {} else { Issue.record("expected a length failure, got \(why)") }
        } else { Issue.record("a truncated long frame must be refused") }
        truncated.append(0x16)
    }

    private func parseSerialOK(_ bytes: [UInt8]) throws -> DbNetFrame.SerialFrame {
        switch DbNetFrame.parseSerial(bytes) {
        case .success(let frame): return frame
        case .failure(let reason): throw reason
        }
    }
}

/// The captured upload of `rulkoshaddirigo.pcc` (Dirigo v2.5.10.459) in `Serial packet capture/`. It is
/// the reference for the serial framing, the upload sequence and the table's container: every request
/// in it must be reproduced byte for byte, and the table it carries must be the one the uploader sends.
@Suite("Serial capture: rulkoshaddirigo upload")
struct SerialCaptureTests {
    static var workspace: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The write frames the log records, in order, as raw bytes. A `Write (DOWN)` record's hex lines are
    /// the frame; the ASCII column after three spaces is skipped.
    static func requests() throws -> [[UInt8]] {
        let url = workspace.appendingPathComponent("Serial packet capture/message.txt")
        try #require(FileManager.default.fileExists(atPath: url.path), "needs the captured upload")
        let text = try String(contentsOf: url, encoding: .utf8)
        var frames: [[UInt8]] = []
        var current: [UInt8]?
        for line in text.components(separatedBy: "\n") {
            if line.range(of: #"^\d{6}: "#, options: .regularExpression) != nil {
                if let frame = current { frames.append(frame) }
                current = line.contains("Write (DOWN)") ? [] : nil
                continue
            }
            guard current != nil else { continue }
            let hex = line.components(separatedBy: "   ").first ?? ""
            for token in hex.split(separator: " ") {
                if let byte = UInt8(token, radix: 16), token.count == 2 { current! .append(byte) }
            }
        }
        if let frame = current { frames.append(frame) }
        return frames.filter { !$0.isEmpty }
    }

    @Test("Every request in the capture is reproduced byte for byte by the encoder")
    func encoderReproducesRequests() throws {
        let frames = try Self.requests()
        #expect(frames.count == 9, "GetStatus, stop, read, five matrix writes, start")
        for frame in frames {
            guard case .success(let parsed) = DbNetFrame.parseSerial(frame) else {
                Issue.record("a captured request does not parse: \(frame.prefix(8))")
                continue
            }
            let encoded = DbNetFrame.encodeSerial(destination: parsed.destination, source: parsed.source,
                                                  function: parsed.function, data: parsed.data)
            #expect(encoded == frame)
        }
    }

    @Test("The table the capture uploads is 640 bytes and carries a valid checksum")
    func capturedTable() throws {
        var bytes = [UInt8](repeating: 0, count: 640)
        var written = Set<Int>()
        for frame in try Self.requests() {
            guard case .success(let parsed) = DbNetFrame.parseSerial(frame),
                  parsed.function == 0x45, parsed.data.count > 12,
                  Array(parsed.data.prefix(4)) == [0x02, 0x20, 0x0D, 0x02] else { continue }
            let data = parsed.data
            let col = Int(data[4]) | Int(data[5]) << 8
            let rows = Int(data[10]) | Int(data[11]) << 8
            let offset = col * rows * 2
            for (i, byte) in data[12...].enumerated() {
                bytes[offset + i] = byte
                written.insert(offset + i)
            }
        }
        #expect(written.count == 640, "five matrix frames cover the table with no gap")
        let table = try PLCProgramTable(bytes: bytes)
        #expect(table.checksumIsValid)
        #expect(table.sentinelOffset == 0x244, "the records run 0x40..0x222, then 34 zeros")
        #expect(table.profileName == "Sybas Control P3")
    }

    /// Answers each request with the short OK the capture shows, and records what was sent.
    private final class Recorder: DbNetTransport {
        private(set) var sent: [[UInt8]] = []
        func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
            sent.append(frame)
            guard case .success(let request) = DbNetFrame.parseSerial(frame) else { return [] }
            return DbNetFrame.encodeSerial(destination: request.source, source: request.destination,
                                           function: 0x00)
        }
    }

    @Test("Uploading the captured table sends exactly the captured requests, in order")
    func uploaderReproducesCapture() throws {
        let captured = try Self.requests()
        // Rebuild the table the capture carried, as the previous test does.
        var bytes = [UInt8](repeating: 0, count: 640)
        for frame in captured {
            guard case .success(let parsed) = DbNetFrame.parseSerial(frame),
                  parsed.function == 0x45, parsed.data.count > 12,
                  Array(parsed.data.prefix(4)) == [0x02, 0x20, 0x0D, 0x02] else { continue }
            let data = parsed.data
            let offset = (Int(data[4]) | Int(data[5]) << 8) * (Int(data[10]) | Int(data[11]) << 8) * 2
            for (i, byte) in data[12...].enumerated() { bytes[offset + i] = byte }
        }
        let table = try PLCProgramTable(bytes: bytes)

        let recorder = Recorder()
        let uploader = PLCUploader(session: DbNetSession(transport: recorder, address: 1),
                                   destination: 1, source: 31)
        let frames = try uploader.upload(table: table)
        #expect(frames == 5)
        #expect(recorder.sent == captured)
    }
}

/// The two saves in `Serial packet capture/` that differ only by edits Dirigo ignores: the `*out` sheet
/// is deleted, and a `SystemCmd` is placed on `main` with thread 0. Both uploads were byte-identical.
@Suite("Serial capture: edits Dirigo ignores")
struct IgnoredEditsTests {
    static var workspace: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func project(_ name: String) throws -> String {
        let url = workspace.appendingPathComponent("Serial packet capture/\(name)")
        try #require(FileManager.default.fileExists(atPath: url.path), "needs the captured project")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("A thread-0 module on a non-macro sheet, and an uncalled sheet, are not in the program")
    func programSelection() throws {
        let modules = PLCProjectCompiler.modules(in: try Self.project("rulkoshaddirigo-mod.pcc"))
        let program = PLCProjectCompiler.programModules(modules)
        #expect(!program.contains { $0.page == "*out" }, "nothing calls *out")
        #expect(!program.contains { $0.name == "SystemCmd2" }, "thread 0 on main is not expanded")
        #expect(program.contains { $0.name == "SystemCmd1" }, "*rultea is called by rultea1")
        #expect(program.contains { $0.name == "PulseGen1" }, "*kostka is called by kostka1")
    }

    @Test("The table is the same for the original and the edited save")
    func tablesMatch() throws {
        let template = try #require(PLCProgramTable.buildTemplate())
        let original = try PLCProjectBuild.compile(xml: try Self.project("rulkoshaddirigo.pcc"),
                                                   classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                   template: template)
        let edited = try PLCProjectBuild.compile(xml: try Self.project("rulkoshaddirigo-mod.pcc"),
                                                 classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                 template: template)
        #expect(original.table == edited.table)
        #expect(original.table.count == PLCProgramTable.length(records: original.records.count),
                "the table is sized to its records")
    }
}

/// What the compiler writes for each captured save, against the table Dirigo uploaded for it.
///
/// All four saves of `rulkoshaddirigo` (the original, `-mod`, `-mod2` with an AdvCounter in `*kostka`, and
/// `-mod3` with the ISwitch moved onto the Set block's X pin) must come out with the same record region,
/// sentinel and table length as the capture, and the header words that follow from the layout (the end of the
/// records, the table length and the thread table) are derived the way `TPCCProject.Compile` does.
@Suite("Serial capture: the compiled table")
struct CompiledTableCaptureTests {
    /// The table a log carries, rebuilt from its matrix writes.
    static func capturedTable(_ log: String) throws -> [UInt8] {
        let url = IgnoredEditsTests.workspace.appendingPathComponent("Serial packet capture/\(log)")
        try #require(FileManager.default.fileExists(atPath: url.path), "needs \(log)")
        let text = try String(contentsOf: url, encoding: .utf8)
        var frames: [[UInt8]] = []
        var current: [UInt8]?
        for line in text.components(separatedBy: "\n") {
            if line.range(of: #"^\d{6}: "#, options: .regularExpression) != nil {
                if let frame = current { frames.append(frame) }
                current = line.contains("Write (DOWN)") ? [] : nil
                continue
            }
            guard current != nil else { continue }
            for token in (line.components(separatedBy: "   ").first ?? "").split(separator: " ") {
                if let byte = UInt8(token, radix: 16), token.count == 2 { current!.append(byte) }
            }
        }
        if let frame = current { frames.append(frame) }
        var bytes = [UInt8](repeating: 0, count: 640)
        for frame in frames where !frame.isEmpty {
            guard case .success(let parsed) = DbNetFrame.parseSerial(frame),
                  parsed.function == 0x45, parsed.data.count > 12,
                  Array(parsed.data.prefix(4)) == [0x02, 0x20, 0x0D, 0x02] else { continue }
            let data = parsed.data
            let offset = (Int(data[4]) | Int(data[5]) << 8) * (Int(data[10]) | Int(data[11]) << 8) * 2
            for (i, byte) in data[12...].enumerated() { bytes[offset + i] = byte }
        }
        return bytes
    }

    @Test("The records, sentinel and length match the upload", arguments: [
        ("rulkoshaddirigo.pcc", "message.txt"),
        ("rulkoshaddirigo-mod.pcc", "message-mod.txt"),
        ("rulkoshaddirigo-mod2.pcc", "message-mod2.txt"),
        ("rulkoshaddirigo-mod3.pcc", "message-mod3.txt"),
    ])
    func matchesUpload(project: String, log: String) throws {
        let template = try #require(PLCProgramTable.buildTemplate())
        let build = try PLCProjectBuild.compile(xml: try IgnoredEditsTests.project(project),
                                                classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                template: template)
        let real = try Self.capturedTable(log)
        #expect(build.table.count == real.count)
        // The whole table: header words (layout-derived and the project flags), records, sentinel, trailer.
        let differing = (0..<real.count).filter { build.table[$0] != real[$0] }
        #expect(differing.isEmpty, "differing bytes: \(differing.prefix(16).map { String($0, radix: 16) })")
        #expect(build.table == real)
    }
}

/// The upload log: the stages the uploader announces and every frame the transport carries.
@Suite("Upload log")
struct UploadLogTests {
    private final class Echo: DbNetTransport {
        func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
            guard case .success(let request) = DbNetFrame.parseSerial(frame) else { return [] }
            return DbNetFrame.encodeSerial(destination: request.source, source: request.destination, function: 0x00)
        }
    }

    @Test("Stages and frames are reported in order, each request with its reply")
    func logsStagesAndFrames() throws {
        var frames: [String] = []
        var stages: [String] = []
        let logged = LoggingDbNetTransport(wrapping: Echo()) { direction, _ in frames.append(direction) }
        let uploader = PLCUploader(session: DbNetSession(transport: logged, address: 1), destination: 1, source: 31)
        uploader.onStage = { stages.append($0) }
        let template = try #require(PLCProgramTable.buildTemplate())
        let count = try uploader.upload(table: template)
        #expect(stages.first == "GetStatus")
        #expect(stages.last == "Start the PLC")
        #expect(stages.filter { $0.hasPrefix("Table frame") }.count == count)
        #expect(frames.count == 2 * (count + 4), "request and reply for GetStatus, stop, read, each frame, start")
        #expect(frames.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0 ? "→" : "←") })
    }
}
