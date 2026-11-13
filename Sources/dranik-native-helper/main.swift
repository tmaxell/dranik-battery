import DranikNative
import Foundation

// Private framework calls are deliberately isolated in this short-lived process.
// The daemon enforces a deadline and kills this process if Apple's XPC stalls.
// Also bound direct installer/diagnostic invocations without a daemon parent.
alarm(8)
let client = NativeChargeClient()
let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args {
    case ["status"]:
        break
    case ["disable"]:
        try client.disableNativeLimit()
    case let values where values.count == 2 && values[0] == "set":
        guard let target = Int(values[1]), (50...100).contains(target) else {
            throw NSError(domain: "DranikNativeHelper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "target must be 50 through 100"])
        }
        try client.requestLimit(target)
    default:
        throw NSError(domain: "DranikNativeHelper", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "usage: dranik-native-helper status | set <50...100> | disable"])
    }
    let data = try JSONEncoder().encode(client.snapshot())
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("native helper: \(error.localizedDescription)\n".utf8))
    exit(1)
}
