import DranikCore
import DranikPower
import DranikSMC
import Foundation

let usage = """
dranik — battery and charge-control inspection for Apple Silicon MacBooks

USAGE
  dranik status [--json]      Battery state, charge-control capabilities, power draw
  dranik smc <KEY>...         Read specific SMC keys, e.g. dranik smc CHTE B0AV
  dranik smc --dump           Enumerate every SMC key as TSV
  dranik watch                Print power events as they arrive
  dranik soak [--since 24h]   Did the daemon behave over the last stretch of time?

Needs a running daemon:
  dranik daemon [--json]      What the daemon is currently doing
  dranik limit <pct> [resume] Change the charge limit, e.g. dranik limit 80 75
  dranik off                  Stop limiting (equivalent to a limit of 100)
  dranik reload               Re-read the configuration file
  dranik help

`dranik` never writes to the SMC itself. The inspection commands read directly
and need no privileges; the daemon commands ask a running daemon to act, and it
is the only thing that touches the charge gate.
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
            let hex = reading.bytes.hexString
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
            let raw = reading.map(\.bytes.hexString)
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

/// Overridable so the control commands can be pointed at a test daemon.
func socketOption() -> String {
    guard let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count else {
        return ControlProtocol.defaultSocketPath
    }
    return arguments[index + 1]
}

/// Arguments with the flags — and the values belonging to them — removed.
///
/// A plain "drop anything starting with --" would leave the socket path behind,
/// and `dranik limit --socket /tmp/x 80` would read the path as the percentage.
func positionalArguments() -> [String] {
    var result: [String] = []
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--socket" {
            index += 2
            continue
        }
        if argument.hasPrefix("--") {
            index += 1
            continue
        }
        result.append(argument)
        index += 1
    }
    return result
}

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

case "watch":
    WatchCommand.run()

case "soak":
    SoakCommand.run(since: {
        guard let index = arguments.firstIndex(of: "--since"), index + 1 < arguments.count
        else { return "24h" }
        return arguments[index + 1]
    }())

case "daemon":
    ControlCommands.daemonStatus(
        socket: socketOption(), json: arguments.dropFirst().contains("--json")
    )

case "limit":
    ControlCommands.limit(arguments: positionalArguments(), socket: socketOption())

case "off":
    ControlCommands.disable(socket: socketOption())

case "reload":
    ControlCommands.reload(socket: socketOption())

case "help", "--help", "-h":
    print(usage)

case let other?:
    fail("unknown command '\(other)'. Try 'dranik help'.")
}
