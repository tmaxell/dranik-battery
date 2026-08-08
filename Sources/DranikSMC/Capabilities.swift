import Foundation

/// A charge-control key together with the exact metadata it must report and the
/// payloads that open and close the charge gate.
///
/// The metadata is part of the identity check on purpose. Firmware has already
/// moved this functionality once — `CH0B`/`CH0C` are gone on MacBookPro17,1 and
/// `CHTE` took over — so a key that exists but no longer matches its expected
/// size, type and attributes is treated as unknown rather than written blindly.
public struct SMCKeySpec: Equatable, Sendable {
    public let key: SMCKey
    public let expectedInfo: SMCKeyInfo
    /// Payload that permits charging.
    public let onBytes: [UInt8]
    /// Payload that inhibits charging. Not written by this module — recorded here
    /// so the spec is complete and reviewable before anything writes it.
    public let offBytes: [UInt8]

    public init(key: SMCKey, expectedInfo: SMCKeyInfo, onBytes: [UInt8], offBytes: [UInt8]) {
        self.key = key
        self.expectedInfo = expectedInfo
        self.onBytes = onBytes
        self.offBytes = offBytes
    }

    public func matches(_ info: SMCKeyInfo) -> Bool {
        info == expectedInfo
    }
}

public extension SMCKeySpec {
    /// Apple Silicon firmware from roughly 2024 onwards. Present on
    /// MacBookPro17,1 / mBoot-18000.120.36 as `4 / ui32 / 0xD4`.
    ///
    /// Off-payload `01 00 00 00` is what both Battery-Toolkit and batt write.
    /// It has not yet been verified on this machine.
    static let chargeGateCHTE = SMCKeySpec(
        key: SMCKey("CHTE")!,
        expectedInfo: SMCKeyInfo(size: 4, type: "ui32", attributes: 0xD4),
        onBytes: [0x00, 0x00, 0x00, 0x00],
        offBytes: [0x01, 0x00, 0x00, 0x00]
    )

    /// Older Apple Silicon firmware. Absent on the target machine.
    ///
    /// Note the off-payload: batt and BatFi write `0x02`, Battery-Toolkit writes
    /// `0x01`. The value here follows the two-to-one majority, but the
    /// disagreement is real and unresolved — see docs/06-upstream-code-review.md §2.
    static let chargeGateCH0B = SMCKeySpec(
        key: SMCKey("CH0B")!,
        expectedInfo: SMCKeyInfo(size: 1, type: "ui8", attributes: 0xD4),
        onBytes: [0x00],
        offBytes: [0x02]
    )

    static let chargeGateCH0C = SMCKeySpec(
        key: SMCKey("CH0C")!,
        expectedInfo: SMCKeyInfo(size: 1, type: "ui8", attributes: 0xD4),
        onBytes: [0x00],
        offBytes: [0x02]
    )
}

/// Which mechanism, if any, this machine offers for gating charge.
public enum ChargeGate: Equatable, Sendable {
    /// One key controls the gate. `CHTE` on current firmware.
    case single(SMCKeySpec)
    /// Two keys must be written together. `CH0B` + `CH0C` on older firmware.
    case pair(SMCKeySpec, SMCKeySpec)
    /// No usable mechanism. Nothing may be written to the SMC.
    case unsupported

    public var isSupported: Bool {
        self != .unsupported
    }

    /// The keys that make up the gate. Writing the gate means writing all of
    /// them, in this order.
    public var specs: [SMCKeySpec] {
        switch self {
        case .single(let spec): return [spec]
        case .pair(let first, let second): return [first, second]
        case .unsupported: return []
        }
    }

    public var keys: [SMCKey] {
        specs.map(\.key)
    }
}

/// What this machine can do, determined by probing rather than by model.
public struct Capabilities: Equatable, Sendable {
    public let chargeGate: ChargeGate
    /// Firmware-enforced 80 % limit. Absent on MacBookPro17,1: the limit has to
    /// be held by a process, which is what drives the fail-safe requirements.
    public let hasHardwareChargeLimit: Bool
    /// Present, but never actuated in this phase.
    public let adapterControlKeys: [SMCKey]

    public init(chargeGate: ChargeGate, hasHardwareChargeLimit: Bool, adapterControlKeys: [SMCKey]) {
        self.chargeGate = chargeGate
        self.hasHardwareChargeLimit = hasHardwareChargeLimit
        self.adapterControlKeys = adapterControlKeys
    }

    /// Probes `connection` for charge-control capabilities.
    ///
    /// Order matters: the newer single-key mechanism is checked first, because a
    /// machine carrying both should use the one its firmware actually drives.
    public static func detect(using connection: SMCConnection) throws -> Capabilities {
        var chargeGate = ChargeGate.unsupported

        if try specMatches(.chargeGateCHTE, on: connection) {
            chargeGate = .single(.chargeGateCHTE)
        } else if try specMatches(.chargeGateCH0B, on: connection),
                  try specMatches(.chargeGateCH0C, on: connection) {
            chargeGate = .pair(.chargeGateCH0B, .chargeGateCH0C)
        }

        let hasHardwareChargeLimit = try connection.keyInfo(SMCKey("CHWA")!) != nil

        var adapterKeys: [SMCKey] = []
        for name in ["CH0I", "CH0J", "CHIE"] {
            let key = SMCKey(name)!
            if try connection.keyInfo(key) != nil {
                adapterKeys.append(key)
            }
        }

        return Capabilities(
            chargeGate: chargeGate,
            hasHardwareChargeLimit: hasHardwareChargeLimit,
            adapterControlKeys: adapterKeys
        )
    }

    private static func specMatches(_ spec: SMCKeySpec, on connection: SMCConnection) throws -> Bool {
        guard let info = try connection.keyInfo(spec.key) else { return false }
        return spec.matches(info)
    }
}
