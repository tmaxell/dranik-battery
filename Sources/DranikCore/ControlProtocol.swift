import Foundation

/// One request, one response, one line of JSON each.
///
/// A line protocol rather than anything cleverer so that the daemon can be
/// interrogated with `nc -U` when it is misbehaving — which is exactly when a
/// bespoke binary format is least welcome.
public struct ControlRequest: Codable, Equatable, Sendable {
    public enum Command: String, Codable, Sendable {
        case status
        case setLimit
        /// Shorthand for a limit of 100: stop managing charging entirely.
        case disable
        /// Re-read the configuration file without restarting.
        case reload
        /// Trust the charge gate again after a verification failure disarmed it.
        case retrust
    }

    public var command: Command
    public var upper: Int?
    public var lower: Int?

    public init(command: Command, upper: Int? = nil, lower: Int? = nil) {
        self.command = command
        self.upper = upper
        self.lower = lower
    }
}

/// What the daemon is doing, as of its last decision.
public struct DaemonReport: Codable, Equatable, Sendable {
    public var upperLimit: Int
    public var lowerLimit: Int
    public var thermalCutoff: Double
    public var sleepPolicy: String
    public var gate: String
    public var reason: String
    /// False once the daemon has stopped believing its own charge gate. It then
    /// refuses to close it, so the limit is not being enforced — worth showing
    /// rather than leaving to be discovered.
    public var gateIsTrusted: Bool
    /// The charger's own account of why it is not charging, as text.
    ///
    /// Distinct from `reason`, which is the daemon's. Where they disagree,
    /// something other than this daemon is holding charging back — macOS's own
    /// battery management, most likely, which is not readable as a setting from
    /// anywhere unprivileged. Reading the effect is possible where reading the
    /// preference is not.
    public var chargerReason: String?
    /// Whether this machine has a charge gate the daemon recognises at all.
    ///
    /// Without one the daemon still runs, still answers, and enforces nothing —
    /// a state otherwise indistinguishable from "the gate is open because it
    /// ought to be", which is the one reading a client must not offer.
    public var limitingIsSupported: Bool
    /// Reported so that a client changing the limit can put it back, and so that
    /// a laptop refusing to sleep has a visible reason.
    public var preventIdleSleepWhileCharging: Bool
    /// `ChargeReason.code` for the decision `reason` describes in prose.
    ///
    /// A client showing an icon or a warning branches on this; matching on the
    /// prose would break the first time a sentence is improved.
    public var reasonCode: String
    /// The daemon's own version. See `DranikVersion` for why a client cares.
    public var version: String
    public var decidedAt: Date

    public init(
        upperLimit: Int,
        lowerLimit: Int,
        thermalCutoff: Double,
        sleepPolicy: String,
        gate: String,
        reason: String,
        gateIsTrusted: Bool,
        chargerReason: String? = nil,
        reasonCode: String = "unknown",
        limitingIsSupported: Bool = true,
        preventIdleSleepWhileCharging: Bool = false,
        version: String = DranikVersion.current,
        decidedAt: Date
    ) {
        self.upperLimit = upperLimit
        self.lowerLimit = lowerLimit
        self.thermalCutoff = thermalCutoff
        self.sleepPolicy = sleepPolicy
        self.gate = gate
        self.reason = reason
        self.gateIsTrusted = gateIsTrusted
        self.chargerReason = chargerReason
        self.reasonCode = reasonCode
        self.limitingIsSupported = limitingIsSupported
        self.preventIdleSleepWhileCharging = preventIdleSleepWhileCharging
        self.version = version
        self.decidedAt = decidedAt
    }

    private enum CodingKeys: String, CodingKey {
        case upperLimit, lowerLimit, thermalCutoff, sleepPolicy, gate, reason
        case gateIsTrusted, chargerReason, reasonCode, limitingIsSupported
        case preventIdleSleepWhileCharging, version, decidedAt
    }

    /// Decoded by hand so that fields added later arrive as their defaults rather
    /// than as a parse failure.
    ///
    /// Not a theoretical courtesy: the daemon keeps running across an install, so
    /// a freshly built client routinely talks to the previous build. A client
    /// that cannot read an old report at all would report "daemon not responding"
    /// for something that is responding perfectly.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upperLimit = try container.decode(Int.self, forKey: .upperLimit)
        lowerLimit = try container.decode(Int.self, forKey: .lowerLimit)
        thermalCutoff = try container.decode(Double.self, forKey: .thermalCutoff)
        sleepPolicy = try container.decode(String.self, forKey: .sleepPolicy)
        gate = try container.decode(String.self, forKey: .gate)
        reason = try container.decode(String.self, forKey: .reason)
        gateIsTrusted = try container.decode(Bool.self, forKey: .gateIsTrusted)
        chargerReason = try container.decodeIfPresent(String.self, forKey: .chargerReason)
        decidedAt = try container.decode(Date.self, forKey: .decidedAt)

        // Added after the first release. A daemon that does not mention support
        // is one from before the question could be asked, and every machine this
        // ran on then had a gate — so `true` is the honest default, not optimism.
        limitingIsSupported = try container.decodeIfPresent(
            Bool.self, forKey: .limitingIsSupported
        ) ?? true
        preventIdleSleepWhileCharging = try container.decodeIfPresent(
            Bool.self, forKey: .preventIdleSleepWhileCharging
        ) ?? false
        reasonCode = try container.decodeIfPresent(String.self, forKey: .reasonCode) ?? "unknown"
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "unknown"
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var report: DaemonReport?
    /// Anything the daemon had to change about what was asked, such as a limit
    /// pulled back into range. Reported rather than applied silently.
    public var notes: [String]

    public init(
        ok: Bool, error: String? = nil, report: DaemonReport? = nil, notes: [String] = []
    ) {
        self.ok = ok
        self.error = error
        self.report = report
        self.notes = notes
    }

    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

public enum ControlProtocol {
    public static let defaultSocketPath = "/var/run/dranik.sock"
    /// A request larger than this is not one this protocol can produce.
    public static let maximumRequestBytes = 8 * 1024

    public static func encode(_ request: ControlRequest) throws -> Data {
        var data = try coder.encoder.encode(request)
        data.append(0x0A)
        return data
    }

    public static func encode(_ response: ControlResponse) throws -> Data {
        var data = try coder.encoder.encode(response)
        data.append(0x0A)
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> ControlRequest {
        try coder.decoder.decode(ControlRequest.self, from: data)
    }

    public static func decodeResponse(_ data: Data) throws -> ControlResponse {
        try coder.decoder.decode(ControlResponse.self, from: data)
    }

    private static let coder: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }()
}
