import Foundation

/// The four-byte type code the SMC reports for a key.
public enum SMCTypeCode {
    /// Decodes a type code, dropping the space or NUL padding shorter codes
    /// carry (`"ui8 "`, `"flt "`).
    public static func decode(_ raw: UInt32) -> String {
        var characters = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((raw >> UInt32(shift)) & 0xFF)
            guard byte >= 0x20, byte <= 0x7E else { continue }
            characters.append(Character(UnicodeScalar(byte)))
        }
        return characters.trimmingCharacters(in: .whitespaces)
    }
}

/// A decoded SMC payload.
///
/// Multi-byte values are decoded **little-endian**. SMC libraries written for
/// Intel Macs assume big-endian; on Apple Silicon that is wrong. Verified against
/// `AppleSmartBattery` on MacBookPro17,1 / macOS 14.8.7 — for example `B0AV` reads
/// `62 32`, which is 12898 mV little-endian against IOKit's `Voltage = 12897`,
/// and 25138 big-endian. See docs/02-hardware-probe.md §5.
public enum SMCValue: Equatable, CustomStringConvertible, Sendable {
    case unsigned(UInt64)
    case signed(Int64)
    case floating(Double)
    case flag(Bool)
    /// Payload whose type is opaque (`hex_`, `ch8*`) or whose size does not
    /// match its type code.
    case raw([UInt8])

    public init(type: String, bytes: [UInt8]) {
        switch (type, bytes.count) {
        case ("ui8", 1), ("ui16", 2), ("ui32", 4), ("ui64", 8):
            self = .unsigned(Self.unsignedLittleEndian(bytes))
        case ("si8", 1):
            self = .signed(Int64(Int8(bitPattern: bytes[0])))
        case ("si16", 2):
            self = .signed(Int64(Int16(bitPattern: UInt16(Self.unsignedLittleEndian(bytes)))))
        case ("si32", 4):
            self = .signed(Int64(Int32(bitPattern: UInt32(Self.unsignedLittleEndian(bytes)))))
        case ("si64", 8):
            self = .signed(Int64(bitPattern: Self.unsignedLittleEndian(bytes)))
        case ("flt", 4):
            self = .floating(Double(Float(bitPattern: UInt32(Self.unsignedLittleEndian(bytes)))))
        case ("flag", 1):
            self = .flag(bytes[0] != 0)
        default:
            self = .raw(bytes)
        }
    }

    private static func unsignedLittleEndian(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt64(byte) << UInt64(index * 8)
        }
        return value
    }

    public var description: String {
        switch self {
        case .unsigned(let value): return String(value)
        case .signed(let value): return String(value)
        case .floating(let value): return String(format: "%.3f", value)
        case .flag(let value): return value ? "true" : "false"
        case .raw(let bytes): return bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Numeric view of the value, for the cases where a caller does not care
    /// whether the key is typed as integer or float. `nil` for `.raw`.
    public var doubleValue: Double? {
        switch self {
        case .unsigned(let value): return Double(value)
        case .signed(let value): return Double(value)
        case .floating(let value): return value
        case .flag(let value): return value ? 1 : 0
        case .raw: return nil
        }
    }
}
