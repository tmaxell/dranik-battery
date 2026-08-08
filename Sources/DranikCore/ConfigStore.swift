import Foundation

/// `ChargeConfig` decodes through its validating initialiser, so a limit that
/// arrives from a file is bounded exactly like one that arrives from an
/// argument. There is no path into the type that skips the checks.
extension ChargeConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case upperLimit, lowerLimit, thermalCutoff
        case sleepPolicy, preventIdleSleepWhileCharging
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every field is optional on the way in: a config missing a key should
        // pick up the default for it, not fail to load and leave the daemon
        // with no configuration at all.
        self.init(
            upperLimit: try container.decodeIfPresent(Int.self, forKey: .upperLimit)
                ?? Self.defaultUpper,
            lowerLimit: try container.decodeIfPresent(Int.self, forKey: .lowerLimit),
            thermalCutoff: try container.decodeIfPresent(Double.self, forKey: .thermalCutoff)
                ?? Self.defaultThermalCutoff,
            sleepPolicy: try container.decodeIfPresent(SleepPolicy.self, forKey: .sleepPolicy)
                ?? .holdLimit,
            preventIdleSleepWhileCharging: try container.decodeIfPresent(
                Bool.self, forKey: .preventIdleSleepWhileCharging
            ) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(upperLimit, forKey: .upperLimit)
        try container.encode(lowerLimit, forKey: .lowerLimit)
        try container.encode(thermalCutoff, forKey: .thermalCutoff)
        try container.encode(sleepPolicy, forKey: .sleepPolicy)
        try container.encode(preventIdleSleepWhileCharging, forKey: .preventIdleSleepWhileCharging)
        // `corrections` is deliberately not written: it describes this load, not
        // the configuration, and persisting it would make it look like a setting.
    }
}

/// Reads and writes the configuration file.
///
/// Loading never fails. A daemon that refuses to start because its configuration
/// is malformed is worse than one that starts with defaults, because the machine
/// it did not start on may have a charge gate that is still shut — and nothing
/// will reopen it until the daemon runs.
public enum ConfigStore {
    public static let defaultPath = "/Library/Application Support/dranik/config.json"

    public struct Result: Equatable {
        public let config: ChargeConfig
        /// Everything that had to be worked around: a missing file, unparseable
        /// contents, values pulled back into range. Empty when the file was
        /// exactly what it claimed to be.
        public let problems: [String]
    }

    public static func load(from path: String = defaultPath) -> Result {
        guard let data = FileManager.default.contents(atPath: path) else {
            return Result(
                config: ChargeConfig(),
                problems: ["no configuration at \(path) — using defaults"]
            )
        }

        do {
            let config = try JSONDecoder().decode(ChargeConfig.self, from: data)
            return Result(config: config, problems: config.corrections)
        } catch {
            return Result(
                config: ChargeConfig(),
                problems: ["\(path) could not be read (\(error)) — using defaults"]
            )
        }
    }

    /// Writes atomically: a crash mid-write leaves the previous file intact
    /// rather than a truncated one that would load as defaults next time.
    public static func save(_ config: ChargeConfig, to path: String = defaultPath) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// What the daemon leaves on disk so its successor knows what it was in the
/// middle of.
///
/// Not a source of truth — the SMC is, and reconciliation reads it directly.
/// This exists for the case where the SMC cannot be read, and for working out
/// afterwards what a daemon was doing when it stopped.
public struct DaemonState: Codable, Equatable, Sendable {
    public var gateIsClosed: Bool
    public var updatedAt: Date
    public var reason: String

    public init(gateIsClosed: Bool, updatedAt: Date = Date(), reason: String) {
        self.gateIsClosed = gateIsClosed
        self.updatedAt = updatedAt
        self.reason = reason
    }
}

public enum StateStore {
    public static let defaultPath = "/Library/Application Support/dranik/state.json"

    public static func load(from path: String = defaultPath) -> DaemonState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DaemonState.self, from: data)
    }

    public static func save(_ state: DaemonState, to path: String = defaultPath) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: URL(fileURLWithPath: path), options: .atomic)

        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path
        )
    }

    public static func remove(at path: String = defaultPath) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
