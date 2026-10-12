/// What the daemon is allowed to do, decided once at startup from what the
/// hardware turned out to offer.
///
/// On 2026-10-12 a firmware update took `CHTE` off the target machine. Probing
/// did the right thing and refused to write anything — but the process then
/// exited non-zero, and `KeepAlive { SuccessfulExit: false }` brought it back
/// every ten seconds for five hours. The comment above that exit claimed it was
/// "not a crash loop".
///
/// The lesson is not "exit zero instead". It is that a daemon with nothing to
/// control still has work: holding the socket, answering, and saying plainly
/// that this machine cannot be limited — a state the CLI and the app already
/// render and could never reach, because nothing lived long enough to publish it.
public enum DaemonMode: Equatable, Sendable {
    /// A way of controlling charging was recognised.
    case limiting
    /// None was. Watch and answer; never write.
    case observing

    public static func forGate(isSupported: Bool) -> DaemonMode {
        isSupported ? .limiting : .observing
    }

    /// Principles III and VI: a mode that recognised nothing writes nothing.
    public var mayWriteToSMC: Bool {
        self == .limiting
    }

    /// The watchdog must not run while observing, and this is forced rather than
    /// chosen. It fires when the controller has made no decision in 120 awake
    /// seconds — and an observing daemon makes none by design. It would call
    /// `exit(EX_SOFTWARE)`, launchd would restart the process, and the crash
    /// loop would be back with a two-minute period instead of a ten-second one.
    /// Its rescue would also have nothing to open: there are no key specs.
    public var runsWatchdog: Bool {
        self == .limiting
    }

    /// Nothing to re-evaluate, so nothing to re-evaluate on a timer. Principle
    /// VII asks every timer to justify itself; this one cannot.
    public var runsSafetyNet: Bool {
        self == .limiting
    }
}
