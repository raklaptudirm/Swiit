import Foundation
import Testing

@testable import Swiit

// Timing of the paths the type record touches, run only when asked (`SWIIT_TIMING=1 swift test -c
// release --filter timing`). Each script runs seven times and its median is printed, to compare with
// the baseline recorded in Docs/type-implementation.md.

private let scripts: [(name: String, source: String)] = [
    (
        "list read",
        "var xs = Array(repeating: 1, count: 100)\nvar t = 0\nfor i in 0..<300000 { t += xs[i % 100] }\nt"
    ),
    ("append", "var a: [Int] = []\nfor i in 0..<300000 { a.append(i) }\na.count"),
    (
        "struct",
        "struct P { var x: Int\n func sum() -> Int { x } }\nvar t = 0\nfor i in 0..<300000 { var q = P(x: i); q.x += 1; t += q.sum() }\nt"
    ),
    (
        "class method",
        "class C { var n = 0\n func bump() { n += 1 } }\nlet c = C()\nfor _ in 0..<300000 { c.bump() }\nc.n"
    ),
    ("held member", "var s = Set<Int>()\nfor i in 0..<300000 { s.insert(i % 100) }\ns.count"),
    (
        "mixed",
        "var a: [Int] = []\nvar d: [Int: Int] = [:]\nfor i in 0..<50000 { a.append(i); d[i % 50] = a[i] }\nd.count"
    ),
]

private func seconds(_ source: String) throws -> Double {
    let host = Interpreter.Host(output: OutputSink({ _ in true }), error: OutputSink({ _ in true }))
    let interpreter = Interpreter(host: host, limits: Interpreter.Limits())
    let start = ContinuousClock.now
    _ = try interpreter.evaluate(source)
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIIT_TIMING"] != nil))
func timingOfThePathsTheTypeRecordTouches() throws {
    for (name, source) in scripts {
        let runs = try (0..<7).map { _ in try seconds(source) }.sorted()
        print("TIMING", name, String(format: "%.3f", runs[3]))
    }
}
