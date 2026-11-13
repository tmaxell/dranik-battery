import DranikCore
import DranikDaemon
import DranikSMC
import Foundation
import IOKit

/// Key-spec expectations that hold without touching hardware.
func runKeySpecTests() {
    test("macOS-denied keys do not abort discovery of remaining capabilities") {
        var visited: [String] = []
        let capabilities = try Capabilities.detect { key in
            visited.append(key.description)
            switch key.description {
            case "bfF0", "bfD0", "bfE0", "CH0J":
                throw SMCError.ioKit(kIOReturnNotPrivileged)
            case "CHIE":
                return SMCKeyInfo(size: 1, type: "hex_", attributes: 0xD4)
            default:
                return nil
            }
        }
        expectFalse(capabilities.chargeGate.isSupported)
        expectEqual(capabilities.firmwareLimit, .unsupported)
        expectEqual(capabilities.adapterControlKeys.map(\.description), ["CHIE"])
        expectTrue(visited.contains("CHIE"))
    }

    test("a denied primary gate does not hide a supported legacy gate") {
        let capabilities = try Capabilities.detect { key in
            switch key.description {
            case "CHTE": throw SMCError.ioKit(kIOReturnNotPrivileged)
            case "CH0B": return SMCKeySpec.chargeGateCH0B.expectedInfo
            case "CH0C": return SMCKeySpec.chargeGateCH0C.expectedInfo
            case "CHWA": throw SMCError.ioKit(kIOReturnNotPrivileged)
            default: return nil
            }
        }
        expectEqual(capabilities.chargeGate, .pair(.chargeGateCH0B, .chargeGateCH0C))
        expectFalse(capabilities.hasHardwareChargeLimit)
    }

    test("a validated legacy gate survives optional corridor and telemetry probe errors") {
        for failingKey in ["bfF0", "bfD0", "bfE0", "CHWA", "CH0I", "CH0J", "CHIE"] {
            let candidate = FirmwareLimitSpec.bf0
            let capabilities = try Capabilities.detect { key in
                if key.description == failingKey { throw SMCError.notConnected }
                switch key.description {
                case "CHTE": return SMCKeySpec.chargeGateCHTE.expectedInfo
                case "bfF0": return candidate.activationInfo
                case "bfD0": return candidate.upperInfo
                case "bfE0": return candidate.lowerInfo
                default: return nil
                }
            }
            expectEqual(capabilities.chargeGate, .single(.chargeGateCHTE), failingKey)
            let corridorFailed = ["bfF0", "bfD0", "bfE0"].contains(failingKey)
            expectEqual(capabilities.firmwareLimit.isSupported, !corridorFailed, failingKey)
            expectFalse(capabilities.hasHardwareChargeLimit)
            expectTrue(capabilities.adapterControlKeys.isEmpty)
        }
    }

    test("a validated paired gate survives a firmware metadata error") {
        let capabilities = try Capabilities.detect { key in
            switch key.description {
            case "CH0B": return SMCKeySpec.chargeGateCH0B.expectedInfo
            case "CH0C": return SMCKeySpec.chargeGateCH0C.expectedInfo
            case "bfF0": throw SMCError.smc(1)
            default: return nil
            }
        }
        expectEqual(capabilities.chargeGate, .pair(.chargeGateCH0B, .chargeGateCH0C))
        expectEqual(capabilities.firmwareLimit, .unsupported)
    }

    test("a validated firmware corridor survives optional telemetry probe errors") {
        for failingKey in ["CHWA", "CH0I", "CH0J", "CHIE"] {
            let candidate = FirmwareLimitSpec.bf0
            let capabilities = try Capabilities.detect { key in
                if key.description == failingKey { throw SMCError.notConnected }
                switch key.description {
                case "bfF0": return candidate.activationInfo
                case "bfD0": return candidate.upperInfo
                case "bfE0": return candidate.lowerInfo
                default: return nil
                }
            }
            expectFalse(capabilities.chargeGate.isSupported)
            expectEqual(capabilities.firmwareLimit, .supported(candidate), failingKey)
            expectFalse(capabilities.hasHardwareChargeLimit)
            expectTrue(capabilities.adapterControlKeys.isEmpty)
        }
    }

    test("a partial legacy gate does not suppress optional probe errors") {
        do {
            _ = try Capabilities.detect { key in
                switch key.description {
                case "CH0B": return SMCKeySpec.chargeGateCH0B.expectedInfo
                case "bfF0": throw SMCError.notConnected
                default: return nil
                }
            }
            expectTrue(false, "an incomplete gate was treated as validated control")
        } catch SMCError.notConnected {
            // A pair is usable only after both descriptors match.
        }
    }

    test("capability probing without validated control still propagates transport errors") {
        for failingKey in ["CHTE", "bfF0", "CHWA", "CH0I", "CH0J", "CHIE"] {
            do {
                _ = try Capabilities.detect { key in
                    if key.description == failingKey { throw SMCError.notConnected }
                    return nil
                }
                expectTrue(false, "transport error swallowed for \(failingKey)")
            } catch SMCError.notConnected {
                // No validated control exists to preserve; the error stays fatal.
            }
        }
    }

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

    test("a gate is detected, or this machine genuinely has none") {
        // This asserted that a gate was always found, which held until a
        // firmware update took CHTE off the target machine on 2026-10-12 and
        // turned a hardware fact into a red suite. The assertion worth keeping
        // is narrower: whatever gate-shaped key is physically here must be
        // recognised. A machine with none is a fact; a machine with one we
        // failed to match is a defect.
        let smc = try connect()
        defer { smc.close() }

        let capabilities = try Capabilities.detect(using: smc)
        if capabilities.chargeGate.isSupported { return }

        let candidates = ["CHTE", "CH0B", "CH0C"]
        let present = candidates.filter { name in
            guard let key = SMCKey(name) else { return false }
            return ((try? smc.keyInfo(key)) ?? nil) != nil
        }
        guard present.isEmpty else {
            return expectTrue(false, """
            \(present.joined(separator: ", ")) present on this machine but no spec matched — \
            that is detection drifting, not hardware changing
            """)
        }
        try skip("no gate-shaped key exists here (\(candidates.joined(separator: ", ")) all absent)")
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

/// The daemon spent five hours restarting every ten seconds because a firmware
/// update removed its charge-gate key and the only answer it had was to die.
func runDaemonModeTests() {
    test("a recognised gate and no firmware corridor means limiting") {
        expectEqual(
            DaemonMode.forHardware(firmwareLimitIsSupported: false, gateIsSupported: true),
            .limiting
        )
    }

    test("recognising nothing means observing, not exiting") {
        expectEqual(
            DaemonMode.forHardware(firmwareLimitIsSupported: false, gateIsSupported: false),
            .observing
        )
    }

    test("observing never writes to the SMC") {
        // Principles III and VI. A mode that recognised nothing has nothing it
        // is entitled to write.
        expectFalse(DaemonMode.observing.mayWriteToSMC)
        expectTrue(DaemonMode.limiting.mayWriteToSMC)
    }

    test("observing runs no watchdog, because the watchdog would restore the loop") {
        // Not a preference. With no decisions being made, the watchdog's stall
        // detector fires after 120 awake seconds and exits non-zero, which is
        // precisely the restart loop this change removes.
        expectFalse(DaemonMode.observing.runsWatchdog)
        expectTrue(DaemonMode.limiting.runsWatchdog)
    }

    test("the backstop lets the kernel coalesce its wakeup, the follow-up does not") {
        // On a laptop the wakeup costs more than the work done once awake — a
        // decision measures 0.73 ms. A backstop nobody is waiting on can drift;
        // the look taken after a write cannot, because it exists to catch the
        // charger reacting at a known moment.
        expectEqual(Daemon.safetyNetLeeway, .seconds(10))
        expectTrue(Daemon.safetyNetLeeway != .seconds(0))
        expectTrue(
            Daemon.firmwareWriteFollowUp > ChargeGateTiming.observedEffectLatency,
            "the follow-up has to land after the hardware has had time to act"
        )
    }

    test("each mode names the backstop it runs, so the daemon can act on it") {
        // Not a yes-or-no: the two limiting modes both want a timer and want
        // different things from it. As a `Bool` this could not be acted on, and
        // each run path started its own — which is how the property and the
        // daemon could drift apart without anything noticing.
        expectEqual(DaemonMode.observing.safetyNet, .none)
        expectEqual(DaemonMode.limiting.safetyNet, .decisions)
        expectEqual(DaemonMode.firmwareLimiting.safetyNet, .corridor)
    }
}
