import DranikCore
import Foundation
import os

/// Serves the control socket.
///
/// Runs on its own queue and never touches the daemon's. A client that connects
/// and then says nothing must not be able to stall the thing holding the charge
/// gate, and a request arriving while the controller is mid-decision must not
/// wait on it either.
///
/// So reads are answered from a snapshot the daemon publishes after each
/// decision, and anything that changes state is handed to the daemon
/// asynchronously. There is no path from a socket client into the daemon's
/// queue, which means there is no way for one to deadlock the other.
public final class ControlServer {
    /// How long a change waits for the decision it provokes before answering
    /// with what it knows.
    static let settleTimeout: TimeInterval = 1.0

    private let path: String
    private let queue = DispatchQueue(label: "com.dranik.battery.control")
    private let log = Logger(subsystem: "com.dranik.battery", category: "Control")

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// Latest published state. Reads are answered from here.
    private let snapshot = SnapshotBox()
    /// Applies a configuration change. Returns immediately; the work happens on
    /// the daemon's queue.
    private let applyConfig: (ChargeConfig) -> Void
    private let reloadConfig: () -> Void
    /// Arms the charge gate again after a verification failure disarmed it.
    private let restoreTrust: () -> Void

    /// `initialConfig` is what the daemon loaded at startup, so that a command
    /// arriving before the first decision has something to modify.
    ///
    /// Without it `disable` would have to refuse until a decision was published,
    /// and `disable` is the way out when something is wrong — the last command
    /// that should depend on the daemon being healthy enough to have decided.
    public init(
        path: String = ControlProtocol.defaultSocketPath,
        initialConfig: ChargeConfig,
        applyConfig: @escaping (ChargeConfig) -> Void,
        reloadConfig: @escaping () -> Void,
        restoreTrust: @escaping () -> Void = {}
    ) {
        self.path = path
        self.applyConfig = applyConfig
        self.reloadConfig = reloadConfig
        self.restoreTrust = restoreTrust
        snapshot.setConfig(initialConfig)
    }

    deinit {
        stop()
    }

    /// The config travels with the report rather than being reconstructed from
    /// it. Reconstructing was the bug: a report is a rendering, and a field a
    /// rendering happens not to carry comes back as a default.
    public func publish(_ report: DaemonReport, config: ChargeConfig) {
        snapshot.set(report, config: config)
    }

    public func start() throws {
        // A socket file left by a previous run is not a live listener, and bind
        // will not replace it.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ControlServerError.cannotListen("socket: \(String(cString: strerror(errno)))")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard fillSocketAddress(&address, with: path) else {
            close(descriptor)
            throw ControlServerError.cannotListen("socket path is too long: \(path)")
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw ControlServerError.cannotListen("bind: \(String(cString: strerror(errno)))")
        }

        guard listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw ControlServerError.cannotListen("listen: \(String(cString: strerror(errno)))")
        }

        // Group `admin`, mode 0660: changing the charge limit is an
        // administrator's business, not that of any process of any user.
        chown(path, 0, adminGroupID)
        chmod(path, 0o660)

        listener = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source

        log.notice("control socket listening at \(self.path, privacy: .public)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listener >= 0 {
            close(listener)
            listener = -1
        }
        unlink(path)
    }

    // MARK: - Connections

    private func acceptOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        // A client that connects and says nothing gets a second, then goes.
        var limit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while received.count <= ControlProtocol.maximumRequestBytes {
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { break }
            received.append(contentsOf: chunk[0..<count])
            if received.last == 0x0A { break }
        }

        let response: ControlResponse
        if received.count > ControlProtocol.maximumRequestBytes {
            response = .failure("request too large")
        } else if received.isEmpty {
            return
        } else {
            do {
                response = handle(try ControlProtocol.decodeRequest(received))
            } catch {
                response = .failure("could not parse the request: \(error)")
            }
        }

        if let data = try? ControlProtocol.encode(response) {
            _ = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        }
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.command {
        case .status:
            guard let report = snapshot.get() else {
                return .failure("the daemon has not reached a decision yet")
            }
            return ControlResponse(ok: true, report: report)

        case .disable:
            let current = snapshot.config()
            // `.with` and not a fresh `ChargeConfig`: turning limiting off is a
            // statement about the limit and nothing else. Rebuilding the config
            // here used to reset the thermal cutoff, the sleep policy and
            // `preventIdleSleepWhileCharging` to defaults — and then write them
            // to disk, so `dranik off` silently discarded them for good.
            return change(to: current.with(upperLimit: 100), asked: "disable")

        case .setLimit:
            guard let upper = request.upper else {
                return .failure("setLimit needs an upper limit")
            }
            let current = snapshot.config()
            // Still through the same validating initialiser as every other path,
            // so the socket is not a way around the bounds.
            return change(
                to: current.with(upperLimit: upper, lowerLimit: request.lower),
                asked: "setLimit \(upper)"
            )

        case .retrust:
            guard snapshot.get()?.gateIsTrusted == false else {
                return ControlResponse(
                    ok: true, report: snapshot.get(),
                    notes: ["the gate was already trusted — nothing to do"]
                )
            }
            log.notice("retrust requested")
            let before = snapshot.get()?.decidedAt
            restoreTrust()
            return settled(after: before, notes: ["charge limiting re-armed"])

        case .reload:
            reloadConfig()
            return ControlResponse(
                ok: true, report: snapshot.get(),
                notes: ["configuration reloaded; the report above may predate it"]
            )
        }
    }

    private func change(to config: ChargeConfig, asked: String) -> ControlResponse {
        log.notice("""
        \(asked, privacy: .public) -> \(config.lowerLimit, privacy: .public)–\
        \(config.upperLimit, privacy: .public)%
        """)
        let before = snapshot.get()?.decidedAt
        applyConfig(config)

        // Wait briefly for the decision the change provokes, so the gate and
        // reason shown belong to the new limit rather than the old one.
        //
        // Reporting the pre-change snapshot with the new limits patched in was
        // actively wrong: `dranik off` said "gate closed" at the moment the
        // daemon was opening it. Bounded, and on this queue only — the daemon's
        // is never blocked, so a wedged controller costs a stale answer and
        // nothing more.
        var response = settled(after: before, notes: config.corrections)
        guard response.report?.decidedAt == before || response.report == nil else {
            return response
        }

        // No new decision in time. Say what will be in force and be explicit
        // that the rest of the report predates the change.
        response.report?.upperLimit = config.upperLimit
        response.report?.lowerLimit = config.lowerLimit
        return response
    }

    /// Waits briefly for the decision a command provokes, so the gate and reason
    /// reported belong to the new state rather than the old one.
    ///
    /// Bounded, and on this queue only — the daemon's is never blocked, so a
    /// wedged controller costs a stale answer and nothing more.
    private func settled(after before: Date?, notes: [String]) -> ControlResponse {
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        while Date() < deadline {
            usleep(20_000)
            if let fresh = snapshot.get(), fresh.decidedAt != before {
                return ControlResponse(ok: true, report: fresh, notes: notes)
            }
        }
        return ControlResponse(
            ok: true, report: snapshot.get(),
            notes: notes + ["applied, but the daemon has not re-decided yet — "
                + "the gate and reason above predate the change"]
        )
    }

    /// `admin` is gid 80 on macOS. Looked up rather than hardcoded, falling back
    /// to `wheel` if it somehow is not there — a socket nobody can reach is
    /// better than one everybody can.
    private var adminGroupID: gid_t {
        guard let group = getgrnam("admin") else { return 0 }
        return group.pointee.gr_gid
    }
}

public enum ControlServerError: Error, CustomStringConvertible {
    case cannotListen(String)

    public var description: String {
        switch self {
        case .cannotListen(let detail):
            return "cannot open the control socket: \(detail)"
        }
    }
}

/// The one piece of shared state between the daemon's queue and the server's.
private final class SnapshotBox {
    private let lock = NSLock()
    private var value: DaemonReport?
    /// Never absent: seeded with what the daemon loaded before the socket opened.
    private var configuration = ChargeConfig()

    func set(_ report: DaemonReport, config: ChargeConfig) {
        lock.lock()
        value = report
        configuration = config
        lock.unlock()
    }

    func setConfig(_ config: ChargeConfig) {
        lock.lock()
        configuration = config
        lock.unlock()
    }

    func get() -> DaemonReport? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func config() -> ChargeConfig {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }
}
