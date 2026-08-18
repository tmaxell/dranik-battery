import Foundation

/// Guarantees one daemon at a time.
///
/// Two daemons would both write the charge gate from their own view of the
/// world, and the one that wrote last would win each round — including rounds
/// where one of them wanted the gate open. An advisory lock is enough because
/// the only thing that takes it is the daemon itself.
///
/// The lock is the open file description, not the file: it is released when the
/// process exits, however it exits, so a killed daemon does not leave a stale
/// lock behind the way a plain pid file would.
public final class InstanceLock {
    public enum Failure: Error, CustomStringConvertible {
        case alreadyRunning(pid: pid_t?)
        case cannotOpen(path: String, errno: Int32)

        public var description: String {
            switch self {
            case .alreadyRunning(let pid):
                let who = pid.map { " (pid \($0))" } ?? ""
                return "another instance is already running\(who)"
            case .cannotOpen(let path, let code):
                return "cannot open \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    public static let defaultPath = "/var/run/dranikd.pid"

    private let descriptor: Int32
    private let path: String

    /// Takes the lock, or throws. Never blocks: if another instance holds it,
    /// this one has nothing useful to do and should say so and exit.
    public init(path: String = InstanceLock.defaultPath) throws {
        self.path = path

        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw Failure.cannotOpen(path: path, errno: errno)
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            // Read whoever has it, for the error message only. Best effort: the
            // lock is what matters, the pid is a courtesy.
            let existing = (try? String(contentsOfFile: path, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            close(fd)
            throw Failure.alreadyRunning(pid: existing)
        }

        descriptor = fd

        // Record the pid for humans. Truncate first: a shorter pid must not
        // leave digits of a longer one behind it.
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let line = "\(getpid())\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    deinit {
        release()
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
