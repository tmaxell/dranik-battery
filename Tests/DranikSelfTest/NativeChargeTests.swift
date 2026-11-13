import DranikCore
import DranikDaemon
import DranikNative
import Foundation

private final class FakeNativeTransport: NativeChargeTransport {
    var agent = NativeAgentObservation()
    var limits: [Int] = []
    var writes: [Int] = []
    var deferRegistration = false
    var failRead = false
    var failWrite = false
    func snapshot() throws -> NativeAgentObservation {
        if failRead { throw NativeControlError.failed("test read failure") }
        return agent
    }
    func registrations() throws -> [Int] { limits }
    func requestLimit(_ target: Int) throws {
        writes.append(target)
        if failWrite { throw NativeControlError.failed("test write failure") }
        agent.limit = target; agent.enabled = true
        if !deferRegistration { limits = [target] }
    }
    func disable() throws {
        writes.append(100)
        if failWrite { throw NativeControlError.failed("test disable failure") }
        agent.enabled = false; agent.limit = 100
        if !deferRegistration { limits = [] }
    }
}

func runNativeChargeTests() {
    func temporary(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dranik-native-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            if directory.lastPathComponent.hasPrefix("dranik-native-test-") {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try body(directory.appendingPathComponent("original.json").path)
    }
    func facts(_ charge: Int, _ charging: Bool, ac: Bool = true) -> BatteryFacts {
        BatteryFacts(percentage: charge, isCharging: charging, isExternalConnected: ac, temperature: 35)
    }
    test("native registration parser accepts only active manual policies") {
        let text = """
        Battery level limits:
        (
          { Terminated = 0; chargeSocLimitSoc = 80; chargeSocLimitReason = manualChargeLimit; },
          { Terminated = 1; chargeSocLimitSoc = 75; chargeSocLimitReason = manualChargeLimit; },
          { Terminated = 0; chargeSocLimitSoc = 90; chargeSocLimitReason = otherPolicy; }
        )
        """
        expectEqual(try NativeChargePolicy.manualRegistrations(in: text), [80])
        expectEqual(try NativeChargePolicy.manualRegistrations(in: "No battery level limits set\n"), [])
        expectEqual(try NativeChargePolicy.manualRegistrations(in: "Battery level limits: ()"), [])
    }
    test("native registration parser fails closed for unknown or malformed output") {
        for text in ["", "80", "some error: 80", "Battery level limits: ({ chargeSocLimitSoc=80; })",
                     "Battery level limits: ({Terminated=2;chargeSocLimitSoc=80;chargeSocLimitReason=manualChargeLimit;})",
                     "Battery level limits: ({Terminated=0;chargeSocLimitSoc=180;chargeSocLimitReason=manualChargeLimit;})",
                     "Battery level limits: ({Terminated=0;chargeSocLimitSoc=80;chargeSocLimitReason=manualChargeLimit;}) extra"] {
            do { _ = try NativeChargePolicy.manualRegistrations(in: text); expectTrue(false, "accepted \(text)") }
            catch { }
        }
    }
    test("native policy registration is not proof charging stopped") {
        let agent = NativeAgentObservation(limit: 80, enabled: true)
        let result = NativeChargePolicy.describe(target: 80, agent: agent, registrations: [80], battery: facts(100, true), milliamps: 500)
        expectEqual(result.state, "registered")
        expectEqual(result.reasonCode, "nativeApplied")
        expectFalse(result.reason.contains("not charging"))
    }
    test("native policy describes calibration, drain, hold and on-battery separately") {
        var agent = NativeAgentObservation(limit: 80, enabled: true)
        func code(_ battery: BatteryFacts, _ amps: Int) -> String {
            NativeChargePolicy.describe(target: 80, agent: agent, registrations: [80], battery: battery, milliamps: amps).reasonCode
        }
        expectEqual(code(facts(100, false), -600), "nativeComingDown")
        expectEqual(code(facts(80, false), 0), "nativeHolding")
        expectEqual(code(facts(70, true), 1200), "nativeCharging")
        expectEqual(code(facts(70, false, ac: false), -500), "nativeOnBattery")
        agent.fullChargeOverride = true
        expectEqual(code(facts(99, true), 1000), "nativeOverride")
    }
    test("native mismatched or absent registration is pending") {
        let agent = NativeAgentObservation(limit: 80, enabled: true)
        for limits in [[], [75], [80, 75]] {
            expectEqual(NativeChargePolicy.describe(target: 80, agent: agent, registrations: limits,
                                                     battery: facts(100, false), milliamps: -600).state, "pending")
        }
        expectEqual(NativeChargePolicy.describe(target: 100, agent: agent, registrations: [80],
                                                 battery: facts(100, false), milliamps: 0).state, "pending")
    }
    test("native dry run never writes or creates a backup") {
        try temporary { path in
            let fake = FakeNativeTransport()
            let controller = NativeChargeController(transport: fake, baselinePath: path)
            let decision = controller.reconcile(target: 80, dryRun: true, battery: facts(100, true), milliamps: 900)
            expectEqual(decision.state, "pending")
            expectTrue(fake.writes.isEmpty)
            expectFalse(FileManager.default.fileExists(atPath: path))
        }
    }
    test("native first write captures original policy and uninstall restores it") {
        try temporary { path in
            let fake = FakeNativeTransport()
            let controller = NativeChargeController(transport: fake, baselinePath: path)
            expectEqual(controller.reconcile(target: 80, dryRun: false, battery: facts(100, true), milliamps: 900).state, "registered")
            expectTrue(FileManager.default.fileExists(atPath: path))
            // Simulate a daemon upgrade: original backup must survive it.
            let successor = NativeChargeController(transport: fake, baselinePath: path)
            _ = successor.reconcile(target: 75, dryRun: false, battery: facts(99, false), milliamps: -500)
            try successor.restoreOriginal()
            expectFalse(fake.agent.enabled)
            expectEqual(fake.writes, [80, 75, 100])
            expectFalse(FileManager.default.fileExists(atPath: path))
        }
    }
    test("native restore preserves a pre-existing enabled target") {
        try temporary { path in
            let fake = FakeNativeTransport(); fake.agent.limit = 85; fake.agent.enabled = true; fake.limits = [85]
            let controller = NativeChargeController(transport: fake, baselinePath: path)
            _ = controller.reconcile(target: 80, dryRun: false, battery: facts(100, true), milliamps: 900)
            try controller.restoreOriginal()
            expectEqual(fake.agent.limit, 85)
            expectTrue(fake.agent.enabled)
        }
    }
    test("native backup failure prevents mutation") {
        try temporary { path in
            try Data("bad original".utf8).write(to: URL(fileURLWithPath: path))
            let fake = FakeNativeTransport()
            let controller = NativeChargeController(transport: fake, baselinePath: path)
            expectEqual(controller.reconcile(target: 80, dryRun: false, battery: nil, milliamps: nil).state, "error")
            expectTrue(fake.writes.isEmpty)
        }
    }
    test("native read failures and malformed registration never imply success") {
        try temporary { path in
            let fake = FakeNativeTransport(); fake.failRead = true
            let controller = NativeChargeController(transport: fake, baselinePath: path)
            expectEqual(controller.reconcile(target: 80, dryRun: false, battery: nil, milliamps: nil).state, "error")
            expectTrue(fake.writes.isEmpty)
        }
    }
    test("native registration delay is pending without repeated target writes") {
        try temporary { path in
            let fake = FakeNativeTransport(); fake.deferRegistration = true
            let controller = NativeChargeController(transport: fake, baselinePath: path)
            for _ in 0..<3 { expectEqual(controller.reconcile(target: 80, dryRun: false, battery: facts(100, true), milliamps: 900).state, "pending") }
            expectEqual(fake.writes, [80])
            fake.limits = [80]
            expectEqual(controller.reconcile(target: 80, dryRun: false, battery: facts(100, false), milliamps: -500).state, "registered")
        }
    }
    test("native write errors are reported and retried no faster than a minute") {
        try temporary { path in
            let fake = FakeNativeTransport(); fake.failWrite = true
            var time = Date()
            let controller = NativeChargeController(transport: fake, baselinePath: path, now: { time })
            expectEqual(controller.reconcile(target: 80, dryRun: false, battery: nil, milliamps: nil).state, "error")
            _ = controller.reconcile(target: 80, dryRun: false, battery: nil, milliamps: nil)
            expectEqual(fake.writes, [80])
            time.addTimeInterval(61)
            _ = controller.reconcile(target: 80, dryRun: false, battery: nil, milliamps: nil)
            expectEqual(fake.writes, [80, 80])
        }
    }
    test("native disable only confirms release after active registrations disappear") {
        try temporary { path in
            let fake = FakeNativeTransport(); fake.agent.enabled = true; fake.agent.limit = 80; fake.limits = [80]; fake.deferRegistration = true
            let controller = NativeChargeController(transport: fake, baselinePath: path)
            expectEqual(controller.reconcile(target: 100, dryRun: false, battery: facts(80, false), milliamps: 0).state, "pending")
            fake.limits = []
            expectEqual(controller.reconcile(target: 100, dryRun: false, battery: facts(80, true), milliamps: 600).state, "disabled")
        }
    }
    test("native helper runner captures output and rejects failure") {
        expectEqual(String(data: try NativeCommandRunner.run(executable: "/usr/bin/printf", arguments: ["hello"]), encoding: .utf8), "hello")
        do { _ = try NativeCommandRunner.run(executable: "/usr/bin/false", arguments: []); expectTrue(false) } catch { }
    }
    test("native helper runner kills a stalled operation within deadline") {
        let start = Date()
        do { _ = try NativeCommandRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1); expectTrue(false) }
        catch { expectTrue(String(describing: error).contains("timed out")) }
        expectTrue(Date().timeIntervalSince(start) < 3)
    }
    test("native Swift wrapper rejects invalid targets before bridge calls") {
        for target in [-1, 0, 49, 101] {
            do { try NativeChargeClient().requestLimit(target); expectTrue(false) } catch { }
        }
    }
}
