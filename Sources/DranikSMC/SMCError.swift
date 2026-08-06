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
        }
    }

    private static func format(_ code: kern_return_t) -> String {
        let hex = String(format: "0x%08x", UInt32(bitPattern: code))
        // Writes require root; reads do not. Confirmed on the target machine by
        // writing a key's own value back to it as an unprivileged user.
        return code == kIOReturnNotPrivileged ? "\(hex) (not privileged — root required)" : hex
    }
}
