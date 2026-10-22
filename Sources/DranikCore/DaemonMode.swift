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
    /// The firmware will hold the corridor. The daemon sets it and then watches
    /// that it still says what was asked for.
    ///
    /// Preferred over `.limiting` wherever both are available: the firmware keeps
    /// the limit through sleep, through a daemon restart and through a crash, so
    /// most of what the software gate needs defending against stops existing.
    /// A reboot clears it — measured 2026-10-22, the same as the gate — which is
    /// why startup writes it again rather than trusting what it finds.
    case firmwareLimiting
    /// A software charge gate was recognised. The daemon holds the corridor
    /// itself, decision by decision.
    case limiting
    /// Neither was. Watch and answer; never write.
    case observing

    public static func forGate(isSupported: Bool) -> DaemonMode {
        isSupported ? .limiting : .observing
    }

    public static func forHardware(
        firmwareLimitIsSupported: Bool, gateIsSupported: Bool
    ) -> DaemonMode {
        if firmwareLimitIsSupported { return .firmwareLimiting }
        return gateIsSupported ? .limiting : .observing
    }

    /// Principles III and VI: a mode that recognised nothing writes nothing.
    public var mayWriteToSMC: Bool {
        self != .observing
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
    /// VII asks every timer to justify itself; an observing one cannot.
    ///
    /// The firmware path keeps its safety net for a different reason than the
    /// gate path. The gate needs re-deciding; the corridor does not, but it is
    /// state that something else could overwrite — macOS, another tool, a
    /// firmware update — and three reads a minute is what notices.
    public var runsSafetyNet: Bool {
        self != .observing
    }

    /// Whether the corridor must be put back where it was when the process
    /// exits.
    ///
    /// True for the gate, whose closed position stops the battery charging and
    /// so must never outlive the daemon. False for the firmware corridor, which
    /// *is* the limit working: clearing it on exit would mean charge limiting
    /// lapsed on every restart. Uninstalling clears it instead.
    public var restoresOnExit: Bool {
        self == .limiting
    }
}
