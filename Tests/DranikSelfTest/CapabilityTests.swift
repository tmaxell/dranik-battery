import DranikSMC
import Foundation

/// Key-spec expectations that hold without touching hardware.
func runKeySpecTests() {
    test("CHTE spec matches the metadata probed on the target machine") {
        // MacBookPro17,1 / mBoot-18000.120.36 reports 4 / ui32 / 0xd4.
        let observed = SMCKeyInfo(size: 4, type: "ui32", attributes: 0xD4)
        expectTrue(SMCKeySpec.chargeGateCHTE.matches(observed))
    }

    test("spec rejects a partial match") {
        let spec = SMCKeySpec.chargeGateCHTE
        // Firmware moved this functionality once already; a key that exists but no
        // longer matches must be treated as unknown, not written blindly.
        expectFalse(spec.matches(SMCKeyInfo(size: 1, type: "ui32", attributes: 0xD4)))
        expectFalse(spec.matches(SMCKeyInfo(size: 4, type: "ui8", attributes: 0xD4)))
        expectFalse(spec.matches(SMCKeyInfo(size: 4, type: "ui32", attributes: 0x84)))
    }

    test("gate specs declare distinct, correctly sized payloads") {
        for spec in [SMCKeySpec.chargeGateCHTE, .chargeGateCH0B, .chargeGateCH0C] {
            expectNotEqual(spec.onBytes, spec.offBytes, "\(spec.key)")
            expectEqual(UInt32(spec.onBytes.count), spec.expectedInfo.size, "\(spec.key) on")
            expectEqual(UInt32(spec.offBytes.count), spec.expectedInfo.size, "\(spec.key) off")
        }
    }

    test("charge gate reports its keys") {
        expectEqual(ChargeGate.single(.chargeGateCHTE).keys.map(\.description), ["CHTE"])
        expectEqual(
            ChargeGate.pair(.chargeGateCH0B, .chargeGateCH0C).keys.map(\.description),
            ["CH0B", "CH0C"]
        )
        expectEqual(ChargeGate.unsupported.keys, [])
        expectFalse(ChargeGate.unsupported.isSupported)
        expectTrue(ChargeGate.single(.chargeGateCHTE).isSupported)
    }
}

/// Tests that talk to the real SMC. Skipped where `AppleSMC` is unavailable.
func runLiveSMCTests() {
    func connect() throws -> SMCConnection {
        do {
            return try SMCConnection()
        } catch {
            try skip("AppleSMC unavailable: \(error)")
        }
    }

    test("a charge gate is detected") {
        let smc = try connect()
        defer { smc.close() }

        let capabilities = try Capabilities.detect(using: smc)
        expectTrue(
            capabilities.chargeGate.isSupported,
            "no charge-control key matched its expected metadata on this machine"
        )
    }

    test("gate keys are readable and carry the writable attribute") {
        let smc = try connect()
        defer { smc.close() }

        let capabilities = try Capabilities.detect(using: smc)
        for key in capabilities.chargeGate.keys {
            let reading = try expectNotNil(try smc.read(key), "\(key)")
            expectTrue(reading.info.isWritable, "\(key)")
            expectEqual(reading.bytes.count, Int(reading.info.size), "\(key)")
        }
    }

    test("a missing key returns nil rather than throwing") {
        let smc = try connect()
        defer { smc.close() }

        // Deliberately nonsensical; the SMC answers kSMCKeyNotFound.
        expectNil(try smc.keyInfo(SMCKey("ZZZZ")!))
        expectNil(try smc.read(SMCKey("ZZZZ")!))
    }

    test("key enumeration is consistent") {
        let smc = try connect()
        defer { smc.close() }

        let count = try smc.keyCount()
        expectInRange(count, 100...10_000, "implausible key count")

        let first = try smc.key(at: 0)
        expectEqual(first.description.count, 4)
        expectEqual(SMCKey(first.description)?.rawValue, first.rawValue)
    }

    test("BUIC agrees with the percentage IOKit reports") {
        let smc = try connect()
        defer { smc.close() }

        // If the little-endian decoding were wrong this would be wildly off
        // rather than within a point.
        let reading = try expectNotNil(try smc.read(SMCKey("BUIC")!))
        let percentage = try expectNotNil(reading.value.doubleValue)
        expectInRange(percentage, 0...100)
    }
}
