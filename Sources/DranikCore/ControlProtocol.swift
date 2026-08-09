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
    public var decidedAt: Date

    public init(
        upperLimit: Int,
        lowerLimit: Int,
        thermalCutoff: Double,
        sleepPolicy: String,
        gate: String,
        reason: String,
        gateIsTrusted: Bool,
        decidedAt: Date
    ) {
        self.upperLimit = upperLimit
        self.lowerLimit = lowerLimit
        self.thermalCutoff = thermalCutoff
        self.sleepPolicy = sleepPolicy
        self.gate = gate
        self.reason = reason
        self.gateIsTrusted = gateIsTrusted
        self.decidedAt = decidedAt
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
