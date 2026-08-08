import Foundation
import IOKit

public enum SMCError: Error, CustomStringConvertible {
    /// `AppleSMC` service not present in the IO registry.
    case serviceNotFound
    /// `IOServiceOpen` failed.
    case cannotOpen(kern_return_t)
    /// The IOKit call itself failed.
    case ioKit(kern_return_t)
    /// The call succeeded but the SMC reported a non-zero `result`.
    case smc(UInt8)
    /// Key string was not exactly four printable ASCII characters.
    case malformedKey(String)
    /// The SMC reported a payload larger than the 32-byte struct field.
    case oversizedPayload(UInt32)
    /// Operation attempted on a closed connection.
    case notConnected
    /// A write targeted a key this machine's SMC does not have.
    case keyAbsent(String)
    /// The key exists but no longer looks the way the caller expects, so its
    /// meaning may have changed with the firmware. Refused rather than guessed.
    case metadataMismatch(key: String, expected: SMCKeyInfo, found: SMCKeyInfo)
    /// The key does not carry the writable attribute.
    case notWritable(String)
    /// Payload length does not match the key's declared size.
    case payloadSizeMismatch(key: String, expected: UInt32, got: UInt32)
    /// The write reported success but the key reads back as something else.
    case writeNotApplied(key: String, wrote: [UInt8], read: [UInt8])

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found"
        case .cannotOpen(let code):
            return "IOServiceOpen failed: \(Self.format(code))"
        case .ioKit(let code):
            return "IOKit call failed: \(Self.format(code))"
        case .smc(let result):
            return "SMC returned result \(result) (0x\(String(result, radix: 16)))"
        case .malformedKey(let key):
            return "malformed SMC key '\(key)': expected four printable ASCII characters"
        case .oversizedPayload(let size):
            return "SMC reported payload of \(size) bytes, maximum is 32"
        case .notConnected:
            return "SMC connection is closed"
        case .keyAbsent(let key):
            return "SMC key '\(key)' is not present on this machine"
        case .metadataMismatch(let key, let expected, let found):
            return """
            SMC key '\(key)' does not match its expected description — \
            expected size \(expected.size)/\(expected.type)/\
            \(String(format: "0x%02x", expected.attributes)), \
            found size \(found.size)/\(found.type)/\
            \(String(format: "0x%02x", found.attributes)). Refusing to write.
            """
        case .notWritable(let key):
            return "SMC key '\(key)' is not writable"
        case .payloadSizeMismatch(let key, let expected, let got):
            return "SMC key '\(key)' takes \(expected) bytes, got \(got)"
        case .writeNotApplied(let key, let wrote, let read):
            return """
            SMC key '\(key)' reported a successful write but reads back \
            \(hex(read)) instead of \(hex(wrote))
            """
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func format(_ code: kern_return_t) -> String {
        let hex = String(format: "0x%08x", UInt32(bitPattern: code))
        // Writes require root; reads do not. Confirmed on the target machine by
        // writing a key's own value back to it as an unprivileged user.
        return code == kIOReturnNotPrivileged ? "\(hex) (not privileged — root required)" : hex
    }
}
