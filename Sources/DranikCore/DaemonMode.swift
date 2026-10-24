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

    /// Which backstop timer a mode runs, and why it is not a yes-or-no.
    ///
    /// The two limiting modes both want one and want different things from it,
    /// so the answer has to name the timer rather than merely permit one. It was
    /// a `Bool` first, which the daemon could not act on — each run path started
    /// its own timer and the property existed only for a test to agree with.
    public enum SafetyNet: Equatable, Sendable {
        /// Nothing to re-evaluate, so nothing on a timer. Principle VII asks
        /// every timer to justify itself; an observing one cannot.
        case none
        /// Re-decide from scratch. The gate path, where the daemon holds the
        /// corridor itself and a missed event costs enforcement.
        case decisions
        /// Re-read the corridor and what the charger did about it. The firmware
        /// holds the corridor between passes, so nothing needs re-deciding —
        /// but the keys are state something else could overwrite, and the moment
        /// charging actually stops is announced by nothing at all.
        case corridor
    }

    public var safetyNet: SafetyNet {
        switch self {
        case .limiting: return .decisions
        case .firmwareLimiting: return .corridor
        case .observing: return .none
        }
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
