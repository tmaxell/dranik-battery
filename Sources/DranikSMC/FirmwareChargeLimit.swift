import Foundation

/// The keys of a charge corridor the firmware enforces by itself.
///
/// Three keys rather than one, and not interchangeable: `activation` switches the
/// mechanism on, `upper` and `lower` carry the corridor as whole percentages. The
/// write order is fixed by the firmware — deactivate, bounds, activate — because
/// a corridor must not be live while half-written.
///
/// Semantics are from `charlie0129/batt` (`pkg/smc/charging.go`) and were
/// verified on this hardware before any of this existed: see
/// `tools/FirmwareLimitExperiment` and the measurements in the change folder.
public struct FirmwareLimitSpec: Equatable, Sendable {
    public let activation: SMCKey
    public let activationInfo: SMCKeyInfo
    public let upper: SMCKey
    public let upperInfo: SMCKeyInfo
    public let lower: SMCKey
    public let lowerInfo: SMCKeyInfo

    /// Written to `activation` to hand the corridor to the firmware.
    public static let activeByte: UInt8 = 0x02
    /// Written to `activation` to take it back. Charging is then unrestricted,
    /// which is why this is also what uninstalling must leave behind.
    public static let inactiveByte: UInt8 = 0x00

    public init(
        activation: SMCKey,
        activationInfo: SMCKeyInfo,
        upper: SMCKey,
        upperInfo: SMCKeyInfo,
        lower: SMCKey,
        lowerInfo: SMCKeyInfo
    ) {
        self.activation = activation
        self.activationInfo = activationInfo
        self.upper = upper
        self.upperInfo = upperInfo
        self.lower = lower
        self.lowerInfo = lowerInfo
    }

    /// Present on MacBookPro17,1 from firmware mBoot-20457.1.29, which is the
    /// same update that took `CHTE` away. Apple shipped it across every
    /// supported train at once, so this is the mechanism going forward rather
    /// than a quirk of one machine.
    public static let bf0 = FirmwareLimitSpec(
        activation: SMCKey("bfF0")!,
        activationInfo: SMCKeyInfo(size: 1, type: "ui8", attributes: 0xD4),
        upper: SMCKey("bfD0")!,
        upperInfo: SMCKeyInfo(size: 4, type: "ui32", attributes: 0xD4),
        lower: SMCKey("bfE0")!,
        lowerInfo: SMCKeyInfo(size: 4, type: "ui32", attributes: 0xD4)
    )

    /// A percentage as the firmware wants it: `ui32`, little-endian, which is
    /// what raw SMC bytes are on Apple Silicon. `batt` reverses its bytes only
    /// because its own codec is big-endian; there is nothing here to reverse.
    public static func percentBytes(_ value: Int) -> [UInt8] {
        let v = UInt32(max(0, min(100, value)))
        return [
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ]
    }

    public static func percent(from bytes: [UInt8]) -> Int {
        var value: UInt32 = 0
        for (index, byte) in bytes.prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * index)
        }
        return Int(value)
    }

    public var keys: [SMCKey] { [activation, upper, lower] }
}

/// Whether this machine can hand the corridor to its firmware.
public enum FirmwareChargeLimit: Equatable, Sendable {
    case supported(FirmwareLimitSpec)
    case unsupported

    public var isSupported: Bool { self != .unsupported }

    public var spec: FirmwareLimitSpec? {
        switch self {
        case .supported(let spec): return spec
        case .unsupported: return nil
        }
    }

    public var keys: [SMCKey] { spec?.keys ?? [] }
}
