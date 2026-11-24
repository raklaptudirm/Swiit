import Testing

@testable import Swiit

// The VM runs what it compiles as the tree evaluator does (Docs/vm.md): the same values, output,
// diagnostics (kind, message, range, calls) and number of steps. Each test runs a program on both
// and compares everything observable, and checks that the function in question was compiled, so
// that a program that quietly stays on the tree evaluator does not pass for the VM.

private final class Log: @unchecked Sendable {
    var text = ""
}

private struct Outcome: Equatable {
    var value: String
    var failure: Diagnostic?
    var output: String
}

private func run(
    _ source: String,
    on engine: Engine,
    limits: Interpreter.Limits = .init()
)
    -> (outcome: Outcome, swiit: Interpreter)
{
    let log = Log()
    let swiit = Interpreter(
        host: Interpreter.Host(
            output: OutputSink({
                log.text += $0
                return true
            }),
            error: OutputSink({
                log.text += "err: " + $0
                return true
            })
        ),
        limits: limits
    )
    swiit.engine = engine
    do {
        let value = try swiit.evaluate(source)
        return (Outcome(value: value.description, failure: nil, output: log.text), swiit)
    } catch {
        return (Outcome(value: "", failure: error, output: log.text), swiit)
    }
}

/// The functions of the program named, which the VM must have compiled.
private func compiled(_ names: [String], in swiit: Interpreter) -> [String] {
    names.filter { name in
        guard case .function(let callable)? = swiit.lookup(name)?.value.storage else { return true }
        let function = (callable as? Function) ?? (callable as? OverloadSet)?.candidates.first
        if case .code? = function?.vmCode { return false }
        return true
    }
}

/// How many steps a program takes: the fewest that let it finish.
private func steps(_ source: String, on engine: Engine) -> Int {
    var low = 1
    var high = 1 << 20
    while low < high {
        let middle = (low + high) / 2
        if run(source, on: engine, limits: .init(maxSteps: middle)).outcome.failure == nil {
            high = middle
        } else {
            low = middle + 1
        }
    }
    return low
}

private struct Sample {
    let name: String
    let source: String
    /// The functions in it the compiler is expected to take.
    let compiles: [String]
}

private let programs: [Sample] = [
    Sample(
        name: "fib",
        source: """
            func fib(_ n: Int) -> Int { if n < 2 { return n }; return fib(n - 1) + fib(n - 2) }
            fib(15)
            """,
        compiles: ["fib"]
    ),
    Sample(
        name: "a for over a range",
        source: """
            func sum(_ n: Int) -> Int { var s = 0; for i in 0..<n { s += i % 7 }; return s }
            sum(100) + sum(0)
            """,
        compiles: ["sum"]
    ),
    Sample(
        name: "a closed range, and a wildcard",
        source: """
            func count(_ n: Int) -> Int { var c = 0; for _ in 1...n { c += 1 }; return c }
            count(10)
            """,
        compiles: ["count"]
    ),
    Sample(
        name: "while, break and continue",
        source: """
            func f(_ n: Int) -> Int {
                var i = 0
                var t = 0
                while i < n {
                    i += 1
                    if i % 2 == 0 { continue }
                    if i > 50 { break }
                    t += i
                }
                return t
            }
            f(100)
            """,
        compiles: ["f"]
    ),
    Sample(
        name: "repeat while",
        source: """
            func g(_ n: Int) -> Int { var i = 0; repeat { i += 3 } while i < n; return i }
            g(10)
            """,
        compiles: ["g"]
    ),
    Sample(
        name: "labels",
        source: """
            func grid() -> Int {
                var seen = 0
                outer: for i in 0..<5 {
                    for j in 0..<5 {
                        if j == 3 { continue outer }
                        if i == 3 { break outer }
                        seen += 1
                    }
                }
                return seen
            }
            grid()
            """,
        compiles: ["grid"]
    ),
    Sample(
        name: "doubles and mixed arithmetic",
        source: """
            func area(_ r: Double) -> Double { return 3.5 * r * r }
            func half(_ n: Int) -> Double { return Double(n) / 2 }
            area(2.0)
            """,
        compiles: ["area"]
    ),
    Sample(
        name: "boolean operators and a default",
        source: """
            func g(_ a: Int, _ b: Int) -> Bool { return a > 1 && b < 3 || a == b }
            func pick(_ x: Int?) -> Int { return x ?? 7 }
            [g(2, 1), g(0, 0), g(1, 5)].count + pick(nil) + pick(3)
            """,
        compiles: ["g", "pick"]
    ),
    Sample(
        name: "a declared type",
        source: """
            func h() -> Double { let x: Double = 1; return x + 2.5 }
            h()
            """,
        compiles: ["h"]
    ),
    Sample(
        name: "blocks and shadowing",
        source: """
            func sh() -> Int { let x = 1; var r = 0; if x == 1 { let x = 5; r = x }; return r + x }
            sh()
            """,
        compiles: ["sh"]
    ),
    Sample(
        name: "mutual recursion",
        source: """
            func even(_ n: Int) -> Bool { if n == 0 { return true }; return odd(n - 1) }
            func odd(_ n: Int) -> Bool { if n == 0 { return false }; return even(n - 1) }
            even(10)
            """,
        compiles: ["even", "odd"]
    ),
    Sample(
        name: "labels that fit",
        source: """
            func lab(a x: Int, _ y: Int) -> Int { x * y }
            lab(a: 3, 4)
            """,
        compiles: ["lab"]
    ),
    Sample(
        name: "calls the VM does not make itself",
        source: """
            func shout(_ s: String) -> String { return s + "!" }
            func twice(_ n: Int) -> Int { return max(n, 3) + abs(n - 9) }
            struct P { var x: Int }
            func make(_ n: Int) -> Int { return P(x: n).x }
            shout("a") + String(twice(5)) + String(make(4))
            """,
        compiles: ["shout", "twice"]
    ),
    Sample(
        name: "a closure called by name",
        source: """
            let add = { (a: Int, b: Int) in a + b }
            func use() -> Int { return add(1, 2) }
            use()
            """,
        compiles: ["use"]
    ),
    Sample(
        name: "output from a function that stays on the tree",
        source: """
            func noisy(_ n: Int) { print("n is \\(n)") }
            func quiet(_ n: Int) -> Int { noisy(n); return n + 1 }
            quiet(4)
            """,
        compiles: []
    ),
]

@Test(arguments: programs)
private func aProgramGivesTheSameOnBothEngines(_ program: Sample) {
    let tree = run(program.source, on: .tree)
    let vm = run(program.source, on: .vm)
    #expect(vm.outcome == tree.outcome, "\(program.name)")
    #expect(
        tree.outcome.failure == nil,
        "\(program.name) failed: \(String(describing: tree.outcome.failure))"
    )
    #expect(compiled(program.compiles, in: vm.swiit) == [], "\(program.name) was not compiled")
}

@Test(arguments: programs)
private func aProgramTakesTheSameStepsOnBothEngines(_ program: Sample) {
    #expect(steps(program.source, on: .vm) == steps(program.source, on: .tree), "\(program.name)")
}

private let failing: [Sample] = [
    Sample(
        name: "an error two calls down",
        source: """
            func d(_ x: Int) -> Int { return 10 / x }
            func e(_ x: Int) -> Int { let y = d(x); return y + 1 }
            e(0)
            """,
        compiles: ["d", "e"]
    ),
    Sample(
        name: "overflow",
        source: """
            func big(_ n: Int) -> Int { return n * 9223372036854775807 }
            big(3)
            """,
        compiles: ["big"]
    ),
    Sample(
        name: "runaway recursion",
        source: """
            func inf(_ n: Int) -> Int { return inf(n + 1) }
            inf(0)
            """,
        compiles: ["inf"]
    ),
    Sample(
        name: "an error in a loop's condition",
        source: """
            func loop(_ n: Int) -> Int {
                var i = 0
                while 10 / (n - i) > 0 { i += 1 }
                return i
            }
            loop(3)
            """,
        compiles: ["loop"]
    ),
    Sample(
        name: "a failing call among several statements",
        source: """
            func unsafe(_ x: Int) -> Int { return 100 % x }
            func run(_ x: Int) -> Int {
                var total = 0
                for i in 0..<3 {
                    total += unsafe(x - i)
                }
                return total
            }
            run(2)
            """,
        compiles: ["unsafe", "run"]
    ),
    Sample(
        name: "a short body that fails",
        source: """
            func short(_ x: Int) -> Int { 10 / x }
            func caller(_ x: Int) -> Int { let y = short(x); return y }
            caller(0)
            """,
        compiles: ["short", "caller"]
    ),
]

@Test(arguments: failing)
private func anErrorIsReportedAsOnTheTreeEvaluator(_ program: Sample) {
    let tree = run(program.source, on: .tree)
    let vm = run(program.source, on: .vm)
    #expect(tree.outcome.failure != nil, "\(program.name) did not fail on the tree evaluator")
    #expect(vm.outcome == tree.outcome, "\(program.name)")
    #expect(compiled(program.compiles, in: vm.swiit) == [], "\(program.name) was not compiled")
}

@Test func theVMNeedsNoSwiftStackForDepth() throws {
    // A recursion far past what the call limit allows the tree evaluator on a small stack is
    // counted by frames, and ends with the same error.
    let source = """
        func down(_ n: Int) -> Int { if n == 0 { return 0 }; return down(n - 1) + 1 }
        down(900)
        """
    let vm = run(source, on: .vm)
    #expect(vm.outcome.value == "900")
}
