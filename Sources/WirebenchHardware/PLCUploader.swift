import Foundation

/// Uploads a program to the PLC, in the order the captured traffic shows.
///
/// From `Serial packet capture/message.txt` (a 640-byte upload, 102 log records) and `message.txt` (a
/// 192-byte upload), the sequence is:
///
/// 1. `GetStatus` — the alive check, a short frame (`10 01 1F 49 69 16`);
/// 2. `WriteVariable 960 = 1` — stop the PLC (`68 09 09 68 01 1F 45 02 00 C0 03 01 00 2C 16`);
/// 3. `ReadVariable 960` — read the register back (`4D 01 00 C0 03`);
/// 4. the table, as matrix frames of `WID 525`, eight columns at a time, each acknowledged;
/// 5. `WriteVariable 960 = 0` — start the PLC.
///
/// The captures show no fixed delays between these. Each frame is acknowledged before the next is sent,
/// and that is the only pacing. The 500 ms and 200 ms waits this file used to take were read from
/// constants in the uploader, and no capture shows them.
///
/// The whole table is sent: the captures transfer `table.count` bytes, not a prefix of it.
public final class PLCUploader {
    public let session: DbNetSession

    /// The PLC's address — `PLC Address 1` in the user's configuration. It is the frame's DA.
    public var destination: UInt8
    /// The PC's address — `PC Address 31`. It is the frame's SA.
    public var source: UInt8
    /// The row count of the matrix the table is written through; the captures use 8.
    public var rows: UInt16 = 8
    /// The chunk size in bytes. The captures use 128 (eight columns of 16 bytes) and send the remainder
    /// as its own frame.
    public var chunkBytes = 128
    /// Called before each step with a short description, for a log.
    public var onStage: ((String) -> Void)?

    /// Called after each acknowledged step with the fraction of the upload that is done. Retries do not move this
    /// counter, unlike counting the bytes the transport happens to carry.
    public var onProgress: ((Double) -> Void)?

    public init(session: DbNetSession, destination: UInt8 = 1, source: UInt8 = 31) {
        self.session = session
        self.destination = destination
        self.source = source
    }

    /// How many table frames `table` will take with the current `rows`/`chunkBytes`.
    public func frameCount(for table: PLCProgramTable) -> Int {
        table.matrixFrameCount(chunkBytes: max(1, chunkBytes))
    }

    /// Stops the PLC, writes the whole table, and starts it again. Returns the number of table frames.
    @discardableResult
    public func upload(table: PLCProgramTable) throws -> Int {
        let frames = table.matrixWriteFrames(rows: rows, chunkBytes: chunkBytes)
        // GetStatus, stop, read, every table frame, start: the progress is step count, not wire traffic.
        let total = 4 + frames.count
        func step(_ index: Int) { onProgress?(Double(index) / Double(total)) }

        onStage?("GetStatus")
        try session.getStatusSerial(destination: destination, source: source)
        step(1)
        onStage?("Stop the PLC")
        try session.requestStopSerial(destination: destination, source: source)
        step(2)
        onStage?("Read the run/stop register")
        try session.readRunStopSerial(destination: destination, source: source)
        step(3)

        for (index, payload) in frames.enumerated() {
            onStage?("Table frame \(index + 1) of \(frames.count)")
            try session.writeMatrixSerial(destination: destination, source: source, payload: payload)
            step(4 + index)
        }

        onStage?("Start the PLC")
        try session.requestStartSerial(destination: destination, source: source)
        step(total)
        return frames.count
    }
}
