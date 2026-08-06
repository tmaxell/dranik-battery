import Foundation

// A minimal test harness.
//
// XCTest ships with Xcode, and swift-testing needs a toolchain that provides the
// `Testing` module. The target machine has Command Line Tools only, so neither is
// importable and `swift test` cannot run. Rather than make Xcode a prerequisite or
// take a network dependency, the suite is an ordinary executable: `make test`.
//
// If Xcode is installed later this can be swapped for XCTest; the assertions are
// deliberately named the same way to keep that port mechanical.

enum Harness {
    nonisolated(unsafe) static var currentTest = ""
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var passedTests = 0
    nonisolated(unsafe) static var skippedTests: [String] = []
    nonisolated(unsafe) static var assertions = 0
    nonisolated(unsafe) private static var failedInCurrentTest = false

    struct Skip: Error {
        let reason: String
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        failedInCurrentTest = false
        do {
            try body()
            if !failedInCurrentTest {
                passedTests += 1
            }
        } catch let skip as Skip {
            skippedTests.append("\(name) — \(skip.reason)")
        } catch {
            record("threw \(error)", file: #file, line: #line)
        }
    }

    static func record(_ message: String, file: StaticString, line: UInt) {
        failedInCurrentTest = true
        let name = "\(file)".split(separator: "/").last.map(String.init) ?? "\(file)"
        failures.append("\(currentTest): \(message)  [\(name):\(line)]")
    }

    static func summary() -> Int32 {
        print("")
        for failure in failures {
            print("  FAIL  \(failure)")
        }
        for skipped in skippedTests {
            print("  SKIP  \(skipped)")
        }
        let status = failures.isEmpty ? "PASSED" : "FAILED"
        print("""

        \(status): \(passedTests) tests, \(assertions) assertions, \
        \(failures.count) failures, \(skippedTests.count) skipped
        """)
        return failures.isEmpty ? 0 : 1
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    Harness.test(name, body)
}

func skip(_ reason: String) throws -> Never {
    throw Harness.Skip(reason: reason)
}

func expectTrue(
    _ value: Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.assertions += 1
    guard !value else { return }
    Harness.record("expected true\(suffix(message()))", file: file, line: line)
}

func expectFalse(
    _ value: Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.assertions += 1
    guard value else { return }
    Harness.record("expected false\(suffix(message()))", file: file, line: line)
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.assertions += 1
    guard actual != expected else { return }
    Harness.record("expected \(expected), got \(actual)\(suffix(message()))", file: file, line: line)
}

func expectNotEqual<T: Equatable>(
    _ actual: T,
    _ unexpected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.assertions += 1
    guard actual == unexpected else { return }
    Harness.record("expected anything but \(unexpected)\(suffix(message()))", file: file, line: line)
}

func expectClose(
    _ actual: Double,
    _ expected: Double,
    accuracy: Double,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.assertions += 1
    guard abs(actual - expected) > accuracy else { return }
    Harness.record(
        "expected \(expected) ± \(accuracy), got \(actual)\(suffix(message()))",
        file: file, line: line
    )
}

func expectNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.assertions += 1
    guard let value else { return }
    Harness.record("expected nil, got \(value)\(suffix(message()))", file: file, line: line)
}

/// Returns the wrapped value or throws, so a test can stop instead of
/// cascading failures off a `nil`.
@discardableResult
func expectNotNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws -> T {
    Harness.assertions += 1
    guard let value else {
        Harness.record("expected non-nil\(suffix(message()))", file: file, line: line)
        throw Harness.Skip(reason: "value was nil")
    }
    return value
}

func expectInRange<T: Comparable>(
    _ value: T,
    _ range: ClosedRange<T>,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.assertions += 1
    guard !range.contains(value) else { return }
    Harness.record("expected \(value) within \(range)\(suffix(message()))", file: file, line: line)
}

private func suffix(_ message: String) -> String {
    message.isEmpty ? "" : " — \(message)"
}
