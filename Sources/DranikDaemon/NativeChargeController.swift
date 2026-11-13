import DranikCore
import Foundation

public protocol NativeChargeTransport {
    func snapshot() throws -> NativeAgentObservation
    func requestLimit(_ target: Int) throws
    func disable() throws
    func registrations() throws -> [Int]
}

public struct NativeHelperTransport: NativeChargeTransport {
    public let helperPath: String
    public init(helperPath: String = NativeHelperTransport.defaultPath) { self.helperPath = helperPath }
    public static var defaultPath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent("dranik-native-helper").path
    }
    private func call(_ arguments: [String]) throws -> NativeAgentObservation {
        let data = try NativeCommandRunner.run(executable: helperPath, arguments: arguments)
        let value = try JSONDecoder().decode(NativeAgentObservation.self, from: data)
        guard (value.supported ? (1...100).contains(value.limit) : value.limit == 0),
              value.availableLimits.allSatisfy({ (1...100).contains($0) }) else {
            throw NativeControlError.invalidState("PowerUIAgent returned an invalid charge target")
        }
        return value
    }
    public func snapshot() throws -> NativeAgentObservation { try call(["status"]) }
    public func requestLimit(_ target: Int) throws { _ = try call(["set", String(target)]) }
    public func disable() throws { _ = try call(["disable"]) }
    public func registrations() throws -> [Int] {
        let data = try NativeCommandRunner.run(executable: "/usr/bin/pmset", arguments: ["-g", "battlimit"], timeout: 2)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NativeControlError.invalidState("pmset returned non-text charge registrations")
        }
        do { return try NativeChargePolicy.manualRegistrations(in: text) }
        catch { throw NativeControlError.invalidState("unrecognized pmset output; native registration cannot be confirmed") }
    }
}

/// Serial daemon-side coordinator. Capture the user's original effective native
/// policy BEFORE any mutation; an ordinary restart never overwrites that backup.
public final class NativeChargeController {
    public static let defaultBaselinePath = "/Library/Application Support/dranik/native-original.json"
    private let transport: NativeChargeTransport
    private let baselinePath: String
    private let now: () -> Date
    private var lastAttempt: (target: Int, at: Date)?
    private var unconfirmedSince: (target: Int, at: Date)?
    public private(set) var observation: NativeAgentObservation?
    public private(set) var decision = NativeChargeDecision(state: "pending", reasonCode: "nativePending",
                                                            reason: "checking native charge policy", registeredLimit: nil)
    public init(transport: NativeChargeTransport = NativeHelperTransport(),
                baselinePath: String = NativeChargeController.defaultBaselinePath,
                now: @escaping () -> Date = Date.init) {
        self.transport = transport; self.baselinePath = baselinePath; self.now = now
    }
    public func probe() throws -> Bool {
        observation = try transport.snapshot()
        return observation?.supported == true
    }

    @discardableResult
    public func reconcile(target: Int, dryRun: Bool, battery: BatteryFacts?, milliamps: Int?) -> NativeChargeDecision {
        do {
            guard ChargeConfig.upperRange.contains(target) else {
                throw NativeControlError.invalidState("native target must be 50 through 100")
            }
            var agent = try transport.snapshot()
            observation = agent
            guard agent.supported else { throw NativeControlError.unavailable("native charge limiting is no longer available") }
            var registered = try transport.registrations()
            let needsChange = target == 100 ? (agent.enabled || !registered.isEmpty) : (!agent.enabled || agent.limit != target)
            if needsChange && !dryRun {
                // A stream of power events must not launch an unbounded stream
                // of writes while Apple is still processing an earlier request.
                let mayRetry = lastAttempt.map { $0.target != target || now().timeIntervalSince($0.at) >= 60 } ?? true
                if !mayRetry, decision.state == "error" { return decision }
                if mayRetry {
                    try preserveOriginal(agent)
                    lastAttempt = (target, now())
                    if target == 100 { try transport.disable() }
                    else { try transport.requestLimit(target) }
                    agent = try transport.snapshot()
                    observation = agent
                    registered = try transport.registrations()
                }
            }
            decision = NativeChargePolicy.describe(target: target, agent: agent,
                                                    registrations: registered, battery: battery, milliamps: milliamps)
            let waitingOnAC = battery?.isExternalConnected == true && !agent.fullChargeOverride &&
                (decision.state == "pending" || (target < 100 && battery?.isCharging == true && (battery?.percentage ?? 0) > target + 2))
            if waitingOnAC && !dryRun {
                if unconfirmedSince?.target != target { unconfirmedSince = (target, now()) }
                if let start = unconfirmedSince, now().timeIntervalSince(start.at) >= 300 {
                    decision = NativeChargeDecision(state: "error", reasonCode: "nativeError",
                        reason: "macOS has not confirmed the requested charge behaviour for five minutes; inspect native policy and battery state",
                        registeredLimit: decision.registeredLimit)
                }
            } else { unconfirmedSince = nil }
            if dryRun && needsChange {
                decision = NativeChargeDecision(state: "pending", reasonCode: "nativePending",
                                                reason: "DRY RUN — would request \(target)%; no native setting was changed",
                                                registeredLimit: nil)
            }
        } catch {
            decision = NativeChargeDecision(state: "error", reasonCode: "nativeError",
                                            reason: "native charge control: \(error)", registeredLimit: nil)
        }
        return decision
    }

    /// Explicit maintenance only, AFTER stopping the daemon. Restores the policy
    /// that predated Dranik, or does nothing if Dranik never changed native state.
    /// A failed confirmation leaves the backup intact for retry.
    public func restoreOriginal() throws {
        guard FileManager.default.fileExists(atPath: baselinePath) else { return }
        let original = try loadOriginal()
        if original.enabled { try transport.requestLimit(original.limit) }
        else { try transport.disable() }
        let agent = try transport.snapshot()
        let registered = try transport.registrations()
        let matches = original.enabled
            ? agent.enabled && agent.limit == original.limit && !registered.isEmpty && registered.allSatisfy({ $0 == original.limit })
            : !agent.enabled && registered.isEmpty
        guard matches else {
            throw NativeControlError.invalidState("original native policy was requested but its registration is not confirmed; backup retained, retry when on AC power")
        }
        // Exact fixed path is supplied at initialization, never taken from the
        // backup's content. Refuse directory/symlink files in loadOriginal.
        try FileManager.default.removeItem(atPath: baselinePath)
    }

    private struct Original: Codable {
        var format: Int = 1
        var enabled: Bool
        var limit: Int
    }
    private func loadOriginal() throws -> Original {
        let attributes = try FileManager.default.attributesOfItem(atPath: baselinePath)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4096 else {
            throw NativeControlError.invalidState("native original-policy backup is not a small regular file")
        }
        let original = try JSONDecoder().decode(Original.self, from: Data(contentsOf: URL(fileURLWithPath: baselinePath)))
        guard original.format == 1, (50...100).contains(original.limit), !original.enabled || original.limit < 100 else {
            throw NativeControlError.invalidState("native original-policy backup is invalid; refusing to replace it")
        }
        return original
    }
    private func preserveOriginal(_ agent: NativeAgentObservation) throws {
        if FileManager.default.fileExists(atPath: baselinePath) { _ = try loadOriginal(); return }
        guard (50...100).contains(agent.limit), !agent.enabled || agent.limit < 100 else {
            throw NativeControlError.invalidState("the existing native policy cannot be safely backed up; refusing to change it")
        }
        let url = URL(fileURLWithPath: baselinePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Original(enabled: agent.enabled, limit: agent.limit))
        let descriptor = open(baselinePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NativeControlError.failed("cannot create original native policy backup: \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        let parentDirectory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        defer { if parentDirectory >= 0 { close(parentDirectory) } }
        guard written == data.count, fsync(descriptor) == 0,
              parentDirectory >= 0, fsync(parentDirectory) == 0 else {
            // Retain any partial backup. Future loads reject it rather than
            // overwriting the only evidence of what preceded a failed write.
            throw NativeControlError.failed("original native policy could not be durably saved; no native change was attempted")
        }
    }
}
