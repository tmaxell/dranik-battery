import DranikPower
import DranikSMC
import Foundation

/// Opening and closing the gate, shared by both tests.
struct Gate {
    let smc: SMCConnection
    let specs: [SMCKeySpec]

    init() {
        do {
            smc = try SMCConnection()
        } catch {
            fail("cannot open AppleSMC: \(error)")
        }
        do {
            specs = try Capabilities.detect(using: smc).chargeGate.specs
        } catch {
            fail("cannot probe SMC capabilities: \(error)")
        }
        if specs.isEmpty {
            fail("no charge-gate key on this machine matched its expected description")
        }
    }

    var primary: SMCKeySpec { specs[0] }

    func close() throws {
        for spec in specs {
            try smc.write(spec.key, bytes: spec.offBytes, matching: spec.expectedInfo)
            note("wrote \(spec.key) = \(hex(spec.offBytes)) — gate closed")
        }
    }

    /// Opens the gate. Reports which keys it could not restore rather than
    /// throwing, so a partial failure still restores everything it can.
    @discardableResult
    func open() -> [String] {
        var failures: [String] = []
        for spec in specs {
            do {
                try smc.write(spec.key, bytes: spec.onBytes, matching: spec.expectedInfo)
                note("wrote \(spec.key) = \(hex(spec.onBytes)) — gate open")
            } catch {
                failures.append("\(spec.key): \(error)")
                note("RESTORE FAILED for \(spec.key): \(error)")
            }
        }
        return failures
    }

    func read() -> [UInt8]? {
        ((try? smc.read(primary.key)) ?? nil)?.bytes
    }

    var isOpen: Bool {
        read() == primary.onBytes
    }

    func describe() -> String {
        specs.map { spec in
            let bytes = ((try? smc.read(spec.key)) ?? nil)?.bytes
            let value = bytes.map(hex) ?? "<unreadable>"
            let state = bytes == spec.onBytes ? "open" : bytes == spec.offBytes ? "closed" : "unexpected"
            return "\(spec.key)=\(value) (\(state))"
        }.joined(separator: " ")
    }
}
