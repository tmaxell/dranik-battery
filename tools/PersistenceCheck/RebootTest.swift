import DranikPower
import DranikSMC
import Foundation

/// Question 2.5: does a closed charge gate survive a reboot?
///
/// The answer decides how bad the worst case is. If a reboot clears the SMC,
/// then "reboot" is a complete recovery from any bug that leaves the gate shut,
/// and the failure mode is an inconvenience. If it does not, the gate can strand
/// a machine across boots and the recovery instructions have to say something
/// else entirely.
///
/// Answering it requires deliberately doing the one thing the rest of the design
/// exists to prevent: leaving the gate closed and rebooting. So the recovery is
/// not left to the operator remembering a command. Arming installs a one-shot
/// LaunchDaemon that runs at the next boot, records what it found, and reopens
/// the gate — before anyone has a chance to notice a machine that will not
/// charge. Installing that daemon happens *before* the gate is closed, and the
/// gate is not closed at all if it cannot be installed.
enum RebootTest {
    static let label = "com.dranik.persistence-check"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let installedBinary = "/usr/local/libexec/dranik-persistence"

    // MARK: - Arm

    static func arm(gate: Gate) -> Never {
        if PersistenceRecord.load()?.observation == nil, FileManager.default.fileExists(atPath: plistPath) {
            fail("a reboot test is already armed. Run `dranik-persistence abort` first.")
        }

        // Order matters: recovery must be in place before the hazard is created.
        do {
            try installBootDaemon()
        } catch {
            fail("""
            could not install the boot-time recovery daemon: \(error)
            The gate has NOT been closed — without automatic recovery this test \
            is not safe to run.
            """)
        }
        note("boot-time recovery installed at \(plistPath)")

        var record = PersistenceRecord(
            key: gate.primary.key.description,
            closedPayload: hex(gate.primary.offBytes),
            openPayload: hex(gate.primary.onBytes),
            armedAt: Date(),
            observation: nil
        )
        do {
            try record.save()
        } catch {
            removeBootDaemon()
            fail("could not write \(PersistenceRecord.path): \(error). Gate NOT closed.")
        }

        do {
            try gate.close()
        } catch {
            removeBootDaemon()
            PersistenceRecord.remove()
            fail("could not close the gate: \(error). Nothing left armed.")
        }

        record.armedAt = Date()
        try? record.save()

        print("""

        ─── armed ──────────────────────────────────────────────

          The charge gate is now CLOSED and will stay closed across the reboot.
          \(gate.describe())

          Reboot when ready:

              sudo reboot

          At the next boot, before you log in, a one-shot daemon will record
          what it finds and reopen the gate. Then:

              sudo dranik-persistence reboot-result

          Changed your mind? This undoes everything:

              sudo dranik-persistence abort

        """)
        exit(0)
    }

    // MARK: - Check, run by launchd at boot

    static func check(gate: Gate) -> Never {
        guard var record = PersistenceRecord.load() else {
            // Nothing was armed; make sure the gate is open regardless and go.
            // This is the boot-time recovery path, so a failure here is the one
            // worth hearing about, not the one worth swallowing.
            let failures = gate.open()
            for failure in failures {
                note("RECOVERY FAILED: \(failure)")
            }
            removeBootDaemon()
            exit(failures.isEmpty ? 0 : 2)
        }

        let payload = gate.read()
        let survived = payload.map(hex) == record.closedPayload
        let reason = (try? PowerReader.snapshot())?.notChargingReason

        note("boot observation: \(gate.describe()), survived=\(survived)")

        let failures = gate.open()

        record.observation = PersistenceRecord.Observation(
            observedAt: Date(),
            payload: payload.map(hex) ?? "<unreadable>",
            survived: survived,
            restoreSucceeded: failures.isEmpty,
            notChargingReason: reason.map(String.init(describing:))
        )
        try? record.save()

        removeBootDaemon()
        exit(0)
    }

    // MARK: - Result

    static func result(gate: Gate) -> Never {
        guard let record = PersistenceRecord.load() else {
            fail("no reboot test on record. Arm one with `reboot-arm`.")
        }
        guard let observation = record.observation else {
            print("""

              A reboot test is armed but has not run yet.
              Armed at \(ISO8601DateFormatter().string(from: record.armedAt)).
              The gate is currently: \(gate.describe())

              Reboot to complete it, or run `abort` to cancel.

            """)
            exit(1)
        }

        print("""

        ─── result: gate across reboot ─────────────────────────
          armed at:    \(ISO8601DateFormatter().string(from: record.armedAt))
          observed at: \(ISO8601DateFormatter().string(from: observation.observedAt))
          wrote:       \(record.key) = \(record.closedPayload)
          found:       \(record.key) = \(observation.payload)
          reason:      \(observation.notChargingReason ?? "-")

        """)

        if observation.survived {
            print("""
              ⚠️  SURVIVED — the gate was still closed after the reboot.

              A reboot is therefore NOT a recovery from a stuck gate, and the
              recovery instructions must say so. Every path that closes the gate
              needs to be certain it can reopen it.
            """)
        } else {
            print("""
              ✅ CLEARED — the SMC was back to its default after the reboot.

              A reboot is a complete recovery from a stuck gate, which puts a
              floor under the worst case: no bug can leave this machine
              permanently refusing to charge.
            """)
        }

        if !observation.restoreSucceeded {
            print("\n  ⚠️  The boot-time restore reported a failure. Check `dranik status`.")
        }
        print("\n  gate now: \(gate.describe())\n")

        PersistenceRecord.remove()
        removeBootDaemon()
        removeInstalledCopy()
        exit(observation.survived ? 1 : 0)
    }

    // MARK: - Abort

    static func abort(gate: Gate) -> Never {
        let failures = gate.open()
        removeBootDaemon()
        removeInstalledCopy()
        PersistenceRecord.remove()
        print("gate reopened, boot daemon, installed copy and record removed")
        print("gate now: \(gate.describe())")
        exit(failures.isEmpty ? 0 : 2)
    }

    // MARK: - launchd plumbing

    /// The plist the boot daemon is installed from. Separate so it can be
    /// inspected — and validated — without installing anything.
    static func bootDaemonPlist() -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [installedBinary, "reboot-check"],
            "RunAtLoad": true,
            "StandardErrorPath": "/var/log/dranik-persistence.log",
            "StandardOutPath": "/var/log/dranik-persistence.log",
        ]
    }

    private static func installBootDaemon() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(
            atPath: (installedBinary as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // Copy rather than point at the build directory, so `make clean` between
        // arming and rebooting cannot leave the machine without its recovery.
        if source != installedBinary {
            try? FileManager.default.removeItem(atPath: installedBinary)
            try FileManager.default.copyItem(atPath: source, toPath: installedBinary)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: installedBinary
        )

        let data = try PropertyListSerialization.data(
            fromPropertyList: bootDaemonPlist(), format: .xml, options: 0
        )
        try data.write(to: URL(fileURLWithPath: plistPath))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: plistPath
        )
    }

    /// Stops the job running again. Removing the plist is what does that;
    /// booting it out of the current launchd session would kill this process
    /// mid-write when called from `check`.
    private static func removeBootDaemon() {
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// Also removes the copied binary. Kept separate from `removeBootDaemon`
    /// because `check` runs *from* that copy — it must survive until the test is
    /// read out or cancelled, at which point nothing should be left behind.
    private static func removeInstalledCopy() {
        try? FileManager.default.removeItem(atPath: installedBinary)
    }
}
