import Foundation

/// Uploads a program to the PLC, in the order the captured traffic shows.
///
/// From `message.txt` (a real upload, 24 frames), `TPCCUploader.Upload` and the section helper
/// `sub_00431F30`:
///
/// 1. `GetStatus` — an alive check (`calll 0x41EB14`, 0x432749);
/// 2. `WriteVariable 960 = 1` — stop the PLC, then wait 500 ms (`movl $0x1f4`, 0x432790);
/// 3. the program table in matrix frames of `WID 525`, 8-column chunks (`sub_00431F30`);
/// 4. `WriteVariable 960 = 0` — start it, after a 200 ms wait (`movl $0xc8`, 0x432B5F).
///
/// The writes carry the device's type byte (`movzbl 0x16(%eax), %edx` off `self[0x94]`), which is
/// `0x01` in the capture, on the `0x45` function.
public final class PLCUploader {
    public let session: DbNetSession

    /// The PLC's address — `PLC Address 1` in the user's configuration. It is the frame's DA.
    public var destination: UInt8
    /// The PC's address — `PC Address 31`. It is the frame's SA.
    public var source: UInt8
    /// The row count of the matrix the table is written through; the capture used 8.
    public var rows: UInt16 = 8
    /// The chunk size in bytes. The uploader clamps `compilation[0x70]` into 64…240, and the capture
    /// used 128.
    public var chunkBytes = 128
    /// Waits, from the capture's own constants.
    public var stopWait: TimeInterval = 0.5
    public var startWait: TimeInterval = 0.2

    public init(session: DbNetSession, destination: UInt8 = 1, source: UInt8 = 31) {
        self.session = session
        self.destination = destination
        self.source = source
    }

    /// Stops the PLC, writes the table, and starts it again.
    @discardableResult
    public func upload(table: PLCProgramTable) throws -> Int {
        try session.requestStopSerial(destination: destination, source: source)
        Thread.sleep(forTimeInterval: stopWait)

        let frames = table.matrixWriteFrames(rows: rows, chunkBytes: chunkBytes)
        for payload in frames {
            try session.writeMatrixSerial(destination: destination, source: source, payload: payload)
        }

        Thread.sleep(forTimeInterval: startWait)
        try session.requestStartSerial(destination: destination, source: source)
        return frames.count
    }
}
