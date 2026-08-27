import DranikCore
import DranikDaemon
import Foundation

/// End-to-end over a real unix socket: a server on a temporary path and the
/// client that ships with the CLI. No daemon, no root, no SMC.
private func withServer(
    apply: @escaping (ChargeConfig) -> Void = { _ in },
    reload: @escaping () -> Void = {},
    restore: @escaping () -> Void = {},
    publish: DaemonReport? = report(),
    config: ChargeConfig = ChargeConfig(),
    _ body: (String, ControlServer) throws -> Void
) throws {
    let path = NSTemporaryDirectory() + "dranik-\(UUID().uuidString).sock"
    let server = ControlServer(
        path: path, initialConfig: config, applyConfig: apply,
        reloadConfig: reload, restoreTrust: restore
    )
    try server.start()
    defer { server.stop() }
    if let publish { server.publish(publish, config: config) }
    try body(path, server)
}

private func report(upper: Int = 80, lower: Int = 75, trusted: Bool = true) -> DaemonReport {
    DaemonReport(
        upperLimit: upper, lowerLimit: lower, thermalCutoff: 40,
        sleepPolicy: "holdLimit", gate: "closed", reason: "reached the limit",
        gateIsTrusted: trusted, decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

/// Every field set away from its default, so a reversion cannot hide behind a
/// value that happens to match one.
private func customConfig() -> ChargeConfig {
    ChargeConfig(
        upperLimit: 90, lowerLimit: 70, thermalCutoff: 45,
        sleepPolicy: .chargeIfLow, preventIdleSleepWhileCharging: true
    )
}

func runControlTests() {
    test("status round-trips over the socket") {
        try withServer { path, _ in
            let response = try ControlClient.send(ControlRequest(command: .status), to: path)
            expectTrue(response.ok)
            let received = try expectNotNil(response.report)
            expectEqual(received.upperLimit, 80)
            expectEqual(received.lowerLimit, 75)
            expectEqual(received.gate, "closed")
            expectEqual(received.decidedAt.timeIntervalSince1970, 1_700_000_000)
        }
    }

    test("setLimit reaches the daemon and reports what will be in force") {
        let lock = NSLock()
        var applied: ChargeConfig?
        try withServer(apply: { config in
            lock.lock(); applied = config; lock.unlock()
        }) { path, _ in
            let response = try ControlClient.send(
                ControlRequest(command: .setLimit, upper: 65, lower: 60), to: path
            )
            expectTrue(response.ok)
            expectEqual(response.report?.upperLimit, 65)
            expectEqual(response.report?.lowerLimit, 60)
        }
        lock.lock()
        let seen = applied
        lock.unlock()
        expectEqual(seen?.upperLimit, 65)
        expectEqual(seen?.lowerLimit, 60)
    }

    test("an out-of-range limit is clamped and the change is reported") {
        // The socket must not be a way around the bounds every other path obeys.
        try withServer { path, _ in
            let response = try ControlClient.send(
                ControlRequest(command: .setLimit, upper: 3), to: path
            )
            expectTrue(response.ok)
            expectEqual(response.report?.upperLimit, 80, "3% should have been refused")
            expectFalse(response.notes.isEmpty, "a clamped value must be reported, not applied quietly")
        }
    }

    test("setLimit without a percentage is refused") {
        try withServer { path, _ in
            let response = try ControlClient.send(ControlRequest(command: .setLimit), to: path)
            expectFalse(response.ok)
            _ = try expectNotNil(response.error)
        }
    }

    test("disable asks for a limit of 100") {
        let lock = NSLock()
        var applied: ChargeConfig?
        try withServer(apply: { config in
            lock.lock(); applied = config; lock.unlock()
        }) { path, _ in
            let response = try ControlClient.send(ControlRequest(command: .disable), to: path)
            expectTrue(response.ok)
            expectEqual(response.report?.upperLimit, 100)
        }
        lock.lock()
        let seen = applied
        lock.unlock()
        expectTrue(seen?.isLimitingDisabled == true)
    }

    test("reload is passed through") {
        let lock = NSLock()
        var reloads = 0
        try withServer(reload: { lock.lock(); reloads += 1; lock.unlock() }) { path, _ in
            expectTrue(try ControlClient.send(ControlRequest(command: .reload), to: path).ok)
        }
        lock.lock()
        let seen = reloads
        lock.unlock()
        expectEqual(seen, 1)
    }

    test("a daemon that has not decided yet says so instead of inventing a report") {
        try withServer(publish: nil) { path, _ in
            let response = try ControlClient.send(ControlRequest(command: .status), to: path)
            expectFalse(response.ok)
            expectNil(response.report)
        }
    }

    test("garbage on the socket gets an error, not a crash") {
        try withServer { path, _ in
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(descriptor) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            expectTrue(fillSocketAddress(&address, with: path))
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            expectEqual(connected, 0)

            let junk = Array("not json at all\n".utf8)
            _ = junk.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }

            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = read(descriptor, &buffer, buffer.count)
            expectTrue(count > 0, "the server should answer rather than drop the connection")

            let response = try ControlProtocol.decodeResponse(Data(buffer[0..<max(count, 0)]))
            expectFalse(response.ok)
        }
    }

    test("no socket at all reports the daemon as not running") {
        do {
            _ = try ControlClient.send(
                ControlRequest(command: .status),
                to: NSTemporaryDirectory() + "dranik-absent-\(UUID().uuidString).sock"
            )
            expectTrue(false, "expected a failure")
        } catch ControlClient.Failure.notRunning {
            // Expected.
        } catch {
            expectTrue(false, "wrong error: \(error)")
        }
    }

    test("a stale socket file left by a crashed daemon is replaced, not fatal") {
        let path = NSTemporaryDirectory() + "dranik-stale-\(UUID().uuidString).sock"
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = ControlServer(
            path: path, initialConfig: ChargeConfig(), applyConfig: { _ in }, reloadConfig: {}
        )
        try server.start()
        defer { server.stop() }
        server.publish(report(), config: ChargeConfig())

        expectTrue(try ControlClient.send(ControlRequest(command: .status), to: path).ok)
    }

    test("stopping removes the socket so the next start is clean") {
        let path = NSTemporaryDirectory() + "dranik-\(UUID().uuidString).sock"
        let server = ControlServer(
            path: path, initialConfig: ChargeConfig(), applyConfig: { _ in }, reloadConfig: {}
        )
        try server.start()
        expectTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        expectFalse(FileManager.default.fileExists(atPath: path))
    }

    test("an over-long socket path is refused rather than silently truncated") {
        // sun_path is 104 bytes. Truncation would bind the wrong path.
        var address = sockaddr_un()
        expectFalse(fillSocketAddress(&address, with: "/tmp/" + String(repeating: "x", count: 200)))
        expectTrue(fillSocketAddress(&address, with: "/tmp/short.sock"))
    }

    // MARK: - A command changes what it names, and nothing else

    // The whole group exists because `disable` and `setLimit` used to rebuild the
    // configuration from scratch, so every field they did not mention reverted to
    // a default — and the daemon then wrote that to disk. Turning limiting off
    // permanently reset the thermal cutoff and the sleep policy, silently.

    test("disable changes the limit and nothing else") {
        let lock = NSLock()
        var applied: ChargeConfig?
        let original = customConfig()
        try withServer(
            apply: { config in lock.lock(); applied = config; lock.unlock() },
            publish: report(upper: 90, lower: 70),
            config: original
        ) { path, _ in
            expectTrue(try ControlClient.send(ControlRequest(command: .disable), to: path).ok)
        }
        lock.lock()
        let seen = applied
        lock.unlock()

        let config = try expectNotNil(seen)
        expectTrue(config.isLimitingDisabled)
        expectEqual(config.thermalCutoff, original.thermalCutoff)
        expectEqual(config.sleepPolicy, original.sleepPolicy)
        expectEqual(
            config.preventIdleSleepWhileCharging, original.preventIdleSleepWhileCharging,
            "turning limiting off must not turn off a setting nobody mentioned"
        )
    }

    test("setLimit changes the limit and nothing else") {
        let lock = NSLock()
        var applied: ChargeConfig?
        let original = customConfig()
        try withServer(
            apply: { config in lock.lock(); applied = config; lock.unlock() },
            publish: report(upper: 90, lower: 70),
            config: original
        ) { path, _ in
            expectTrue(try ControlClient.send(
                ControlRequest(command: .setLimit, upper: 75), to: path
            ).ok)
        }
        lock.lock()
        let seen = applied
        lock.unlock()

        let config = try expectNotNil(seen)
        expectEqual(config.upperLimit, 75)
        expectEqual(config.thermalCutoff, original.thermalCutoff)
        expectEqual(config.sleepPolicy, original.sleepPolicy)
        expectEqual(config.preventIdleSleepWhileCharging, true)
    }

    test("a limit change with no resume point keeps the band the owner set") {
        let lock = NSLock()
        var applied: ChargeConfig?
        // A 20-point band, nothing like the 5-point default.
        let original = ChargeConfig(upperLimit: 90, lowerLimit: 70)
        try withServer(
            apply: { config in lock.lock(); applied = config; lock.unlock() },
            publish: report(upper: 90, lower: 70),
            config: original
        ) { path, _ in
            expectTrue(try ControlClient.send(
                ControlRequest(command: .setLimit, upper: 60), to: path
            ).ok)
        }
        lock.lock()
        let seen = applied
        lock.unlock()
        // 70 no longer fits under 60, so the width carries across rather than
        // collapsing to the default hysteresis.
        expectEqual(seen?.lowerLimit, 40)
    }

    test("disable works before the daemon has decided anything") {
        // The way out must not depend on the daemon being well enough to have
        // reached a decision — that is when it is most likely to be needed.
        let lock = NSLock()
        var applied: ChargeConfig?
        try withServer(
            apply: { config in lock.lock(); applied = config; lock.unlock() },
            publish: nil,
            config: customConfig()
        ) { path, _ in
            expectTrue(try ControlClient.send(ControlRequest(command: .disable), to: path).ok)
        }
        lock.lock()
        let seen = applied
        lock.unlock()

        let config = try expectNotNil(seen, "disable must reach the daemon regardless")
        expectTrue(config.isLimitingDisabled)
        expectEqual(config.thermalCutoff, 45, "and still not reset anything on the way")
    }

    test("retrust reaches the daemon when the gate has been disarmed") {
        // The way back. Before this the only route was restarting the daemon,
        // and on 2026-08-19 nobody did for two days.
        let lock = NSLock()
        var restored = 0
        try withServer(
            restore: { lock.lock(); restored += 1; lock.unlock() },
            publish: report(trusted: false)
        ) { path, _ in
            let response = try ControlClient.send(ControlRequest(command: .retrust), to: path)
            expectTrue(response.ok)
        }
        lock.lock()
        let seen = restored
        lock.unlock()
        expectEqual(seen, 1)
    }

    test("retrust on a healthy gate says so instead of doing something") {
        let lock = NSLock()
        var restored = 0
        try withServer(
            restore: { lock.lock(); restored += 1; lock.unlock() },
            publish: report(trusted: true)
        ) { path, _ in
            let response = try ControlClient.send(ControlRequest(command: .retrust), to: path)
            expectTrue(response.ok)
            expectFalse(response.notes.isEmpty, "it should say there was nothing to do")
        }
        lock.lock()
        let seen = restored
        lock.unlock()
        expectEqual(seen, 0, "re-arming a gate that is armed must not disturb it")
    }

    // MARK: - Fields a client needs to tell states apart

    test("the report says whether this machine can be limited at all") {
        let unsupported = DaemonReport(
            upperLimit: 80, lowerLimit: 75, thermalCutoff: 40, sleepPolicy: "holdLimit",
            gate: "open", reason: "no charge gate on this machine",
            gateIsTrusted: true, limitingIsSupported: false,
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try withServer(publish: unsupported) { path, _ in
            let response = try ControlClient.send(ControlRequest(command: .status), to: path)
            expectEqual(response.report?.limitingIsSupported, false)
        }
    }

    test("a report from an older daemon decodes to defaults rather than failing") {
        // The daemon keeps running across an install, so a new client talking to
        // the previous build is routine, not an edge case. Failing to parse would
        // be reported as "not responding" by something responding perfectly.
        let old = """
        {"decidedAt":"2023-11-14T22:13:20Z","gate":"closed","gateIsTrusted":true,\
        "lowerLimit":75,"reason":"reached the limit","sleepPolicy":"holdLimit",\
        "thermalCutoff":40,"upperLimit":80}
        """.replacingOccurrences(of: "\\\n        ", with: "")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DaemonReport.self, from: Data(old.utf8))

        expectEqual(report.upperLimit, 80)
        expectTrue(report.limitingIsSupported, "an old daemon predates the question")
        expectFalse(report.preventIdleSleepWhileCharging)
        expectEqual(report.version, "unknown", "a version it never sent must not read as ours")
    }

    test("requests and responses survive a round trip through JSON") {
        let request = ControlRequest(command: .setLimit, upper: 70, lower: 65)
        let encoded = try ControlProtocol.encode(request)
        expectEqual(encoded.last, 0x0A, "the protocol is line-delimited")
        expectEqual(try ControlProtocol.decodeRequest(encoded), request)

        let response = ControlResponse(ok: true, report: report(), notes: ["a note"])
        expectEqual(try ControlProtocol.decodeResponse(ControlProtocol.encode(response)), response)
    }
}
