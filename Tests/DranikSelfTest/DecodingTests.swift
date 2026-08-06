import DranikSMC
import Foundation

/// Byte payloads here are real readings captured from the target machine
/// (MacBookPro17,1, macOS 14.8.7). The expected values are what IOKit reported at
/// the same moment, so these tests pin the endianness question rather than just
/// restating the implementation.
func runDecodingTests() {
    test("unsigned is little-endian") {
        // B0AV read `62 32` while IOKit reported Voltage = 12897 mV.
        expectEqual(SMCValue(type: "ui16", bytes: [0x62, 0x32]), .unsigned(12898))
    }

    test("signed is little-endian") {
        // B0AC read `9f 04` while IOKit reported Amperage = 1167 mA.
        expectEqual(SMCValue(type: "si16", bytes: [0x9F, 0x04]), .signed(1183))
    }

    test("float is little-endian") {
        // TB0T; IOKit reported Temperature = 3043 (30.43 °C) at the same moment.
        let value = SMCValue(type: "flt", bytes: [0xC8, 0xCC, 0xF8, 0x41])
        guard case .floating(let celsius) = value else {
            return expectTrue(false, "expected a floating value, got \(value)")
        }
        expectClose(celsius, 31.1, accuracy: 0.01)
    }

    test("adapter power cross-checks its own factors") {
        // VD0R × ID0R must equal PDTR. Three independent keys agreeing is what
        // rules out a big-endian reading.
        guard case .floating(let volts) = SMCValue(type: "flt", bytes: [0x0E, 0x6D, 0x9D, 0x41]),
              case .floating(let amps) = SMCValue(type: "flt", bytes: [0xB1, 0x77, 0xAD, 0x3F]),
              case .floating(let watts) = SMCValue(type: "flt", bytes: [0xF0, 0x53, 0xD5, 0x41])
        else {
            return expectTrue(false, "expected floating values")
        }
        expectClose(volts, 19.678, accuracy: 0.01)
        expectClose(amps, 1.355, accuracy: 0.01)
        expectClose(volts * amps, watts, accuracy: 0.01)
    }

    test("capacity keys match IOKit") {
        // B0FC / B0DC / B0CT against AppleRawMaxCapacity / DesignCapacity / CycleCount.
        expectEqual(SMCValue(type: "ui16", bytes: [0x3E, 0x12]), .unsigned(4670))
        expectEqual(SMCValue(type: "ui16", bytes: [0xEF, 0x13]), .unsigned(5103))
        expectEqual(SMCValue(type: "ui16", bytes: [0xAA, 0x00]), .unsigned(170))
    }

    test("signed negative value") {
        // AC-B reads `ff`.
        expectEqual(SMCValue(type: "si8", bytes: [0xFF]), .signed(-1))
    }

    test("charge gate payloads decode") {
        expectEqual(SMCValue(type: "ui32", bytes: [0, 0, 0, 0]), .unsigned(0))
        expectEqual(SMCValue(type: "ui32", bytes: [1, 0, 0, 0]), .unsigned(1))
    }

    test("flag") {
        expectEqual(SMCValue(type: "flag", bytes: [0x00]), .flag(false))
        expectEqual(SMCValue(type: "flag", bytes: [0x01]), .flag(true))
    }

    test("opaque type stays raw") {
        expectEqual(SMCValue(type: "hex_", bytes: [0x01, 0x01]), .raw([0x01, 0x01]))
        expectEqual(SMCValue(type: "ch8*", bytes: [0x41, 0x42]), .raw([0x41, 0x42]))
    }

    test("size mismatch falls back to raw instead of guessing") {
        expectEqual(SMCValue(type: "ui32", bytes: [0x01, 0x02]), .raw([0x01, 0x02]))
        expectEqual(SMCValue(type: "flt", bytes: [0x01]), .raw([0x01]))
    }

    test("doubleValue is nil only for raw") {
        expectEqual(SMCValue(type: "ui8", bytes: [42]).doubleValue, 42)
        expectEqual(SMCValue(type: "flag", bytes: [1]).doubleValue, 1)
        expectNil(SMCValue(type: "hex_", bytes: [1, 2]).doubleValue)
    }

    test("key round-trip") {
        let key = SMCKey("CHTE")
        expectEqual(key?.rawValue, 0x4348_5445)
        expectEqual(key?.description, "CHTE")
    }

    test("key rejects wrong length") {
        expectNil(SMCKey("CHT"))
        expectNil(SMCKey("CHTEX"))
        expectNil(SMCKey(""))
    }

    test("key rejects non-printable characters") {
        expectNil(SMCKey("CH\u{0}E"))
        expectNil(SMCKey("CHTÉ"))
    }

    test("key accepts punctuation used by real keys") {
        expectEqual(SMCKey("#KEY")?.description, "#KEY")
        expectEqual(SMCKey("AC-W")?.description, "AC-W")
    }

    test("type code strips padding") {
        expectEqual(SMCTypeCode.decode(0x7569_3820), "ui8")
        expectEqual(SMCTypeCode.decode(0x666C_7420), "flt")
        expectEqual(SMCTypeCode.decode(0x7569_3332), "ui32")
        expectEqual(SMCTypeCode.decode(0x6865_785F), "hex_")
    }

    test("writable attribute bit") {
        // 0xd4/0xd0 mark the writable charge-control keys; 0x84/0x90 mark telemetry.
        expectTrue(SMCKeyInfo(size: 4, type: "ui32", attributes: 0xD4).isWritable)
        expectTrue(SMCKeyInfo(size: 1, type: "ui8", attributes: 0xD0).isWritable)
        expectFalse(SMCKeyInfo(size: 2, type: "ui16", attributes: 0x84).isWritable)
        expectFalse(SMCKeyInfo(size: 1, type: "si8", attributes: 0x90).isWritable)
    }
}
