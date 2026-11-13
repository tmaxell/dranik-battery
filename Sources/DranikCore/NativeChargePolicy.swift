import Foundation

/// Read-side facts, deliberately independent of private framework code.
public struct NativeAgentObservation: Codable, Equatable, Sendable {
    public var supported: Bool
    public var limit: Int
    public var enabled: Bool
    public var availableLimits: [Int]
    public var fullChargeOverride: Bool
    public init(supported: Bool = true, limit: Int = 100, enabled: Bool = false,
                availableLimits: [Int] = [80, 85, 90, 95, 100], fullChargeOverride: Bool = false) {
        self.supported = supported; self.limit = limit; self.enabled = enabled
        self.availableLimits = availableLimits; self.fullChargeOverride = fullChargeOverride
    }
}

public struct NativeChargeDecision: Equatable, Sendable {
    public let state: String
    public let reasonCode: String
    public let reason: String
    public let registeredLimit: Int?
    public init(state: String, reasonCode: String, reason: String, registeredLimit: Int?) {
        self.state = state; self.reasonCode = reasonCode; self.reason = reason; self.registeredLimit = registeredLimit
    }
}

public enum NativeChargePolicy {
    /// Registration confirms OS policy, never physical charge inhibition. The
    /// latter comes only from a fresh battery observation.
    public static func describe(target: Int, agent: NativeAgentObservation,
                                registrations: [Int], battery: BatteryFacts?, milliamps: Int?) -> NativeChargeDecision {
        func result(_ state: String, _ code: String, _ message: String, _ registered: Int? = nil) -> NativeChargeDecision {
            NativeChargeDecision(state: state, reasonCode: code, reason: message, registeredLimit: registered)
        }
        guard agent.supported else { return result("error", "nativeError", "macOS native charge limiting is unavailable") }
        if target == 100 {
            return !agent.enabled && registrations.isEmpty
                ? result("disabled", "nativeDisabled", "native manual limit released; charging is managed by macOS")
                : result("pending", "nativePending", "waiting for macOS to release the manual charge limit")
        }
        guard agent.enabled && agent.limit == target else {
            return result("pending", "nativePending", "waiting for PowerUIAgent to load the requested \(target)% target")
        }
        guard !registrations.isEmpty, registrations.allSatisfy({ $0 == target }) else {
            if battery?.isExternalConnected == false {
                return result("pending", "nativeOnBattery", "on battery; macOS target is loaded, registration will be checked on AC power")
            }
            return result("pending", "nativePending", "macOS has loaded \(target)%, but its active registration is not confirmed yet")
        }
        if agent.fullChargeOverride {
            return result("override", "nativeOverride", "macOS temporarily overrides the limit to calibrate the battery gauge", target)
        }
        guard let battery else {
            return result("registered", "nativeApplied", "\(target)% registered with macOS; physical charging state is not readable", target)
        }
        if !battery.isExternalConnected {
            return result("registered", "nativeOnBattery", "on battery; the native \(target)% target remains configured", target)
        }
        if battery.isCharging {
            // Do not call a successful policy write 'holding'. In particular,
            // the old 100% reading can persist until Apple's next update.
            return result("registered", battery.percentage < target ? "nativeCharging" : "nativeApplied",
                          battery.percentage < target
                            ? "charging toward the native \(target)% target"
                            : "\(target)% registered; waiting for macOS to stop charging", target)
        }
        if battery.percentage > target, let milliamps, milliamps < -20 {
            return result("registered", "nativeComingDown", "macOS is using the battery to come down toward \(target)% while plugged in", target)
        }
        if battery.percentage >= target - 2 {
            return result("registered", "nativeHolding", "\(target)% registered and the battery is not charging", target)
        }
        return result("registered", "nativeApplied", "\(target)% registered; macOS currently holds charging for its own policy", target)
    }

    /// pmset emits an OpenStep property list after its heading. Parse the full
    /// structure instead of accepting a percentage found in an arbitrary line.
    public static func manualRegistrations(in output: String) throws -> [Int] {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "No battery level limits set" { return [] }
        let heading = "Battery level limits:"
        guard text.utf8.count <= 64 * 1024, text.hasPrefix(heading) else { throw RegistrationError.invalid }
        let body = String(text.dropFirst(heading.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("("), body.hasSuffix(")"), let data = body.data(using: .utf8),
              let rows = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]]
        else { throw RegistrationError.invalid }
        var result: [Int] = []
        for row in rows {
            func integer(_ key: String) -> Int? {
                if let string = row[key] as? String, !string.isEmpty,
                   string.allSatisfy({ $0.isASCII && $0.isNumber }) { return Int(string) }
                return nil
            }
            guard let target = integer("chargeSocLimitSoc"), (1...100).contains(target),
                  let terminated = integer("Terminated"), (0...1).contains(terminated),
                  let reason = row["chargeSocLimitReason"] as? String, !reason.isEmpty
            else { throw RegistrationError.invalid }
            if reason == "manualChargeLimit", terminated == 0 { result.append(target) }
        }
        return result
    }
    public enum RegistrationError: Error { case invalid }
}
