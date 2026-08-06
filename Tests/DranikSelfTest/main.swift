import Foundation

print("dranik self-test")

runLayoutTests()
runDecodingTests()
runKeySpecTests()
runBatterySnapshotTests()

// These touch the real SMC and battery. They read only — no key is ever written.
runLiveSMCTests()
runLivePowerReaderTests()

exit(Harness.summary())
