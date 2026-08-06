import DranikPower
import DranikSMC
import Foundation

let usage = """
dranik — battery and charge-control inspection for Apple Silicon MacBooks

USAGE
  dranik status [--json]      Battery state, charge-control capabilities, power draw
  dranik smc <KEY>...         Read specific SMC keys, e.g. dranik smc CHTE B0AV
  dranik smc --dump           Enumerate every SMC key as TSV
  dranik help

This build only reads. It never writes to the SMC, so it cannot change how the
machine charges. Reading needs no privileges.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dranik: \(message)\n".utf8))
    exit(1)
}

func runStatus(json: Bool) {
    do {
        let report = try StatusReport.gather()
        print(json ? try report.json() : report.humanReadable())
    } catch {
        fail(String(describing: error))
    }
}

func runSMCRead(_ names: [String]) {
    do {
        let smc = try SMCConnection()
        defer { smc.close() }

        for name in names {
            guard let key = SMCKey(name) else {
                fail("malformed key '\(name)': expected four printable ASCII characters")
            }
            guard let reading = try smc.read(key) else {
                print("\(key)\tabsent")
                continue
            }
            let hex = reading.bytes.map { String(format: "%02x", $0) }.joined()
            print("\(key)\t\(reading.info.type)\t\(reading.info.size)\t"
                + String(format: "0x%02x", reading.info.attributes) + "\t"
                + (reading.info.isWritable ? "W" : "-") + "\t"
                + "\(reading.value)\t\(hex)")
        }
    } catch {
        fail(String(describing: error))
    }
}

func runSMCDump() {
    do {
        let smc = try SMCConnection()
        defer { smc.close() }

        let count = try smc.keyCount()
        FileHandle.standardError.write(Data("enumerating \(count) keys\n".utf8))
        print("key\ttype\tsize\tattr\twritable\tvalue\traw")

        for index in 0..<count {
            guard let key = try? smc.key(at: index), key.rawValue != 0 else { continue }
            guard let info = (try? smc.keyInfo(key)) ?? nil else { continue }

            // Some keys advertise metadata but refuse to be read — often
            // write-only or size-gated ones. Report them rather than dropping
            // them: for a diagnostic tool an unreadable key is a finding.
            let reading = try? smc.read(key)
            let value = reading.map { "\($0.value)" } ?? ""
            let raw = reading.map { $0.bytes.map { String(format: "%02x", $0) }.joined() }
                ?? "<unreadable>"

            print("\(key)\t\(info.type)\t\(info.size)\t"
                + String(format: "0x%02x", info.attributes) + "\t"
                + (info.isWritable ? "W" : "-") + "\t"
                + "\(value)\t\(raw)")
        }
    } catch {
        fail(String(describing: error))
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "status":
    runStatus(json: arguments.dropFirst().contains("--json"))

case "smc":
    let rest = Array(arguments.dropFirst())
    if rest.contains("--dump") {
        runSMCDump()
    } else if rest.isEmpty {
        fail("smc: expected one or more key names, or --dump")
    } else {
        runSMCRead(rest)
    }

case "help", "--help", "-h":
    print(usage)

case let other?:
    fail("unknown command '\(other)'. Try 'dranik help'.")
}
