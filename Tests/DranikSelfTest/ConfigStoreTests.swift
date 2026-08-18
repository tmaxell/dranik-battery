import DranikCore
import Foundation

private func temporaryPath(_ name: String) -> String {
    NSTemporaryDirectory() + "dranik-test-\(UUID().uuidString)-\(name)"
}

func runConfigStoreTests() {
    test("a saved config comes back identical") {
        let path = temporaryPath("config.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let original = ChargeConfig(
            upperLimit: 70, lowerLimit: 62, thermalCutoff: 38,
            sleepPolicy: .allowCharge, preventIdleSleepWhileCharging: true
        )
        try ConfigStore.save(original, to: path)

        let loaded = ConfigStore.load(from: path)
        expectEqual(loaded.config, original)
        expectTrue(loaded.problems.isEmpty, "\(loaded.problems)")
    }

    test("a missing file yields defaults and says so") {
        let result = ConfigStore.load(from: temporaryPath("absent.json"))
        expectEqual(result.config, ChargeConfig())
        expectFalse(result.problems.isEmpty, "a missing file should be reported")
    }

    test("unparseable contents yield defaults rather than refusing to load") {
        // A daemon that will not start is worse than one on defaults: the gate
        // it left shut stays shut until something runs and reopens it.
        let path = temporaryPath("broken.json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "this is not json".write(toFile: path, atomically: true, encoding: .utf8)

        let result = ConfigStore.load(from: path)
        expectEqual(result.config, ChargeConfig())
        expectFalse(result.problems.isEmpty)
    }

    test("out-of-range values in a file are clamped on the way in") {
        // The file is not a way around the bounds.
        let path = temporaryPath("absurd.json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"upperLimit": 3, "lowerLimit": 1, "thermalCutoff": 900}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        let result = ConfigStore.load(from: path)
        expectEqual(result.config.upperLimit, 80)
        expectEqual(result.config.thermalCutoff, 40)
        expectTrue(result.config.lowerLimit < result.config.upperLimit)
        expectFalse(result.problems.isEmpty, "clamping should be reported")
    }

    test("a partial file picks up defaults for what it omits") {
        let path = temporaryPath("partial.json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"upperLimit": 65}"#.write(toFile: path, atomically: true, encoding: .utf8)

        let result = ConfigStore.load(from: path)
        expectEqual(result.config.upperLimit, 65)
        expectEqual(result.config.lowerLimit, 60, "should default to upper - 5")
        expectEqual(result.config.thermalCutoff, 40)
        expectEqual(result.config.sleepPolicy, .holdLimit)
    }

    test("an unknown sleep policy falls back rather than failing the load") {
        let path = temporaryPath("policy.json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"upperLimit": 80, "sleepPolicy": "teleport"}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        let result = ConfigStore.load(from: path)
        expectEqual(result.config, ChargeConfig())
        expectFalse(result.problems.isEmpty)
    }

    test("the corrections list is not persisted as if it were a setting") {
        let path = temporaryPath("corrections.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let clamped = ChargeConfig(upperLimit: 5)
        expectFalse(clamped.corrections.isEmpty)
        try ConfigStore.save(clamped, to: path)

        let text = try String(contentsOfFile: path, encoding: .utf8)
        expectFalse(text.contains("corrections"), "corrections leaked into the file")
        expectTrue(ConfigStore.load(from: path).problems.isEmpty)
    }

    test("saving creates the directory it needs") {
        let directory = NSTemporaryDirectory() + "dranik-test-\(UUID().uuidString)"
        let path = directory + "/nested/config.json"
        defer { try? FileManager.default.removeItem(atPath: directory) }

        try ConfigStore.save(ChargeConfig(), to: path)
        expectTrue(FileManager.default.fileExists(atPath: path))
    }

    test("daemon state round-trips") {
        let path = temporaryPath("state.json")
        defer { StateStore.remove(at: path) }

        let state = DaemonState(gateIsClosed: true, reason: "reached 80%")
        try StateStore.save(state, to: path)

        let loaded = try expectNotNil(StateStore.load(from: path))
        expectEqual(loaded.gateIsClosed, true)
        expectEqual(loaded.reason, "reached 80%")
        expectClose(
            loaded.updatedAt.timeIntervalSince1970,
            state.updatedAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    test("state is written so only root can read it") {
        let path = temporaryPath("state-perms.json")
        defer { StateStore.remove(at: path) }
        try StateStore.save(DaemonState(gateIsClosed: false, reason: "x"), to: path)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        expectEqual(permissions, 0o600)
    }

    test("missing state reads as nil, not as a fabricated one") {
        expectNil(StateStore.load(from: temporaryPath("no-state.json")))
    }
}

func runInstanceLockTests() {
    test("a second instance cannot take the lock") {
        let path = temporaryPath("lock.pid")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try InstanceLock(path: path)
        do {
            _ = try InstanceLock(path: path)
            expectTrue(false, "the second lock should have been refused")
        } catch InstanceLock.Failure.alreadyRunning(let pid) {
            expectEqual(pid, getpid(), "should report who holds it")
        } catch {
            expectTrue(false, "wrong error: \(error)")
        }
        first.release()
    }

    test("releasing lets the next instance in") {
        let path = temporaryPath("lock-release.pid")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try InstanceLock(path: path)
        first.release()

        let second = try InstanceLock(path: path)
        second.release()
    }

    test("the lock records the holder's pid") {
        let path = temporaryPath("lock-pid.pid")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lock = try InstanceLock(path: path)
        defer { lock.release() }

        let contents = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        expectEqual(contents, "\(getpid())")
    }

    test("a shorter pid does not leave digits of a longer one behind") {
        let path = temporaryPath("lock-truncate.pid")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try "9999999999\n".write(toFile: path, atomically: true, encoding: .utf8)
        let lock = try InstanceLock(path: path)
        defer { lock.release() }

        let contents = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        expectEqual(contents, "\(getpid())")
    }

    test("the lock creates the directory it needs") {
        let directory = NSTemporaryDirectory() + "dranik-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let lock = try InstanceLock(path: directory + "/run/dranikd.pid")
        lock.release()
    }
}
