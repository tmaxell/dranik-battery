import DranikSMC
import Foundation

/// The write path refuses far more often than it proceeds, and every refusal
/// happens *before* anything reaches the kernel. These check the refusals — the
/// one case that would actually write is covered by `dranik-gate-experiment`,
/// which needs root and changes machine state, so it is never run from here.
func runWriteGuardTests() {
    func connect() throws -> SMCConnection {
        do {
            return try SMCConnection()
        } catch {
            try skip("AppleSMC unavailable: \(error)")
        }
    }

    test("write refuses a key this machine does not have") {
        let smc = try connect()
        defer { smc.close() }

        // CH0B is genuinely absent here, which makes it a real case rather than
        // a synthetic one.
        do {
            try smc.write(
                SMCKey("CH0B")!,
                bytes: [0x00],
                matching: SMCKeyInfo(size: 1, type: "ui8", attributes: 0xD4)
            )
            expectTrue(false, "expected the write to be refused")
        } catch SMCError.keyAbsent {
            // Expected.
        } catch {
            expectTrue(false, "wrong error: \(error)")
        }
    }

    test("write refuses when the key's metadata has drifted") {
        let smc = try connect()
        defer { smc.close() }

        // CHTE exists and is writable, but claim the wrong size for it. A
        // firmware change that repurposes a key would look exactly like this,
        // and guessing past it could actuate something entirely different.
        do {
            try smc.write(
                SMCKey("CHTE")!,
                bytes: [0x00],
                matching: SMCKeyInfo(size: 1, type: "ui8", attributes: 0xD4)
            )
            expectTrue(false, "expected the write to be refused")
        } catch SMCError.metadataMismatch {
            // Expected — and note this refused before checking privileges.
        } catch {
            expectTrue(false, "wrong error: \(error)")
        }
    }

    test("write refuses a read-only key") {
        let smc = try connect()
        defer { smc.close() }

        // B0AV is telemetry: attributes 0x84, no write bit.
        let info = try expectNotNil((try? smc.keyInfo(SMCKey("B0AV")!)) ?? nil)
        expectFalse(info.isWritable, "B0AV should not be writable")

        do {
            try smc.write(SMCKey("B0AV")!, bytes: [0x00, 0x00], matching: info)
            expectTrue(false, "expected the write to be refused")
        } catch SMCError.notWritable {
            // Expected.
        } catch {
            expectTrue(false, "wrong error: \(error)")
        }
    }

    test("write refuses a payload of the wrong length") {
        let smc = try connect()
        defer { smc.close() }

        let info = try expectNotNil((try? smc.keyInfo(SMCKey("CHTE")!)) ?? nil)
        do {
            try smc.write(SMCKey("CHTE")!, bytes: [0x00, 0x00], matching: info)
            expectTrue(false, "expected the write to be refused")
        } catch SMCError.payloadSizeMismatch {
            // Expected.
        } catch {
            expectTrue(false, "wrong error: \(error)")
        }
    }

    test("an unprivileged write to a valid key fails on privileges, not silently") {
        let smc = try connect()
        defer { smc.close() }

        guard geteuid() != 0 else {
            try skip("running as root — this test asserts the unprivileged path")
        }

        let spec = SMCKeySpec.chargeGateCHTE
        let before = try expectNotNil((try? smc.read(spec.key)) ?? nil)

        // Writes the gate's *open* payload, which is what the key already holds
        // whenever charging is under system control — so even if privileges were
        // somehow granted, this could not close the gate.
        expectEqual(before.bytes, spec.onBytes, "precondition: gate should be open")

        do {
            try smc.write(spec.key, bytes: spec.onBytes, matching: spec.expectedInfo)
            expectTrue(false, "an unprivileged write should not succeed")
        } catch SMCError.ioKit {
            // Expected: kIOReturnNotPrivileged.
        } catch {
            expectTrue(false, "wrong error: \(error)")
        }

        let after = try expectNotNil((try? smc.read(spec.key)) ?? nil)
        expectEqual(after.bytes, before.bytes, "the refused write must not have changed anything")
    }

    test("gate exposes its specs in write order") {
        expectEqual(ChargeGate.single(.chargeGateCHTE).specs.count, 1)
        expectEqual(ChargeGate.pair(.chargeGateCH0B, .chargeGateCH0C).specs.count, 2)
        expectEqual(ChargeGate.unsupported.specs.count, 0)
        expectEqual(
            ChargeGate.pair(.chargeGateCH0B, .chargeGateCH0C).specs.map(\.key.description),
            ["CH0B", "CH0C"]
        )
    }
}
