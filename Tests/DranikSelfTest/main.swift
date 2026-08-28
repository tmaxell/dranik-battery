import Foundation

print("dranik self-test")

runLayoutTests()
runDecodingTests()
runKeySpecTests()
runBatterySnapshotTests()
runNotChargingReasonTests()
runChargeConfigTests()
runChargeControllerTests()
runSleepDetectorTests()
runConfigStoreTests()
runInstanceLockTests()
runWatchdogTests()
runSuppressionWindowTests()
runSleepPolicyTests()
runGateVerificationTests()
runGateTrustTests()
runGateApplicationTests()
runSoakAnalysisTests()
runSoakRatioTests()
runControlTests()
runMenuBarPresentationTests()

// Power-event subscriptions need neither a battery nor a charge gate — only
// notifyd and IOKit, which any Mac has.
runPowerEventTests()

// These three read the real SMC and battery. Every one of them either reads, or
// exercises a write that the guards are expected to refuse before it reaches the
// kernel. No SMC key is ever actually changed by this suite.
//
// `--skip-hardware` exists for continuous integration, where the machine is
// some other Mac. "A charge gate is detected" is an assertion about *this*
// hardware: on a builder without one it fails, and a red build that says nothing
// about the code is worse than no build at all. Skipping is a request, never
// automatic — locally these are the tests that matter most.
if CommandLine.arguments.contains("--skip-hardware") {
    print("skipping the hardware groups by request\n")
} else {
    runLiveSMCTests()
    runLivePowerReaderTests()
    runWriteGuardTests()
}

exit(Harness.summary())
