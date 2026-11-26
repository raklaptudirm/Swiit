import Foundation
import Testing

@testable import Swiit

// Swift programs and what the compiler printed for each (parity.json). A case
// marked "ok" must print the same here; one marked "todo" is a gap, and the
// test fails when it starts passing, so the file is changed (to "ok") in
// the change that closes the gap, and the gaps only close.

private struct ParityCase: Decodable, Sendable, CustomTestStringConvertible {
    var name: String
    var source: String
    var expected: String
    var status: String
    var testDescription: String { name }
}

private let parityCases: [ParityCase] = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("parity.json")
    return try! JSONDecoder().decode([ParityCase].self, from: Data(contentsOf: url))
}()

/// What the program printed, or why it didn't run.
private func printed(_ source: String) -> (output: String, problem: String?) {
    nonisolated(unsafe) var output = ""
    let host = Interpreter.Host(
        output: OutputSink({
            output += $0; return true
        }),
        error: OutputSink({
            output += "err: " + $0; return true
        })
    )
    let interpreter = Interpreter(host: host, limits: Interpreter.Limits())
    do {
        _ = try interpreter.evaluate(source)
        return (output, nil)
    } catch let diagnostic as Diagnostic {
        return (output, "\(diagnostic.kind) error: \(diagnostic.message)")
    } catch {
        return (output, "error: \(error)")
    }
}

@Test(arguments: parityCases.filter { $0.status == "ok" })
private func swiftPrintsWhatTheCompilerPrints(_ item: ParityCase) {
    let result = printed(item.source)
    #expect(result.problem == nil, Comment(rawValue: result.problem ?? ""))
    #expect(result.output == item.expected)
}

@Test func gapsThatCloseAreMarkedOk() {
    let closed = parityCases.filter { $0.status == "todo" }
        .filter { item in
            let result = printed(item.source)
            return result.problem == nil && result.output == item.expected
        }
        .map(\.name)
    #expect(closed == [], "these now pass: mark them \"ok\" in parity.json")
}

/// `PARITY_REPORT=1 swift test --filter theGapsAndWhyTheyAreOpen`: each open
/// gap, with what stops it, for choosing what to close next.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PARITY_REPORT"] != nil))
func theGapsAndWhyTheyAreOpen() {
    var lines: [String] = []
    for item in parityCases where item.status == "todo" {
        let result = printed(item.source)
        let why =
            result.problem
            ?? (result.output == item.expected
                ? "passes"
                : "prints \(result.output.debugDescription), not \(item.expected.debugDescription)")
        lines.append(
            "GAP \(item.name): \(why.split(separator: "\n").first.map(String.init) ?? why)"
        )
    }
    print(lines.joined(separator: "\n"))
}

/// `PARITY_RUN='print(1)' swift test --filter runTheGivenSource`: one program, for looking at what
/// it does.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PARITY_RUN"] != nil))
func runTheGivenSource() {
    let source = ProcessInfo.processInfo.environment["PARITY_RUN"]!
    let result = printed(source)
    print("OUTPUT:", result.output, "PROBLEM:", result.problem ?? "none")
    let interpreter = Interpreter(
        host: Interpreter.Host(output: OutputSink({ _ in true }), error: OutputSink({ _ in true })),
        limits: Interpreter.Limits()
    )
    do { _ = try interpreter.evaluate(source) } catch let diagnostic as Diagnostic {
        print("RENDERED:\n" + diagnostic.rendered(in: source))
    } catch {}
    print("TREE RUNS:", interpreter.vmTreeRuns)
}

/// How much of the programs the VM runs: each function it left to the tree evaluator, by reason.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PARITY_REPORT"] != nil))
func theFunctionsTheVMLeavesToTheTree() {
    var reasons: [String: Int] = [:]
    var loops = 0
    var slow: [String: Int] = [:]
    var entries = 0
    for item in parityCases where item.status == "ok" {
        let interpreter = Interpreter(host: Interpreter.Host(), limits: Interpreter.Limits())
        interpreter.engine = .vm
        _ = try? interpreter.evaluate(item.source)
        loops += interpreter.vmLoops
        entries += interpreter.vmEntries
        for (kind, count) in interpreter.vmSlowCalls { slow[kind, default: 0] += count }
        for fallback in interpreter.vmFallbacks {
            reasons[String(fallback.drop { $0 != ":" }.dropFirst(2)), default: 0] += 1
        }
    }
    print("VM: \(loops) top-level loops compiled; left to the tree: \(reasons.values.reduce(0, +))")
    for (reason, count) in reasons.sorted(by: { $0.value > $1.value }) {
        print("  \(count) × \(reason)")
    }
    print("VM entered from outside \(entries) times; calls the loop gave the tree evaluator:")
    for (kind, count) in slow.sorted(by: { $0.value > $1.value }) {
        print("  \(count) × \(kind)")
    }
}
