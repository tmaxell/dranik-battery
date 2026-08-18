import DranikSMC
import Foundation

/// What the reboot test leaves behind so the two halves — before the reboot and
/// after it — can talk to each other.
struct PersistenceRecord: Codable {
    var key: String
    var closedPayload: String
    var openPayload: String
    var armedAt: Date
    var observation: Observation?

    struct Observation: Codable {
        var observedAt: Date
        var payload: String
        var survived: Bool
        var restoreSucceeded: Bool
        var notChargingReason: String?
    }

    static let path = "/var/db/dranik-persistence.json"

    static func load() -> PersistenceRecord? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistenceRecord.self, from: data)
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)

        // Write via a temporary file so a crash mid-write cannot leave a record
        // that parses as something other than what happened.
        let temporary = Self.path + ".tmp"
        try data.write(to: URL(fileURLWithPath: temporary))
        _ = try? FileManager.default.replaceItemAt(
            URL(fileURLWithPath: Self.path),
            withItemAt: URL(fileURLWithPath: temporary)
        )
        if FileManager.default.fileExists(atPath: temporary) {
            try? FileManager.default.moveItem(atPath: temporary, toPath: Self.path)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Self.path
        )
    }

    static func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.hexString }

func stamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func note(_ message: String) {
    print("[\(stamp())] \(message)")
    fflush(stdout)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dranik-persistence: \(message)\n".utf8))
    exit(1)
}
