import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// MaraProt over the Duino-S Ethernet TCP server (port 5020).
///
/// The socket layer is POSIX rather than Apple's Network framework so the same transport builds on
/// Linux, where Wirebench's non-SwiftUI targets run. One connection carries one client session: the
/// firmware is point-to-point on TCP, so station IDs do not need the RS-485 filter.
public final class MaraTCPTransport: MaraProtTransport, @unchecked Sendable {
    public enum TCPError: Error, LocalizedError, Equatable {
        case badHost
        case resolutionFailed(String)
        case connectFailed(String)
        case connectTimeout
        case notConnected
        case writeFailed(String)
        case readFailed(String)
        case closed
        case responseTimeout

        public var errorDescription: String? {
            switch self {
            case .badHost: return "The Duino-S host name is empty."
            case .resolutionFailed(let host): return "Could not resolve \(host)."
            case .connectFailed(let detail): return "Could not connect to the Duino-S: \(detail)."
            case .connectTimeout: return "Timed out connecting to the Duino-S."
            case .notConnected: return "The Duino-S TCP connection is not open."
            case .writeFailed(let detail): return "Could not send to the Duino-S: \(detail)."
            case .readFailed(let detail): return "Could not read from the Duino-S: \(detail)."
            case .closed: return "The Duino-S closed the TCP connection."
            case .responseTimeout: return "The Duino-S did not answer before the timeout."
            }
        }
    }

    public let host: String
    public let port: UInt16
    public var connectTimeout: TimeInterval = 3
    private var descriptor: Int32 = -1
    private var isOpen = false

    public init(host: String, port: UInt16 = 5020) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
    }

    deinit { close() }

    public func open() throws {
        close()
        guard !host.isEmpty else { throw TCPError.badHost }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let service = String(port)
        let status = getaddrinfo(host, service, &hints, &result)
        guard status == 0, let first = result else {
            throw TCPError.resolutionFailed(host)
        }
        defer { freeaddrinfo(result) }

        var lastError = "connection refused"
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let address = candidate {
            let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if fd < 0 { candidate = address.pointee.ai_next; continue }
            setNonBlocking(fd)
            #if canImport(Darwin)
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            let connected = connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
            if connected == 0 {
                descriptor = fd
                isOpen = true
                return
            }
            if errno == EINPROGRESS {
                var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let wait = poll(&pollDescriptor, 1, Int32(connectTimeout * 1000))
                if wait > 0 {
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                    if socketError == 0 {
                        descriptor = fd
                        isOpen = true
                        return
                    }
                    lastError = String(cString: strerror(socketError))
                } else if wait == 0 {
                    lastError = "connection timeout"
                } else {
                    lastError = String(cString: strerror(errno))
                }
            } else {
                lastError = String(cString: strerror(errno))
            }
            sysClose(fd)
            candidate = address.pointee.ai_next
        }
        if lastError == "connection timeout" { throw TCPError.connectTimeout }
        throw TCPError.connectFailed(lastError)
    }

    public func close() {
        if descriptor >= 0 { sysClose(descriptor) }
        descriptor = -1
        isOpen = false
    }

    public func exchange(_ frame: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        guard isOpen, descriptor >= 0 else { throw TCPError.notConnected }
        try writeAll(frame, timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TCPError.responseTimeout }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(max(1, remaining * 1000)))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw TCPError.readFailed(String(cString: strerror(errno)))
            }
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { throw TCPError.closed }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw TCPError.readFailed(String(cString: strerror(errno)))
            }
            received.append(contentsOf: buffer.prefix(count))
            if let total = MaraProtFrame.frameLength(from: received), received.count >= total {
                return Array(received.prefix(total))
            }
        }
    }

    private func writeAll(_ bytes: [UInt8], timeout: TimeInterval) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        while offset < bytes.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TCPError.responseTimeout }
            #if canImport(Darwin)
            let count = bytes.withUnsafeBytes { buffer in
                send(descriptor, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            #else
            let count = bytes.withUnsafeBytes { buffer in
                send(descriptor, buffer.baseAddress! + offset, bytes.count - offset, Int32(MSG_NOSIGNAL))
            }
            #endif
            if count > 0 { offset += count; continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pollDescriptor, 1, Int32(max(1, remaining * 1000)))
                continue
            }
            throw TCPError.writeFailed(count < 0 ? String(cString: strerror(errno)) : "short write")
        }
    }
}

private func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

private func sysClose(_ fd: Int32) { _ = close(fd) }
