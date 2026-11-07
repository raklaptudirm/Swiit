import Foundation
import Swiit

// How long Swiit takes on small programs that each stress one part of it: run with
// `swift run -c release swiit-benchmarks`, and compare before and after a change. Each case runs
// in a new interpreter, and the best of the runs is shown, which is the least disturbed by the
// machine.

struct Case {
    let name: String
    let source: String
    var limits = Interpreter.Limits()
}

let cases = [
    Case(name: "loop, 1M additions", source: "var s = 0\nfor i in 0..<1_000_000 { s += i }\ns"),
    Case(
        name: "loop under a time limit",
        source: "var s = 0\nfor i in 0..<1_000_000 { s += i }\ns",
        limits: Interpreter.Limits(timeLimit: .seconds(60))
    ),
    Case(name: "while, 1M steps", source: "var i = 0\nwhile i < 1_000_000 { i += 1 }\ni"),
    Case(
        name: "recursion, fib(24)",
        source: "func fib(_ n: Int) -> Int { n < 2 ? n : fib(n - 1) + fib(n - 2) }\nfib(24)"
    ),
    Case(
        name: "list append, 200k",
        source: "var xs: [Int] = []\nfor i in 0..<200_000 { xs.append(i * 2) }\nxs.reduce(0, +)"
    ),
    Case(
        name: "closures, map/filter 200k",
        source: "(0..<200_000).map { $0 * 3 }.filter { $0 % 2 == 0 }.count"
    ),
    Case(
        name: "string building, 50k",
        source: #"var t = ""\#nfor i in 0..<50_000 { t += "\(i)," }\#nt.count"#
    ),
    Case(
        name: "mutating method, 200k",
        source: """
            struct P { var x = 0; mutating func inc() { x += 1 } }
            var p = P()
            for _ in 0..<200_000 { p.inc() }
            p.x
            """
    ),
    Case(
        name: "dictionary, 100k",
        source:
            "var d: [Int: Int] = [:]\nfor i in 0..<100_000 { d[i % 1000, default: 0] += i }\nd.count"
    ),
    Case(
        name: "bridged calls, 100k",
        source: "var n = 0\nfor i in 0..<100_000 { n += String(i).count }\nn"
    ),
]

let runs = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 5
let filter = CommandLine.arguments.dropFirst(2).first

func interpreter(_ limits: Interpreter.Limits) -> Interpreter {
    let discard = OutputSink({ _ in true })
    return Interpreter(host: Interpreter.Host(output: discard, error: discard), limits: limits)
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

let clock = ContinuousClock()
let startup = clock.measure { _ = try? interpreter(Interpreter.Limits()).evaluate("1") }
print(String(format: "%-28@ %9.2f ms", "startup, then 1" as NSString, milliseconds(startup)))

for benchmark in cases where filter.map({ benchmark.name.contains($0) }) ?? true {
    var best = Duration.seconds(Int64.max)
    var result = ""
    for _ in 0..<runs {
        let swiit = interpreter(benchmark.limits)
        let time = clock.measure {
            do { result = "\(try swiit.evaluate(benchmark.source))" } catch { result = "\(error)" }
        }
        best = min(best, time)
    }
    print(
        String(
            format: "%-28@ %9.2f ms   %@",
            benchmark.name as NSString,
            milliseconds(best),
            result as NSString
        )
    )
}
