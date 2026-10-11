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
        return items
            .filter { $0.hasPrefix("cu.usb") || $0.hasPrefix("cu.SLAB") || $0.hasPrefix("cu.wch") }
            .map { PortInfo(path: "/dev/\($0)", name: $0) }
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

    public func write(data: Data) throws -> Int {
        guard isOpen, fileDescriptor >= 0 else { return 0 }
        let bytesWritten = data.withUnsafeBytes { ptr in
            Darwin.write(fileDescriptor, ptr.baseAddress, data.count)
        }
        if bytesWritten < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return bytesWritten
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
