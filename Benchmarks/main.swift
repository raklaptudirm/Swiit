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
    /// The host is told each statement as it finishes, as a shell's is.
    var observed = false
}

let cases = [
    Case(
        name: "native: String.count, 100k",
        source: """
            func run() -> Int { let s = "hello, world"; var n = 0; for _ in 0..<100_000 { n += s.count }; return n }
            run()
            """
    ),
    Case(
        name: "native: String.isEmpty, 100k",
        source: """
            func run() -> Int { let s = "hello"; var n = 0; for _ in 0..<100_000 { if !s.isEmpty { n += 1 } }; return n }
            run()
            """
    ),
    Case(
        name: "native: Array.first, 100k",
        source: """
            func run() -> Int { let xs = [3, 1, 2]; var n = 0; for _ in 0..<100_000 { n += xs.first ?? 0 }; return n }
            run()
            """
    ),
    Case(
        name: "native: Array.max(), 100k",
        source: """
            func run() -> Int { let xs = [3, 1, 2]; var n = 0; for _ in 0..<100_000 { n += xs.max() ?? 0 }; return n }
            run()
            """
    ),
    Case(
        name: "native: String.hasPrefix, 100k",
        source: """
            func run() -> Int { let s = "hello"; var n = 0; for _ in 0..<100_000 { if s.hasPrefix("he") { n += 1 } }; return n }
            run()
            """
    ),
    Case(
        name: "native: Array.contains(x), 100k",
        source: """
            func run() -> Int { let xs = [3, 1, 2]; var n = 0; for i in 0..<100_000 { if xs.contains(i % 4) { n += 1 } }; return n }
            run()
            """
    ),
    Case(
        name: "native: max(a, b), 100k",
        source: """
            func run() -> Int { var n = 0; for i in 0..<100_000 { n += max(i % 7, 3) }; return n }
            run()
            """
    ),
    Case(
        name: "native: Int(String), 100k",
        source: """
            func run() -> Int { var n = 0; for _ in 0..<100_000 { n += Int("42") ?? 0 }; return n }
            run()
            """
    ),
    Case(
        name: "native: String(Int), 100k",
        source: """
            func run() -> Int { var n = 0; for i in 0..<100_000 { n += String(i).count }; return n }
            run()
            """
    ),
    Case(
        name: "native: Int.max, 100k",
        source: """
            func run() -> Int { var n = 0; for _ in 0..<100_000 { if Int.max > 0 { n += 1 } }; return n }
            run()
            """
    ),
    Case(
        name: "native: String.uppercased(), 100k",
        source: """
            func run() -> Int { let s = "hello"; var n = 0; for _ in 0..<100_000 { n += s.uppercased().count }; return n }
            run()
            """
    ),
    Case(
        name: "native: String.split, 100k",
        source: """
            func run() -> Int { let s = "a,b,c"; var n = 0; for _ in 0..<100_000 { n += s.split(separator: ",").count }; return n }
            run()
            """
    ),
    Case(
        name: "native: map { $0 * 2 }, 100k",
        source: """
            func run() -> Int { let xs = Array(0..<100_000); return xs.map { $0 * 2 }.count }
            run()
            """
    ),
    Case(
        name: "native: map { String($0) }, 100k",
        source: """
            func run() -> Int { let xs = Array(0..<100_000); return xs.map { String($0) }.count }
            run()
            """
    ),
    Case(
        name: "native: filter, 100k",
        source: """
            func run() -> Int { let xs = Array(0..<100_000); return xs.filter { $0 % 3 == 0 }.count }
            run()
            """
    ),
    Case(
        name: "native: reduce, 100k",
        source: """
            func run() -> Int { let xs = Array(0..<100_000); return xs.reduce(0) { $0 + $1 } }
            run()
            """
    ),
    Case(
        name: "native: sorted(by:), 20k",
        source: """
            func run() -> Int { let xs = (0..<20_000).map { ($0 * 7919) % 20_011 }; return xs.sorted { $0 > $1 }.count }
            run()
            """
    ),
    Case(
        name: "native: contains(where:), 100k",
        source: """
            func run() -> Int { let xs = Array(0..<100_000); return xs.contains { $0 == -1 } ? 1 : 0 }
            run()
            """
    ),
    Case(
        name: "col: build dict 100k",
        source: """
            func run() -> Int { var d: [Int: Int] = [:]; for i in 0..<100_000 { d[i] = i }; return d.count }
            run()
            """
    ),
    Case(
        name: "col: build Array(0..<300k)",
        source: "func run() -> Int { let xs = Array(0..<300_000); return xs.count }\nrun()"
    ),
    Case(
        name: "col: build by append 300k",
        source: """
            func run() -> Int { var xs: [Int] = []; for i in 0..<300_000 { xs.append(i) }; return xs.count }
            run()
            """
    ),
    Case(
        name: "col: build by map 300k",
        source: "func run() -> Int { let xs = (0..<300_000).map { $0 }; return xs.count }\nrun()"
    ),
    Case(
        name: "col: for x in xs, 300k",
        source: """
            func run() -> Int { let xs = Array(0..<300_000); var s = 0; for x in xs { s += x }; return s }
            run()
            """
    ),
    Case(
        name: "col: counts[k, default: 0] += 1, 200k",
        source: """
            func run() -> Int { var d: [Int: Int] = [:]; for i in 0..<200_000 { d[i % 1000, default: 0] += 1 }; return d.count }
            run()
            """
    ),
    Case(
        name: "col: xs += [i], 100k",
        source: """
            func run() -> Int { var xs: [Int] = []; for i in 0..<100_000 { xs += [i] }; return xs.count }
            run()
            """
    ),
    Case(
        name: "col: for (k, v) in d, 100k",
        source: """
            func run() -> Int { var d: [Int: Int] = [:]; for i in 0..<100_000 { d[i] = i }; var s = 0; for (k, v) in d { s += k + v }; return s }
            run()
            """
    ),
    Case(
        name: "col: sorted, 100k",
        source: """
            func run() -> Int { var xs: [Int] = []; for i in 0..<100_000 { xs.append((i * 7919) % 100_003) }; return xs.sorted().count }
            run()
            """
    ),
    Case(
        name: "col: joined, 50k",
        source: """
            func run() -> Int { let xs = Array(0..<50_000); return xs.map { String($0) }.joined(separator: ",").count }
            run()
            """
    ),
    Case(
        name: "col: map String, 50k",
        source: """
            func run() -> Int { let xs = Array(0..<50_000); return xs.map { String($0) }.count }
            run()
            """
    ),
    Case(
        name: "col: joined strings, 50k",
        source: """
            func run() -> Int { let xs = (0..<50_000).map { "a" }; return xs.joined(separator: ",").count }
            run()
            """
    ),
    Case(
        name: "col: String(i) in a loop, 50k",
        source: """
            func run() -> Int { var n = 0; for i in 0..<50_000 { n += String(i).count }; return n }
            run()
            """
    ),
    Case(
        name: "col: Int.description in a loop, 50k",
        source: """
            func run() -> Int { var n = 0; for i in 0..<50_000 { n += i.description.count }; return n }
            run()
            """
    ),
    Case(
        name: "col: grid[i][j] += 1, 300x300",
        source: """
            func run() -> Int { var g = Array(repeating: Array(repeating: 0, count: 300), count: 300); for i in 0..<300 { for j in 0..<300 { g[i][j] += i + j } }; return g[299][299] }
            run()
            """
    ),
    Case(
        name: "col: xs[i] reads, 300k",
        source: """
            func run() -> Int { let xs = Array(0..<300_000); var s = 0; for i in 0..<300_000 { s += xs[i] }; return s }
            run()
            """
    ),
    Case(
        name: "fn: print, 100k",
        source: "func run() { for i in 0..<100_000 { print(i, \"x\") } }\nrun()"
    ),
    Case(
        name: "fn: struct field update, 200k",
        source: """
            struct P { var x = 0; var y = 0 }
            func run() -> Int { var p = P(); for _ in 1...200_000 { p.x += 1; p.y = p.x }; return p.y }
            run()
            """
    ),
    Case(
        name: "closed range loop in a function, 1M",
        source: "func f() -> Int { var s = 0; for i in 1...1_000_000 { s += i }; return s }\nf()"
    ),
    Case(
        name: "observed: loop in a function, 1.5M",
        source: """
            func run() -> Int { var s = 0; for i in 0..<1_500_000 { s += i % 7 }; return s }
            run()
            """,
        observed: true
    ),
    Case(
        name: "observed: fib(30), statements",
        source: """
            func fib(_ n: Int) -> Int { if n < 2 { return n }; return fib(n - 1) + fib(n - 2) }
            fib(30)
            """,
        observed: true
    ),
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
        name: "fn: initializer only, 100k",
        source: """
            struct V { var x: Int; var y: Int; init(x: Int, y: Int) { self.x = x; self.y = y * 2 } }
            func run() -> Int { var s = 0; for i in 0..<100_000 { let v = V(x: i, y: 1); s += i }; return s }
            run()
            """
    ),
    Case(
        name: "fn: empty initializer, 100k",
        source: """
            struct V { var x = 1; init() { } }
            func run() -> Int { var s = 0; for i in 0..<100_000 { let v = V(); s += i }; return s }
            run()
            """
    ),
    Case(
        name: "fn: class empty initializer, 100k",
        source: """
            class D { var x = 1; init() { } }
            func run() -> Int { var s = 0; for i in 0..<100_000 { let v = D(); s += i }; return s }
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
        name: "fn: method reading self, 200k",
        source: """
            struct P { var x: Int; var y: Int; func sum() -> Int { x + y } }
            func run() -> Int { let p = P(x: 1, y: 2); var t = 0; for _ in 0..<200_000 { t += p.sum() }; return t }
            run()
            """
    ),
    Case(
        name: "fn: class constructor, 100k",
        source: """
            class D { var a: Int; var b = 2; init(a: Int) { self.a = a } }
            func run() -> Int { var s = 0; for i in 0..<100_000 { let d = D(a: i); s += d.a + d.b }; return s }
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

// safe: touched by the one thread that runs the benchmark
final class StatusBox: @unchecked Sendable { var count = 0 }

func interpreter(_ limits: Interpreter.Limits, observed: Bool = false) -> Interpreter {
    let discard = OutputSink({ _ in true })
    var host = Interpreter.Host(output: discard, error: discard)
    if observed {
        let box = StatusBox()
        host.didFinishStatement = { value, caught in
            box.count += (value == nil ? 0 : 1) + (caught ? 1 : 0)
        }
    }
    return Interpreter(host: host, limits: limits)
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
        let swiit = interpreter(benchmark.limits, observed: benchmark.observed)
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
