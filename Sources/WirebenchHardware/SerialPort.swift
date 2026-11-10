import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// `SerialPort` has methods called `open`, `close`, `read` and `write`, which hide the C functions of the same
// name inside it; these reach them without naming the platform's C module.
private func sysOpen(_ path: String, _ flags: Int32) -> Int32 { open(path, flags) }
private func sysClose(_ fd: Int32) { _ = close(fd) }
private func sysWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buffer, count) }
private func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }

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
            // Linux names its USB serial adapters `ttyUSB*` (FTDI, CH340, Prolific), CDC boards `ttyACM*`, and Bluetooth
            // serial `rfcomm*`. The built-in `ttyS*` ports are left out: most of them are not wired to anything.
            if ["ttyUSB", "ttyACM", "rfcomm"].contains(where: { name.hasPrefix($0) && name.count > $0.count }) { return true }
            guard name.hasPrefix("cu."), name.count > 3 else { return false }
            // macOS ships three `cu.` pseudo-ports that are not adapters. Offering them would let a
            // user "connect" to something that cannot carry D3Net traffic.
            let builtIn = ["cu.Bluetooth-Incoming-Port", "cu.debug-console", "cu.SerialPort"]
            return !builtIn.contains(name)
        }
    }

    /// What to tell the user when a port will not open.
    ///
    /// On Linux the usual reason is that the device belongs to a group the user is not in, which no error code explains by itself.
    public static func openFailureMessage(path: String, error: Error) -> String {
        switch (error as? POSIXError)?.code {
        case .EACCES?:
            #if os(Linux)
            return "No permission to open \(path). Add your user to the group that owns it (dialout on Debian, Ubuntu and Fedora, uucp on Arch: "
                + "sudo usermod -aG dialout $USER), then log in again."
            #else
            return "No permission to open \(path)."
            #endif
        case .EBUSY?:
            return "\(path) is in use by another program."
        case .ENOENT?, .ENODEV?:
            return "\(path) is not there. Plug the adapter in again and refresh the ports."
        default:
            return "Could not open \(path): \(error.localizedDescription)"
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

        let fd = sysOpen(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var tty = termios()
        if tcgetattr(fd, &tty) != 0 {
            sysClose(fd)
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
        tty.c_cflag |= (tcflag_t(CS8) | tcflag_t(CLOCAL) | tcflag_t(CREAD))
        tty.c_cflag &= ~(tcflag_t(PARENB) | tcflag_t(PARODD) | tcflag_t(CSTOPB) | tcflag_t(CRTSCTS))
        switch parity {
        case .none:
            break
        case .even:
            // PARENB enables the parity bit; leaving PARODD clear selects even.
            tty.c_cflag |= tcflag_t(PARENB)
            tty.c_cflag &= ~tcflag_t(PARODD)
        }
        tty.c_iflag &= ~(tcflag_t(IGNBRK) | tcflag_t(BRKINT) | tcflag_t(PARMRK) | tcflag_t(ISTRIP) | tcflag_t(INLCR) | tcflag_t(IGNCR) | tcflag_t(ICRNL) | tcflag_t(IXON))
        // Input parity errors are not stripped or flagged: a damaged byte is the transaction
        // layer's problem, and it has a checksum for exactly that.
        tty.c_iflag &= ~tcflag_t(INPCK)
        tty.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ECHONL) | tcflag_t(ICANON) | tcflag_t(ISIG) | tcflag_t(IEXTEN))
        tty.c_oflag &= ~tcflag_t(OPOST)

        // The slots differ between platforms (16 and 17 on Darwin, 6 and 5 on Linux), so index by the constants.
        withUnsafeMutableBytes(of: &tty.c_cc) { slots in
            slots[Int(VMIN)] = 0
            slots[Int(VTIME)] = 1   // 0.1 sec
        }

        if tcsetattr(fd, TCSANOW, &tty) != 0 {
            sysClose(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        self.fileDescriptor = fd
        self.isOpen = true
    }

    public func close() {
        if fileDescriptor >= 0 {
            sysClose(fileDescriptor)
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
                sysWrite(fileDescriptor, ptr.baseAddress! + offset, data.count - offset)
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
        let bytesRead = sysRead(fileDescriptor, &buffer, maxBytes)
        if bytesRead < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return Data()
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Data(buffer.prefix(bytesRead))
    }
}
