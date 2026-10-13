import Foundation

// A minimal, dependency-free test harness.
//
// XCTest is not available with a bare Command Line Tools install (`import XCTest` fails), and
// this project deliberately has no package dependencies. The harness below keeps the tests
// runnable everywhere `swift build` works.

public struct TestCase {
    public let name: String
    public let body: () throws -> Void
    public init(_ name: String, _ body: @escaping () throws -> Void) {
        self.name = name
        self.body = body
    }
}

public struct TestFailure: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Records the outcome of the current test so the runner can report it.
final class TestContext {
    var failures: [String] = []
    var checks = 0
    var currentFile = ""
    var currentLine = 0
    var skipped = false
}

var context = TestContext()

// MARK: - Assertions

public func expectTrue(_ condition: Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    context.checks += 1
    guard condition else {
        context.failures.append("\(file):\(line): expected true — \(message)")
        return
    }
}

public func expectFalse(_ condition: Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    expectTrue(!condition, message, file: file, line: line)
}

public func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
    context.checks += 1
    guard actual != expected else { return }
    context.failures.append("\(file):\(line): expected \(expected), got \(actual) — \(message)")
}

public func expectEqual(_ actual: Double, _ expected: Double, accuracy: Double, _ message: String = "", file: String = #fileID, line: Int = #line) {
    context.checks += 1
    guard abs(actual - expected) <= accuracy else {
        context.failures.append("\(file):\(line): expected \(expected) ±\(accuracy), got \(actual) — \(message)")
        return
    }
}

public func expectNil<T>(_ value: T?, _ message: String = "", file: String = #fileID, line: Int = #line) {
    context.checks += 1
    guard value == nil else {
        context.failures.append("\(file):\(line): expected nil, got \(value!) — \(message)")
        return
    }
}

public func expectNotNil<T>(_ value: T?, _ message: String = "", file: String = #fileID, line: Int = #line) {
    context.checks += 1
    guard value != nil else {
        context.failures.append("\(file):\(line): expected a value — \(message)")
        return
    }
}

public func expectThrows<T>(_ message: String = "", file: String = #fileID, line: Int = #line, _ body: () throws -> T) {
    context.checks += 1
    do {
        _ = try body()
        context.failures.append("\(file):\(line): expected an error to be thrown — \(message)")
    } catch {
        // expected
    }
}

public func expectNoThrow<T>(file: String = #fileID, line: Int = #line, _ body: () throws -> T) -> T? {
    context.checks += 1
    do {
        return try body()
    } catch {
        context.failures.append("\(file):\(line): unexpected error: \(error)")
        return nil
    }
}

public func unwrap<T>(_ value: T?, _ message: String = "", file: String = #fileID, line: Int = #line) throws -> T {
    context.checks += 1
    guard let value else {
        throw TestFailure(message: "\(file):\(line): expected a value — \(message)")
    }
    return value
}

public func skip(_ reason: String) {
    context.skipped = true
    FileHandle.standardError.write("skipped: \(reason)\n".data(using: .utf8)!)
}

// MARK: - Runner

public func runTests(_ suites: [(String, [TestCase])]) -> Int32 {
    var passed = 0
    var failed = 0
    var skipped = 0
    let start = Date()

    for (suiteName, cases) in suites {
        print("\n\(suiteName)")
        for testCase in cases {
            context = TestContext()
            let testStart = Date()
            do {
                try testCase.body()
            } catch let failure as TestFailure {
                context.failures.append(failure.message)
            } catch {
                context.failures.append("threw \(error)")
            }
            let elapsed = Date().timeIntervalSince(testStart)
            if context.skipped {
                skipped += 1
                print("  ⤼ \(testCase.name) (skipped)")
            } else if context.failures.isEmpty {
                passed += 1
                print(String(format: "  ✓ %@  (%d checks, %.3fs)", testCase.name, context.checks, elapsed))
            } else {
                failed += 1
                print("  ✗ \(testCase.name)")
                for failure in context.failures { print("      \(failure)") }
            }
        }
    }

    let total = Date().timeIntervalSince(start)
    print("")
    print(String(format: "%d passed, %d failed, %d skipped in %.2fs", passed, failed, skipped, total))
    return failed == 0 ? 0 : 1
}
