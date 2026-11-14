import Foundation

/// Minimal assertion harness.
///
/// The Command Line Tools ship an incomplete `Testing.framework` and no XCTest,
/// so neither standard runner works without a full Xcode install. This keeps the
/// suite dependency-free and runnable via `swift run HiFiGuardTests`.
enum Harness {
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var currentSuite = ""

    static func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        print("\n\(name)")
        body()
    }

    static func test(_ name: String, _ body: () -> Void) {
        let before = failures.count
        body()
        if failures.count == before {
            passed += 1
            print("  ✓ \(name)")
        } else {
            print("  ✗ \(name)")
            for failure in failures[before...] {
                print("      \(failure)")
            }
        }
    }

    static func expect<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard actual != expected else { return }
        failures.append("\(label): expected \(expected), got \(actual) (line \(line))")
    }

    static func expectNil<T>(_ actual: T?, _ label: String, line: UInt = #line) {
        guard actual != nil else { return }
        failures.append("\(label): expected nil, got \(String(describing: actual)) (line \(line))")
    }

    static func fail(_ message: String, line: UInt = #line) {
        failures.append("\(message) (line \(line))")
    }

    /// Prints the summary and exits non-zero if anything failed, so CI can gate on it.
    static func finish() -> Never {
        print("\n\(passed) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }
}
