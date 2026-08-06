import CDranikSMC
import Foundation
import IOKit
import os

/// Read-only connection to `AppleSMC`.
///
/// This type deliberately exposes **no write operation**. Writing to the SMC is
/// the one action in this project that can leave the machine in a state where it
/// refuses to charge, so it arrives in its own change together with the fail-safe
/// machinery that must surround it (see docs/04-safety.md).
///
/// Reads do not require root; writes do.
///
/// All IOKit traffic is serialised onto one queue: the SMC user client is not
/// safe to call concurrently.
public final class SMCConnection {
    private let queue = DispatchQueue(label: "com.dranik.battery.smc")
    private let log = Logger(subsystem: "com.dranik.battery", category: "SMC")
    private var connection: io_connect_t = IO_OBJECT_NULL

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else {
            throw SMCError.serviceNotFound
        }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw SMCError.cannotOpen(result)
        }
        self.connection = connection

        // The documented handshake. Reads work without it, but the kext expects
        // it and Battery-Toolkit issues it, so do the same. Failure is not fatal.
        let open = IOConnectCallMethod(
            connection, UInt32(kDRSMCUserClientOpen),
            nil, 0, nil, 0, nil, nil, nil, nil
        )
        if open != kIOReturnSuccess {
            let code = String(format: "0x%08x", UInt32(bitPattern: open))
            log.debug("kSMCUserClientOpen returned \(code, privacy: .public), continuing")
        }
    }

    deinit {
        close()
    }

    public func close() {
        queue.sync {
            guard connection != IO_OBJECT_NULL else { return }
            _ = IOConnectCallMethod(
                connection, UInt32(kDRSMCUserClientClose),
                nil, 0, nil, 0, nil, nil, nil, nil
            )
            IOServiceClose(connection)
            connection = IO_OBJECT_NULL
        }
    }

    // MARK: - Key access

    /// Metadata for `key`, or `nil` if the SMC does not know the key.
    ///
    /// A missing key is not an error: the IOKit call succeeds and the SMC reports
    /// `result == kSMCKeyNotFound (0x84)`. This is the supported way to ask
    /// whether a key exists — `CH0B` and `CHWA` are absent on MacBookPro17,1.
    public func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo? {
        try queue.sync { try keyInfoLocked(key) }
    }

    /// Reads `key`, or returns `nil` if the SMC does not know it.
    public func read(_ key: SMCKey) throws -> SMCReading? {
        try queue.sync {
            guard let info = try keyInfoLocked(key) else { return nil }
            guard info.size <= UInt32(DRSMC_MAX_DATA_SIZE) else {
                throw SMCError.oversizedPayload(info.size)
            }

            var input = DRSMCParamStruct()
            input.key = key.rawValue
            input.keyInfo.dataSize = info.size
            input.data8 = UInt8(kDRSMCReadKey)

            let output = try call(&input)
            guard output.result == UInt8(kDRSMCSuccess) else {
                throw SMCError.smc(output.result)
            }

            var bytes = [UInt8](repeating: 0, count: Int(info.size))
            withUnsafePointer(to: output) { pointer in
                dr_smc_param_get_bytes(pointer, &bytes, info.size)
            }
            return SMCReading(key: key, info: info, bytes: bytes)
        }
    }

    /// Number of keys the SMC exposes, via the `#KEY` pseudo-key.
    ///
    /// `#KEY` is typed `ui32` but, unlike ordinary keys on this platform, its
    /// payload is big-endian — 1634 keys read as `00 00 06 62`. Decoded here
    /// explicitly rather than through `SMCValue`.
    public func keyCount() throws -> UInt32 {
        guard let reading = try read(SMCKey("#KEY")!), reading.bytes.count == 4 else {
            throw SMCError.serviceNotFound
        }
        return reading.bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// The key at `index` in the SMC's internal table, for enumeration.
    public func key(at index: UInt32) throws -> SMCKey {
        try queue.sync {
            var input = DRSMCParamStruct()
            input.data8 = UInt8(kDRSMCGetKeyFromIndex)
            input.data32 = index

            let output = try call(&input)
            guard output.result == UInt8(kDRSMCSuccess) else {
                throw SMCError.smc(output.result)
            }
            return SMCKey(rawValue: output.key)
        }
    }

    // MARK: - Private

    private func keyInfoLocked(_ key: SMCKey) throws -> SMCKeyInfo? {
        var input = DRSMCParamStruct()
        input.key = key.rawValue
        input.data8 = UInt8(kDRSMCGetKeyInfo)

        let output = try call(&input)
        if output.result == UInt8(kDRSMCKeyNotFound) {
            return nil
        }
        guard output.result == UInt8(kDRSMCSuccess) else {
            throw SMCError.smc(output.result)
        }
        return SMCKeyInfo(
            size: output.keyInfo.dataSize,
            type: SMCTypeCode.decode(output.keyInfo.dataType),
            attributes: output.keyInfo.dataAttributes
        )
    }

    private func call(_ input: inout DRSMCParamStruct) throws -> DRSMCParamStruct {
        guard connection != IO_OBJECT_NULL else {
            throw SMCError.notConnected
        }

        var output = DRSMCParamStruct()
        var outputSize = MemoryLayout<DRSMCParamStruct>.size

        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    UInt32(kDRSMCHandleYPCEvent),
                    inputPointer,
                    MemoryLayout<DRSMCParamStruct>.size,
                    outputPointer,
                    &outputSize
                )
            }
        }
        guard result == kIOReturnSuccess else {
            throw SMCError.ioKit(result)
        }
        return output
    }
}
