import CDranikSMC
import Foundation

/// The parameter struct is a binary contract with AppleSMC.kext. If the compiler
/// ever lays it out differently, calls silently read and write the wrong fields,
/// so pin the size and every offset.
func runLayoutTests() {
    test("param struct is 80 bytes") {
        expectEqual(MemoryLayout<DRSMCParamStruct>.size, 80)
    }

    test("field offsets") {
        expectEqual(MemoryLayout<DRSMCParamStruct>.offset(of: \.key), 0)
        expectEqual(MemoryLayout<DRSMCParamStruct>.offset(of: \.vers), 4)
        expectEqual(MemoryLayout<DRSMCParamStruct>.offset(of: \.pLimitData), 12)
        expectEqual(MemoryLayout<DRSMCParamStruct>.offset(of: \.keyInfo), 28)
        expectEqual(MemoryLayout<DRSMCParamStruct>.offset(of: \.result), 40)
        expectEqual(MemoryLayout<DRSMCParamStruct>.offset(of: \.status), 41)
        expectEqual(MemoryLayout<DRSMCParamStruct>.offset(of: \.data8), 42)
        expectEqual(MemoryLayout<DRSMCParamStruct>.offset(of: \.data32), 44)
        expectEqual(MemoryLayout<DRSMCParamStruct>.offset(of: \.bytes), 48)
    }

    test("nested struct sizes") {
        expectEqual(MemoryLayout<DRSMCVersion>.size, 6)
        expectEqual(MemoryLayout<DRSMCPLimitData>.size, 16)
        expectEqual(MemoryLayout<DRSMCKeyInfoData>.size, 12)
    }

    test("command codes match Apple's header") {
        expectEqual(kDRSMCUserClientOpen, 0)
        expectEqual(kDRSMCUserClientClose, 1)
        expectEqual(kDRSMCHandleYPCEvent, 2)
        expectEqual(kDRSMCReadKey, 5)
        expectEqual(kDRSMCWriteKey, 6)
        expectEqual(kDRSMCGetKeyCount, 7)
        expectEqual(kDRSMCGetKeyFromIndex, 8)
        expectEqual(kDRSMCGetKeyInfo, 9)
        expectEqual(kDRSMCKeyNotFound, 0x84)
    }

    test("byte accessors round-trip") {
        var params = DRSMCParamStruct()
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        dr_smc_param_set_bytes(&params, payload, UInt32(payload.count))

        var readBack = [UInt8](repeating: 0, count: 4)
        withUnsafePointer(to: params) { dr_smc_param_get_bytes($0, &readBack, 4) }

        expectEqual(readBack, payload)
    }

    test("byte accessor clamps an oversized write") {
        var params = DRSMCParamStruct()
        let payload = [UInt8](repeating: 0xAA, count: 64)
        // Must not overflow the 32-byte field.
        dr_smc_param_set_bytes(&params, payload, UInt32(payload.count))

        var readBack = [UInt8](repeating: 0, count: 32)
        withUnsafePointer(to: params) { dr_smc_param_get_bytes($0, &readBack, 32) }

        expectEqual(readBack, [UInt8](repeating: 0xAA, count: 32))
    }
}
