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

    /// A charge-control key this machine has that is present *and* writable.
    ///
    /// Two of the cases below need one, and one of them reaches the kernel. Which
    /// mechanism it comes from does not matter to the guard under test, and
    /// taking either is what keeps these covered: when the gate went away on
    /// 2026-10-12 they skipped for months, and a guard nothing exercises is a
    /// guard nobody would notice breaking.
    func writableChargeKey(_ smc: SMCConnection) throws -> (key: SMCKey, info: SMCKeyInfo) {
        let capabilities = try Capabilities.detect(using: smc)
        if let spec = capabilities.chargeGate.specs.first {
            return (spec.key, spec.expectedInfo)
        }
        if let spec = capabilities.firmwareLimit.spec {
            return (spec.activation, spec.activationInfo)
        }
        try skip("nothing writable on this machine to exercise the guard on")
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

        // Claim the wrong size for a key that certainly exists. B0AV rather
        // than the gate, deliberately: metadata is checked before writability,
        // so this case needs only presence — and tying it to the gate is what
        // made it fail the day the gate went away. A firmware change that
        // repurposes a key looks exactly like this, and guessing past it could
        // actuate something entirely different.
        do {
            try smc.write(
                SMCKey("B0AV")!,
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

        // Needs a key that is present and writable: the length check sits after
        // the writability check, so a read-only key would throw the wrong error.
        let target = try writableChargeKey(smc)
        let info = try expectNotNil((try? smc.keyInfo(target.key)) ?? nil)
        do {
            // Five bytes, which is the wrong length for every charge-control key
            // on any of these mechanisms.
            try smc.write(target.key, bytes: [0x00, 0x00, 0x00, 0x00, 0x00], matching: info)
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

        let target = try writableChargeKey(smc)
        let before = try expectNotNil((try? smc.read(target.key)) ?? nil)

        // Writes back exactly what the key already holds. That cannot change
        // anything whatever it is currently set to, even if privileges were
        // somehow granted — which matters because the daemon may well be running
        // and enforcing a limit while this suite runs. An earlier version wrote
        // the gate's open payload and assumed it was already there; with a limit
        // actually being enforced, that assumption was false and the write would
        // have lifted the limit.
        do {
            try smc.write(target.key, bytes: before.bytes, matching: target.info)
            expectTrue(false, "an unprivileged write should not succeed")
        } catch SMCError.ioKit {
            // Expected: kIOReturnNotPrivileged.
        } catch {
            expectTrue(false, "wrong error: \(error)")
        }

        let after = try expectNotNil((try? smc.read(target.key)) ?? nil)
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
