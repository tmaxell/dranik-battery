import Foundation
import CDranikNative

/// Native PowerUI observations, not a claim that hardware is currently enforcing
/// the requested target. Apple's full-charge override can intentionally bypass it.
public struct NativeChargeSnapshot: Codable, Equatable, Sendable {
    public let supported: Bool
    /// Zero when unsupported; otherwise the target reported by PowerUI.
    public let limit: Int
    public let enabled: Bool
    public let availableLimits: [Int]
    public let fullChargeOverride: Bool

    public init(supported: Bool, limit: Int, enabled: Bool, availableLimits: [Int], fullChargeOverride: Bool) {
        self.supported = supported
        self.limit = limit
        self.enabled = enabled
        self.availableLimits = availableLimits
        self.fullChargeOverride = fullChargeOverride
    }
}

public struct NativeChargeError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) { self.message = message }
}

/// Thin, independently authored synchronous bridge; no orchestration or storage.
///
/// Initialization is inert. Run each operation in a disposable helper process
/// with a parent-enforced timeout: PowerUI's private synchronous IPC cannot be
/// safely cancelled in-process. Do not call from the UI thread. The parent must
/// persist the original effective (enabled, target) policy before any mutation,
/// serialize operations, verify readback, and restore policy on uninstall.
/// Errors after mutation can represent partial success; do not assume rollback.
public struct NativeChargeClient: Sendable {
    public init() {}

    public func snapshot() throws -> NativeChargeSnapshot {
        var json: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let success = dn_native_snapshot(&json, &error)
        defer {
            dn_native_free(json)
            dn_native_free(error)
        }
        guard success == 1, let json else {
            throw bridgeError(error, fallback: "Native snapshot failed without a diagnostic")
        }
        let data = Data(String(cString: json).utf8)
        do {
            return try JSONDecoder().decode(NativeChargeSnapshot.self, from: data)
        } catch {
            throw NativeChargeError("Invalid native snapshot: \(error)")
        }
    }

    /// Root only. Advertised slider values use PowerUI; other targets in 50...99
    /// use macOS 27 root preferences. 100 disables the limit. Acceptance is not proof
    /// of enforcement; verification and override handling belong to the caller.
    public func requestLimit(_ limit: Int) throws {
        guard (50...100).contains(limit) else {
            throw NativeChargeError("Native limit must be an integer in 50...100")
        }
        var error: UnsafeMutablePointer<CChar>?
        let success = dn_native_request_limit(Int32(limit), &error)
        defer { dn_native_free(error) }
        guard success == 1 else {
            throw bridgeError(error, fallback: "Native limit request failed without a diagnostic")
        }
    }

    public func disableNativeLimit() throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = dn_native_disable_limit(&error)
        defer { dn_native_free(error) }
        guard success == 1 else {
            throw bridgeError(error, fallback: "Native disable failed without a diagnostic")
        }
    }

    private func bridgeError(_ pointer: UnsafeMutablePointer<CChar>?, fallback: String) -> NativeChargeError {
        NativeChargeError(pointer.map { String(cString: $0) } ?? fallback)
    }
}
