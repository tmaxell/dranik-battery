import Foundation

/// The charger's own account of why it is not charging, from
/// `AppleSmartBattery` → `ChargerData` → `NotChargingReason`.
///
/// It is a 64-bit mask, not an enumeration. Only the bits observed directly on
/// the target machine are named here; anything else is reported as raw bits
/// rather than guessed at.
///
/// This matters more than it looks. It is the hardware's answer to "did the
/// charge gate actually take effect", independent of anything the SMC reports
/// about its own keys — and `.inhibited` distinguishes "the gate is holding"
/// from "not charging for some entirely different reason", which a plain
/// non-zero test cannot do.
public struct NotChargingReason: Equatable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ value: Int) {
        self.rawValue = UInt64(bitPattern: Int64(value))
    }

    /// Bit 7. Observed whenever the machine runs on battery — there is simply
    /// no charger attached. Present regardless of anything this project does.
    public static let onBattery = NotChargingReason(rawValue: 1 << 7)

    /// Bit 55. Observed on MacBookPro17,1 / macOS 14.8.7 for exactly as long as
    /// `CHTE` held the off-payload, and gone once it was restored. This is the
    /// signal that the software charge gate is what is holding charging back.
    public static let inhibited = NotChargingReason(rawValue: 1 << 55)

    public static let none = NotChargingReason(rawValue: 0)

    public var isEmpty: Bool { rawValue == 0 }

    public func contains(_ other: NotChargingReason) -> Bool {
        rawValue & other.rawValue == other.rawValue
    }

    /// Bits set here that this project has never seen and cannot name.
    public var unrecognisedBits: UInt64 {
        rawValue & ~(Self.onBattery.rawValue | Self.inhibited.rawValue)
    }

    public var description: String {
        if isEmpty { return "none" }

        var parts: [String] = []
        if contains(.onBattery) { parts.append("onBattery") }
        if contains(.inhibited) { parts.append("inhibited") }

        let leftover = unrecognisedBits
        if leftover != 0 {
            let bits = (0..<64).filter { leftover >> UInt64($0) & 1 == 1 }
            parts.append("unknown(bits \(bits.map(String.init).joined(separator: ",")))")
        }
        return parts.joined(separator: "+")
    }
}
