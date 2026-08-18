import Foundation

/// Talks to a running daemon over its control socket.
public enum ControlClient {
    public enum Failure: Error, CustomStringConvertible {
        case notRunning(path: String)
        case connectionFailed(String)
        case noResponse
        case malformedResponse(String)

        public var description: String {
            switch self {
            case .notRunning(let path):
                return """
                the daemon does not appear to be running (no socket at \(path)). \
                Start it with `make install`, or use `dranik status`, which reads \
                the battery directly and needs no daemon.
                """
            case .connectionFailed(let detail):
                return "cannot reach the daemon: \(detail)"
            case .noResponse:
                return "the daemon accepted the request but said nothing"
            case .malformedResponse(let detail):
                return "the daemon replied with something unreadable: \(detail)"
            }
        }
    }

    /// Sends one request and waits for the reply. Blocking, which is what a
    /// short-lived command-line client wants.
    public static func send(
        _ request: ControlRequest,
        to path: String = ControlProtocol.defaultSocketPath,
        timeout: TimeInterval = 5
    ) throws -> ControlResponse {
        guard FileManager.default.fileExists(atPath: path) else {
            throw Failure.notRunning(path: path)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Failure.connectionFailed(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        setTimeout(descriptor, SO_RCVTIMEO, timeout)
        setTimeout(descriptor, SO_SNDTIMEO, timeout)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard fillSocketAddress(&address, with: path) else {
            throw Failure.connectionFailed("socket path is too long: \(path)")
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            // A socket file with nothing listening is the shape a crashed daemon
            // leaves behind, so say the useful thing rather than "connection
            // refused".
            if errno == ECONNREFUSED || errno == ENOENT {
                throw Failure.notRunning(path: path)
            }
            throw Failure.connectionFailed(String(cString: strerror(errno)))
        }

        let payload = try ControlProtocol.encode(request)
        try payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + sent, buffer.count - sent)
                guard written > 0 else {
                    throw Failure.connectionFailed("write: \(String(cString: strerror(errno)))")
                }
                sent += written
            }
        }

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while received.count < ControlProtocol.maximumRequestBytes {
            let count = read(descriptor, &chunk, chunk.count)
            if count <= 0 { break }
            received.append(contentsOf: chunk[0..<count])
            if received.last == 0x0A { break }
        }

        guard !received.isEmpty else { throw Failure.noResponse }
        do {
            return try ControlProtocol.decodeResponse(received)
        } catch {
            throw Failure.malformedResponse("\(error)")
        }
    }

    private static func setTimeout(_ descriptor: Int32, _ option: Int32, _ seconds: TimeInterval) {
        var value = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Copies `path` into a `sockaddr_un`, reporting whether it fitted.
///
/// `sun_path` is a fixed 104-byte array. Truncating it silently would connect to
/// or bind the wrong path, so the length is checked rather than assumed.
public func fillSocketAddress(_ address: inout sockaddr_un, with path: String) -> Bool {
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { return false }

    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    return true
}
