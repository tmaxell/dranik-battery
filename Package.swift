// swift-tools-version: 5.10
//
// Pinned to 5.10 rather than 6.0 so the package builds under either toolchain
// present on the target machine: Command Line Tools (Swift 6.0.3) and
// Xcode 15.4 (Swift 5.10). A 6.0 manifest is rejected outright by the older
// SwiftPM, which would break the build the moment `xcode-select` is pointed at
// Xcode. Nothing is given up: 5.10 already defaults to the Swift 5 language
// mode, which is what the 6.0 manifest asked for explicitly.
import PackageDescription

let package = Package(
    name: "dranik-battery",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dranik", targets: ["dranik"]),
        .executable(name: "dranikd", targets: ["dranikd"]),
        .library(name: "DranikSMC", targets: ["DranikSMC"]),
        .library(name: "DranikPower", targets: ["DranikPower"]),
        .library(name: "DranikCore", targets: ["DranikCore"]),
    ],
    targets: [
        // Layout of AppleSMC's SMCParamStruct. Kept in C so the compiler,
        // not us, guarantees the 80-byte layout the kext expects.
        .target(name: "CDranikSMC"),

        .target(name: "DranikSMC", dependencies: ["CDranikSMC"]),
        // Power-management message types, derived by the C preprocessor from
        // Apple's headers rather than hardcoded.
        .target(name: "CDranikPower"),
        .target(name: "DranikPower", dependencies: ["CDranikPower"]),

        // Decisions only: no IOKit, no clock, no filesystem. Every branch is
        // reachable from a plain struct, which is why it can be tested whole.
        .target(name: "DranikCore"),

        .executableTarget(name: "dranik", dependencies: ["DranikSMC", "DranikPower"]),

        // The daemon's moving parts, in a library so the safety mechanisms can
        // be tested rather than only reasoned about.
        .target(
            name: "DranikDaemon",
            dependencies: ["DranikSMC", "DranikPower", "DranikCore"]
        ),
        .executableTarget(name: "dranikd", dependencies: ["DranikDaemon"]),

        // Writes to the SMC. Kept out of the `dranik` CLI so it cannot be
        // reached by accident: it must be invoked by name, as root.
        .executableTarget(
            name: "dranik-gate-experiment",
            dependencies: ["DranikSMC", "DranikPower"],
            path: "tools/GateExperiment"
        ),

        // Answers the sleep/reboot persistence questions. Writes to the SMC,
        // so it too is a separate executable that must be invoked by name.
        .executableTarget(
            name: "dranik-persistence",
            dependencies: ["DranikSMC", "DranikPower", "DranikCore"],
            path: "tools/PersistenceCheck"
        ),

        // Not a .testTarget: XCTest lives in Xcode, and `xcode-select` currently
        // points at Command Line Tools, so it cannot be imported. The suite is an
        // ordinary executable instead. Run it with `make test`.
        .executableTarget(
            name: "dranik-selftest",
            dependencies: ["DranikSMC", "DranikPower", "DranikCore", "DranikDaemon", "CDranikSMC"],
            path: "Tests/DranikSelfTest"
        ),
    ]
)
