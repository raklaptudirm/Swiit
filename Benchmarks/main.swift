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
        name: "recursion, fib(30), statements",
        source: """
            func fib(_ n: Int) -> Int { if n < 2 { return n }; return fib(n - 1) + fib(n - 2) }
            fib(30)
            """
    ),
    Case(
        name: "loop in a function, 1.5M",
        source: """
            func run() -> Int { var s = 0; for i in 0..<1_500_000 { s += i % 7 }; return s }
            run()
            """
    ),
    Case(
        name: "fn: list append, 200k",
        source: """
            func run() -> Int { var xs: [Int] = []; for i in 0..<200_000 { xs.append(i * 2) }; return xs.count }
            run()
            """
    ),
    Case(
        name: "fn: mutating method, 200k",
        source: """
            struct P { var x = 0; mutating func inc() { x += 1 } }
            func run() -> Int { var p = P(); for _ in 0..<200_000 { p.inc() }; return p.x }
            run()
            """
    ),
    Case(
        name: "fn: method with arguments, 200k",
        source: """
            struct A { var k = 3; func add(_ x: Int, _ y: Int) -> Int { if x > y { return x + k }; return y + k } }
            func run() -> Int { let a = A(); var s = 0; for i in 0..<200_000 { s += a.add(i, 5) }; return s }
            run()
            """
    ),
    Case(
        name: "fn: initializer, 100k",
        source: """
            struct V { var x: Int; var y: Int; init(x: Int, y: Int) { self.x = x; self.y = y * 2 } }
            func run() -> Int { var s = 0; for i in 0..<100_000 { let v = V(x: i, y: 1); s += v.x + v.y }; return s }
            run()
            """
    ),
    Case(
        name: "fn: class method, 100k",
        source: """
            class C { var n = 0; func bump(_ by: Int) -> Int { n += by; return n } }
            func run() -> Int { let c = C(); var s = 0; for i in 0..<100_000 { s += c.bump(i % 3) }; return s }
            run()
            """
    ),
    Case(
        name: "fn: dictionary, 100k",
        source: """
            func run() -> Int {
                var d: [Int: Int] = [:]
                for i in 0..<100_000 { d[i % 1000, default: 0] += i }
                return d.count
            }
            run()
            """
    ),
    Case(
        name: "fn: string building, 50k",
        source: """
            func run() -> Int { var t = ""; for i in 0..<50_000 { t += "\\(i)," }; return t.count }
            run()
            """
    ),
    Case(
        name: "fn: member read, 200k",
        source: """
            struct P { var x = 1; var y = 2 }
            func run() -> Int { let p = P(); var s = 0; for _ in 0..<200_000 { s += p.x + p.y }; return s }
            run()
            """
    ),
    Case(
        name: "fn: member write, 200k",
        source: """
            struct P { var x = 1 }
            func run() -> Int { var p = P(); for i in 0..<200_000 { p.x = i }; return p.x }
            run()
            """
    ),
    Case(
        name: "fn: constructor, 200k",
        source: """
            struct P { var x: Int; var y: Int }
            func run() -> Int { var s = 0; for i in 0..<200_000 { let p = P(x: i, y: 2); s += i }; return s }
            run()
            """
    ),
    Case(
        name: "fn: method call, 200k",
        source: """
            struct P { var x = 1; func g() -> Int { 3 } }
            func run() -> Int { let p = P(); var s = 0; for _ in 0..<200_000 { s += p.g() }; return s }
            run()
            """
    ),
    Case(
        name: "fn: struct make and read, 200k",
        source: """
            struct P { var x: Int; var y: Int; func sum() -> Int { x + y } }
            func run() -> Int { var t = 0; for i in 0..<200_000 { let p = P(x: i, y: 1); t += p.sum() }; return t }
            run()
            """
    ),
    Case(
        name: "fn: map and filter, 200k",
        source: """
            func run(_ k: Int) -> Int { (0..<200_000).map { $0 * k }.filter { $0 % 2 == 0 }.count }
            run(3)
            """
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
