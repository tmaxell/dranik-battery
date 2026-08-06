import Foundation

/// A four-character SMC key such as `CHTE` or `B0AV`.
public struct SMCKey: Hashable, CustomStringConvertible, Sendable {
    public let rawValue: UInt32

    /// Fails unless `string` is exactly four printable ASCII characters.
    public init?(_ string: String) {
        let scalars = Array(string.unicodeScalars)
        guard scalars.count == 4 else { return nil }
        var value: UInt32 = 0
        for scalar in scalars {
            guard scalar.value >= 0x20, scalar.value <= 0x7E else { return nil }
            value = (value << 8) | scalar.value
        }
        rawValue = value
    }

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public var description: String {
        var characters = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((rawValue >> UInt32(shift)) & 0xFF)
            characters.append(byte >= 0x20 && byte <= 0x7E ? Character(UnicodeScalar(byte)) : "?")
        }
        return characters
    }
}

/// Result of `kSMCGetKeyInfo` for one key.
public struct SMCKeyInfo: Equatable, Sendable {
    /// Payload size in bytes, 0...32.
    public let size: UInt32
    /// Type code with trailing padding stripped: `ui8`, `ui32`, `flt`, `hex_`, ...
    public let type: String
    /// Attribute bitmask. Bit `0x40` marks a writable key on Apple Silicon.
    public let attributes: UInt8

    public init(size: UInt32, type: String, attributes: UInt8) {
        self.size = size
        self.type = type
        self.attributes = attributes
    }

    /// Set on every writable key in a full dump of 1634 keys (MacBookPro17,1,
    /// macOS 14.8.7). A hint, not a guarantee — see `SMCKeySpec.matches`.
    public static let writableAttributeBit: UInt8 = 0x40

    public var isWritable: Bool {
        attributes & Self.writableAttributeBit != 0
    }
}

/// A key read together with its payload.
public struct SMCReading: Equatable, Sendable {
    public let key: SMCKey
    public let info: SMCKeyInfo
    public let bytes: [UInt8]

    public init(key: SMCKey, info: SMCKeyInfo, bytes: [UInt8]) {
        self.key = key
        self.info = info
        self.bytes = bytes
    }

    /// Payload decoded according to `info.type`.
    public var value: SMCValue {
        SMCValue(type: info.type, bytes: bytes)
    }
}
