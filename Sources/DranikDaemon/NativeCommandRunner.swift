import Foundation

public enum NativeControlError: Error, CustomStringConvertible {
    case unavailable(String)
    case timedOut(String)
    case failed(String)
    case invalidState(String)
    public var description: String {
        switch self {
        case .unavailable(let value), .timedOut(let value), .failed(let value), .invalidState(let value):
            return value
        }
    }
}

/// Subprocess deadlines contain private-framework/XPC hangs. Killing a helper
/// cannot retract a request already accepted by Apple: timeout is indeterminate,
/// and the coordinator must re-read policy rather than assume rollback.
public enum NativeCommandRunner {
    private static let unresolved = UnresolvedNativeChildren()
    public static func run(executable: String, arguments: [String], timeout: TimeInterval = 4) throws -> Data {
        guard !unresolved.hasRunningChildren else {
            throw NativeControlError.failed("a previous native helper has not exited; further operations are blocked")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        // Do not let an inherited injection setting affect a privileged helper.
        for key in environment.keys where key.hasPrefix("DYLD_") { environment.removeValue(forKey: key) }
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            throw NativeControlError.unavailable("cannot launch \((executable as NSString).lastPathComponent): \(error)")
        }
        // Process closes each Pipe's parent write end when launched (Foundation).
        // Drain both streams concurrently, retaining only a bounded diagnostic.
        let group = DispatchGroup()
        let stdout = BoundedBytes(), stderr = BoundedBytes()
        for (handle, destination) in [(output.fileHandleForReading, stdout), (errors.fileHandleForReading, stderr)] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave(); try? handle.close() }
                while let data = try? handle.read(upToCount: 4096), !data.isEmpty { destination.append(data) }
            }
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // Stop the local caller. Apple's service may still finish an XPC
            // request it already accepted, so the outcome remains indeterminate.
            _ = kill(process.processIdentifier, SIGKILL)
            let confirmedExit = exited.wait(timeout: .now() + 1) == .success
            if !confirmedExit { unresolved.retain(process) }
            _ = group.wait(timeout: .now() + 1)
            throw NativeControlError.timedOut(confirmedExit
                ? "native operation timed out; helper exit confirmed, but the policy must be re-read"
                : "native operation timed out and helper exit is unconfirmed; further operations are blocked")
        }
        guard group.wait(timeout: .now() + 1) == .success else {
            throw NativeControlError.failed("native operation left an unreadable output stream")
        }
        guard !stdout.overflow, !stderr.overflow else {
            throw NativeControlError.failed("native operation exceeded the diagnostic size limit")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let diagnostic = String(data: stderr.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NativeControlError.failed(diagnostic.isEmpty ? "native operation failed (\(process.terminationStatus))" : diagnostic)
        }
        return stdout.data
    }
}

private final class UnresolvedNativeChildren: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [Process] = []
    func retain(_ child: Process) { lock.lock(); defer { lock.unlock() }; children.append(child) }
    var hasRunningChildren: Bool {
        lock.lock(); defer { lock.unlock() }
        children.removeAll { !$0.isRunning }
        return !children.isEmpty
    }
}

private final class BoundedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var exceeded = false
    private let maximum = 64 * 1024
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.count + data.count > maximum { exceeded = true }
        bytes.append(data.prefix(max(0, maximum - bytes.count)))
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var overflow: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
}
