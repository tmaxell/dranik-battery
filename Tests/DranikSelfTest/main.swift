import Foundation

print("dranik self-test")

runLayoutTests()
runDecodingTests()
runKeySpecTests()
runBatterySnapshotTests()

// These touch the real SMC and battery. Every one of them either reads, or
// exercises a write that the guards are expected to refuse before it reaches the
// kernel. No SMC key is ever actually changed by this suite.
runLiveSMCTests()
runLivePowerReaderTests()
runWriteGuardTests()

exit(Harness.summary())
