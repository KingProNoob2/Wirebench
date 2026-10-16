import Foundation
import Darwin

public final class SerialPort: @unchecked Sendable {
    public struct PortInfo: Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let name: String
    }

    public static func availablePorts() -> [PortInfo] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: "/dev") else { return [] }
        return serialDeviceNames(in: items)
            .sorted()
            .map { PortInfo(path: "/dev/\($0)", name: $0) }
    }

    /// Which of the names in `/dev` are serial adapters, in the order given.
    ///
    /// Takes the directory listing rather than reading `/dev` itself so the rule can be tested against
    /// a fixed list — the one thing a test cannot do is plug in a USB adapter.
    ///
    /// **Every** `cu.*` device is a candidate rather than a hand-written prefix list. The list this
    /// replaces recognised only `cu.usb*`, `cu.SLAB*` and `cu.wch*`, which misses most adapters in
    /// practice: an FTDI is `cu.usbserial-*`, a CH340 is `cu.wchusbserial*`, a CDC board is
    /// `cu.usbmodem*`, and a Prolific is `cu.PL2303*`. (`cu.wch*` did not even match
    /// `cu.wchusbserial*`; it happened to be saved by the `cu.usb*` arm.) A user's own adapter was
    /// `cu.usbserial-110`, which the list *would* have matched — the picker was empty because nothing
    /// ever called `refreshPorts`, and both defects are fixed here.
    public static func serialDeviceNames(in deviceNames: [String]) -> [String] {
        deviceNames.filter { name in
            // `cu.` itself, and `cu.` with an empty suffix, are not devices — a bare prefix would
            // otherwise be offered as a port with no name. (`DevicesTests` caught exactly that.)
            guard name.hasPrefix("cu."), name.count > 3 else { return false }
            // macOS ships three `cu.` pseudo-ports that are not adapters. Offering them would let a
            // user "connect" to something that cannot carry D3Net traffic.
            let builtIn = ["cu.Bluetooth-Incoming-Port", "cu.debug-console", "cu.SerialPort"]
            return !builtIn.contains(name)
        }
    }

    private var fileDescriptor: Int32 = -1
    public private(set) var isOpen: Bool = false

    /// Serial framing parity.
    ///
    /// The D3Net link runs with **even** parity: the *Unit config* dialog's `CbParity` is a checkbox
    /// captioned "Even parity" (`extracted_dfms/12_DFM_12.dfm`) and is checked in the user's
    /// configuration, alongside `RS485 D3Net Master`, `COM5` and `57600`. The dialog offers no odd
    /// setting, so those are the only two cases.
    public enum Parity: Sendable {
        case none
        case even
    }

    public init() {}

    deinit {
        close()
    }

    public func open(path: String, baudRate: Int = 57600, parity: Parity = .even) throws {
        close()

        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var tty = termios()
        if tcgetattr(fd, &tty) != 0 {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let speed: speed_t
        switch baudRate {
        case 9600: speed = speed_t(B9600)
        case 19200: speed = speed_t(B19200)
        case 38400: speed = speed_t(B38400)
        case 57600: speed = speed_t(B57600)
        case 115200: speed = speed_t(B115200)
        default: speed = speed_t(B57600)
        }

        cfsetspeed(&tty, speed)
        tty.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(PARENB | PARODD | CSTOPB | CRTSCTS)
        switch parity {
        case .none:
            break
        case .even:
            // PARENB enables the parity bit; leaving PARODD clear selects even.
            tty.c_cflag |= tcflag_t(PARENB)
            tty.c_cflag &= ~tcflag_t(PARODD)
        }
        tty.c_iflag &= ~tcflag_t(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON)
        // Input parity errors are not stripped or flagged: a damaged byte is the transaction
        // layer's problem, and it has a checksum for exactly that.
        tty.c_iflag &= ~tcflag_t(INPCK)
        tty.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | ISIG | IEXTEN)
        tty.c_oflag &= ~tcflag_t(OPOST)

        tty.c_cc.16 = 0 // VMIN
        tty.c_cc.17 = 1 // VTIME (0.1 sec)

        if tcsetattr(fd, TCSANOW, &tty) != 0 {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        self.fileDescriptor = fd
        self.isOpen = true
    }

    public func close() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        isOpen = false
    }

    /// Writes all of `data`. The port is non-blocking, so a long frame can be taken in pieces; this waits for room
    /// rather than dropping the rest.
    public func write(data: Data) throws -> Int {
        guard isOpen, fileDescriptor >= 0 else { return 0 }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { ptr in
                Darwin.write(fileDescriptor, ptr.baseAddress! + offset, data.count - offset)
            }
            if written > 0 { offset += written; continue }
            guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
            _ = poll(&descriptor, 1, 100)
        }
        return offset
    }

    /// Blocks until a byte can be read or `timeout` seconds pass. Returns whether one can.
    /// This is what the reader waits on instead of sleeping: a reply is picked up when its first byte arrives, not
    /// at the next tick of a poll loop.
    public func waitReadable(timeout: TimeInterval) -> Bool {
        guard isOpen, fileDescriptor >= 0 else { return false }
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(0, min(timeout, 60)) * 1000)
        return poll(&descriptor, 1, milliseconds) > 0 && descriptor.revents & Int16(POLLIN) != 0
    }

    /// Throws away what has arrived and not been read, so a stale byte cannot be taken for the next reply.
    public func discardInput() {
        guard isOpen, fileDescriptor >= 0 else { return }
        tcflush(fileDescriptor, TCIFLUSH)
    }

    public func read(maxBytes: Int = 1024) throws -> Data {
        guard isOpen, fileDescriptor >= 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let bytesRead = Darwin.read(fileDescriptor, &buffer, maxBytes)
        if bytesRead < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return Data()
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Data(buffer.prefix(bytesRead))
    }
}
