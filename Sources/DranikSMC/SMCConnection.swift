import CDranikSMC
import Foundation
import IOKit
import os

/// Connection to `AppleSMC`.
///
/// Reads need no privileges. Writes need root, and `write(_:bytes:matching:)`
/// is the only way to perform one — it refuses unless the key's live metadata
/// matches the caller's expectation exactly, and it verifies the result by
/// reading the key back. See docs/04-safety.md.
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
            return try readLocked(key, info: info)
        }
    }

    /// Writes `bytes` to `key`, refusing unless the key still looks exactly as
    /// `expected` describes it, and confirming the result by reading it back.
    ///
    /// The metadata check is not ceremony. Firmware has already moved charge
    /// control once — `CH0B`/`CH0C` gave way to `CHTE` — so a key whose size,
    /// type or attributes have drifted is a key whose meaning may have drifted
    /// too, and writing to it blind could actuate something else entirely.
    ///
    /// The read-back is not ceremony either. Battery-Toolkit records observing
    /// SMC keys report values matching neither the previous nor the written
    /// value, so a successful IOKit call is not by itself evidence of anything.
    /// Note that a matching read-back still only proves the key holds the value;
    /// proving the machine acted on it needs `ChargerData` (see `DranikPower`).
    ///
    /// Requires root — otherwise this throws `SMCError.ioKit(kIOReturnNotPrivileged)`.
    public func write(_ key: SMCKey, bytes: [UInt8], matching expected: SMCKeyInfo) throws {
        try queue.sync {
            guard let live = try keyInfoLocked(key) else {
                throw SMCError.keyAbsent(key.description)
            }
            guard live == expected else {
                throw SMCError.metadataMismatch(key: key.description, expected: expected, found: live)
            }
            guard live.isWritable else {
                throw SMCError.notWritable(key.description)
            }
            guard bytes.count == Int(expected.size) else {
                throw SMCError.payloadSizeMismatch(
                    key: key.description, expected: expected.size, got: UInt32(bytes.count)
                )
            }

            let before = try readLocked(key, info: live)

            var input = DRSMCParamStruct()
            input.key = key.rawValue
            input.keyInfo.dataSize = expected.size
            input.data8 = UInt8(kDRSMCWriteKey)
            bytes.withUnsafeBufferPointer { buffer in
                dr_smc_param_set_bytes(&input, buffer.baseAddress, expected.size)
            }

            let hexBefore = Self.hex(before.bytes)
            let hexWanted = Self.hex(bytes)
            log.notice("""
            SMC write \(key.description, privacy: .public): \
            \(hexBefore, privacy: .public) -> \(hexWanted, privacy: .public)
            """)

            let output = try call(&input)
            guard output.result == UInt8(kDRSMCSuccess) else {
                throw SMCError.smc(output.result)
            }

            let after = try readLocked(key, info: live)
            guard after.bytes == bytes else {
                let hexAfter = Self.hex(after.bytes)
                log.fault("""
                SMC write \(key.description, privacy: .public) not applied: \
                reads \(hexAfter, privacy: .public), wanted \(hexWanted, privacy: .public)
                """)
                throw SMCError.writeNotApplied(key: key.description, wrote: bytes, read: after.bytes)
            }
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

    private func readLocked(_ key: SMCKey, info: SMCKeyInfo) throws -> SMCReading {
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

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

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
