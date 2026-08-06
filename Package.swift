// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dranik-battery",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dranik", targets: ["dranik"]),
        .library(name: "DranikSMC", targets: ["DranikSMC"]),
        .library(name: "DranikPower", targets: ["DranikPower"]),
    ],
    targets: [
        // Layout of AppleSMC's SMCParamStruct. Kept in C so the compiler,
        // not us, guarantees the 80-byte layout the kext expects.
        .target(name: "CDranikSMC"),

        .target(
            name: "DranikSMC",
            dependencies: ["CDranikSMC"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DranikPower",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "dranik",
            dependencies: ["DranikSMC", "DranikPower"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Not a .testTarget: XCTest ships with Xcode and swift-testing needs a
        // toolchain providing the `Testing` module. The target machine has
        // Command Line Tools only, so the suite is an ordinary executable.
        // Run it with `make test`.
        .executableTarget(
            name: "dranik-selftest",
            dependencies: ["DranikSMC", "DranikPower", "CDranikSMC"],
            path: "Tests/DranikSelfTest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
