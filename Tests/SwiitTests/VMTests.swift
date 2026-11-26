import Testing

@testable import Swiit

// The VM runs what it compiles as the tree evaluator does (Docs/vm.md): the same values, output,
// diagnostics (kind, message, range, calls) and number of steps. Each test runs a program on both
// and compares everything observable, and checks that the function in question was compiled, so
// that a program that quietly stays on the tree evaluator does not pass for the VM.

private let programs: [VMSample] = [
    VMSample(
        name: "fib",
        source: """
            func fib(_ n: Int) -> Int { if n < 2 { return n }; return fib(n - 1) + fib(n - 2) }
            fib(15)
            """,
        compiles: ["fib"]
    ),
    VMSample(
        name: "a for over a range",
        source: """
            func sum(_ n: Int) -> Int { var s = 0; for i in 0..<n { s += i % 7 }; return s }
            sum(100) + sum(0)
            """,
        compiles: ["sum"]
    ),
    VMSample(
        name: "a closed range, and a wildcard",
        source: """
            func count(_ n: Int) -> Int { var c = 0; for _ in 1...n { c += 1 }; return c }
            count(10)
            """,
        compiles: ["count"]
    ),
    VMSample(
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
    VMSample(
        name: "repeat while",
        source: """
            func g(_ n: Int) -> Int { var i = 0; repeat { i += 3 } while i < n; return i }
            g(10)
            """,
        compiles: ["g"]
    ),
    VMSample(
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
    VMSample(
        name: "doubles and mixed arithmetic",
        source: """
            func area(_ r: Double) -> Double { return 3.5 * r * r }
            func half(_ n: Int) -> Double { return Double(n) / 2 }
            area(2.0)
            """,
        compiles: ["area"]
    ),
    VMSample(
        name: "boolean operators and a default",
        source: """
            func g(_ a: Int, _ b: Int) -> Bool { return a > 1 && b < 3 || a == b }
            func pick(_ x: Int?) -> Int { return x ?? 7 }
            [g(2, 1), g(0, 0), g(1, 5)].count + pick(nil) + pick(3)
            """,
        compiles: ["g", "pick"]
    ),
    VMSample(
        name: "a declared type",
        source: """
            func h() -> Double { let x: Double = 1; return x + 2.5 }
            h()
            """,
        compiles: ["h"]
    ),
    VMSample(
        name: "blocks and shadowing",
        source: """
            func sh() -> Int { let x = 1; var r = 0; if x == 1 { let x = 5; r = x }; return r + x }
            sh()
            """,
        compiles: ["sh"]
    ),
    VMSample(
        name: "mutual recursion",
        source: """
            func even(_ n: Int) -> Bool { if n == 0 { return true }; return odd(n - 1) }
            func odd(_ n: Int) -> Bool { if n == 0 { return false }; return even(n - 1) }
            even(10)
            """,
        compiles: ["even", "odd"]
    ),
    VMSample(
        name: "labels that fit",
        source: """
            func lab(a x: Int, _ y: Int) -> Int { x * y }
            lab(a: 3, 4)
            """,
        compiles: ["lab"]
    ),
    VMSample(
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
    VMSample(
        name: "a closure called by name",
        source: """
            let add = { (a: Int, b: Int) in a + b }
            func use() -> Int { return add(1, 2) }
            use()
            """,
        compiles: ["use"]
    ),
    VMSample(
        name: "output from a function that stays on the tree",
        source: """
            func noisy(_ n: Int) { print("n is \\(n)") }
            func quiet(_ n: Int) -> Int { noisy(n); return n + 1 }
            quiet(4)
            """,
        compiles: []
    ),
]

/// The programs of every file, which one test runs on both engines.
private let everyProgram: [VMSample] = [
    programs, vmControlFlow, vmMoreControlFlow, vmClosures, vmRuntimeNodes, vmKinds,
    vmParameterKinds, vmAsync, vmTopLevel, vmFastMembers, vmStructMembers, vmClasses, vmEntered,
    vmCallbacks, vmExpressions,
]
.flatMap { $0 }

@Test(arguments: everyProgram)
private func aProgramGivesTheSameOnBothEngines(_ program: VMSample) {
    let tree = vmRun(program.source, on: .tree)
    let vm = vmRun(program.source, on: .vm)
    #expect(vm.outcome == tree.outcome, "\(program.name)")
    #expect(
        tree.outcome.failure == nil,
        "\(program.name) failed: \(String(describing: tree.outcome.failure))"
    )
    let missed = vmCompiled(program.compiles, in: vm.swiit)
    #expect(missed == [], "\(program.name) was not compiled: \(missed)")
    #expect(
        vm.swiit.vmLoops == program.loops,
        "\(program.name) ran \(vm.swiit.vmLoops) loops compiled"
    )
    if let runs = program.treeRuns {
        #expect(
            vm.swiit.vmTreeRuns == runs,
            "\(program.name) ran \(vm.swiit.vmTreeRuns) tree nodes, not \(runs)"
        )
    }
    if let trees = program.trees {
        let left = vmTreeNodes(program.compiles, in: vm.swiit)
        #expect(left == trees, "\(program.name) left \(left) nodes to the tree, not \(trees)")
    }
    if program.entirely {
        #expect(
            vm.swiit.vmFallbacks == [],
            "\(program.name) left functions to the tree: \(vm.swiit.vmFallbacks)"
        )
    }
}

@Test(arguments: everyProgram)
private func aProgramTakesTheSameStepsOnBothEngines(_ program: VMSample) {
    #expect(
        vmSteps(program.source, on: .vm) == vmSteps(program.source, on: .tree),
        "\(program.name)"
    )
}

private let failing: [VMSample] = [
    VMSample(
        name: "an error in a class's method frame the loop made, after the site was warm",
        source: """
            class K { var k = 10; func div(_ n: Int) -> Int { k / n } }
            func f() -> Int {
                let c = K()
                var t = 0
                for i in 0..<5 { t += c.div(2 - i) }
                return t
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an error in a method frame the loop made, after the site was warm",
        source: """
            struct D { var k = 10; func div(_ n: Int) -> Int { k / n } }
            func f() -> Int {
                let d = D()
                var t = 0
                for i in 0..<5 { t += d.div(2 - i) }
                return t
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an assignment through an index out of range, from a value that reads",
        source: """
            struct P { var xs = [1, 2, 3] }
            func f(_ n: Int) -> Int {
                var p = P()
                let ys = [4, 5, 6]
                p.xs[n] = ys[1] + p.xs[0]
                return p.xs[0]
            }
            f(7)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a path with an index out of range",
        source: """
            func f(_ n: Int) -> Int {
                var grid = [[1, 2], [3, 4]]
                grid[1][n] = 9
                return grid[1][0]
            }
            f(5)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a force unwrap of nil, and a failed forced cast",
        source: """
            func f(_ n: Int) -> Int {
                let maybe: Int? = n > 2 ? n : nil
                return maybe! + 1
            }
            f(1)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a forced cast that fails",
        source: """
            func f(_ n: Int) -> String {
                let any: Any = n
                return any as! String
            }
            f(1)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an error two calls down",
        source: """
            func d(_ x: Int) -> Int { return 10 / x }
            func e(_ x: Int) -> Int { let y = d(x); return y + 1 }
            e(0)
            """,
        compiles: ["d", "e"]
    ),
    VMSample(
        name: "overflow",
        source: """
            func big(_ n: Int) -> Int { return n * 9223372036854775807 }
            big(3)
            """,
        compiles: ["big"]
    ),
    VMSample(
        name: "runaway recursion",
        source: """
            func inf(_ n: Int) -> Int { return inf(n + 1) }
            inf(0)
            """,
        compiles: ["inf"]
    ),
    VMSample(
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
    VMSample(
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
    VMSample(
        name: "a short body that fails",
        source: """
            func short(_ x: Int) -> Int { 10 / x }
            func caller(_ x: Int) -> Int { let y = short(x); return y }
            caller(0)
            """,
        compiles: ["short", "caller"]
    ),
]

private let everyFailingProgram: [VMSample] = [
    failing, vmFailingControlFlow, vmFailingClosures, vmFailingRuntimeNodes, vmFailingKinds,
    vmAsyncFailing, vmFailingTopLevel, vmFailingFastMembers, vmFailingStructMembers,
    vmFailingClasses, vmFailingCallbacks, vmFailingCollections,
]
.flatMap { $0 }

@Test(arguments: everyFailingProgram)
private func anErrorIsReportedAsOnTheTreeEvaluator(_ program: VMSample) {
    let tree = vmRun(program.source, on: .tree)
    let vm = vmRun(program.source, on: .vm)
    #expect(tree.outcome.failure != nil, "\(program.name) did not fail on the tree evaluator")
    #expect(vm.outcome == tree.outcome, "\(program.name)")
    #expect(vm.swiit.vmLoops == program.loops, "\(program.name) ran \(vm.swiit.vmLoops) loops")
    let missed = vmCompiled(program.compiles, in: vm.swiit)
    #expect(
        missed == [],
        "\(program.name) was not compiled: \(missed); it failed with \(tree.outcome.failure ?? "")"
    )
}

@Test func theVMNeedsNoSwiftStackForDepth() throws {
    // A recursion far past what the call limit allows the tree evaluator on a small stack is
    // counted by frames, and ends with the same error.
    let source = """
        func down(_ n: Int) -> Int { if n == 0 { return 0 }; return down(n - 1) + 1 }
        down(900)
        """
    let vm = vmRun(source, on: .vm)
    #expect(vm.outcome.value == "900")
}

@Test func changingACollectionInAFunctionDoesNotCopyIt() {
    // Each change moves the collection out of its register into the frame the tree evaluator runs
    // over, and back: if it were copied each time, 40 000 appends would take minutes.
    let source = """
        func build(_ n: Int) -> Int {
            var xs: [Int] = []
            var d: [Int: Int] = [:]
            for i in 0..<n { xs.append(i); d[i % 100, default: 0] += 1 }
            return xs.count + d.count
        }
        build(40000)
        """
    let start = ContinuousClock.now
    let result = vmRun(source, on: .vm)
    #expect(result.outcome.value == "40100")
    #expect(ContinuousClock.now - start < .seconds(10), "took \(ContinuousClock.now - start)")
    #expect(vmCompiled(["build"], in: result.swiit) == [])
}

/// A call the loop makes itself is a frame of the loop, not a run of it on Swift's stack, which is
/// what a task needs to be parked: the loop is entered once for these, from the program's call of `f`.
@Test(arguments: vmEntered)
private func aCallOfTheLoopIsNotANestedRun(_ program: VMSample) {
    let vm = vmRun(program.source, on: .vm)
    #expect(vm.outcome.failure == nil, "\(program.name) failed: \(vm.outcome.failure ?? "")")
    #expect(vm.swiit.vmEntries == 1, "\(program.name) entered the VM \(vm.swiit.vmEntries) times")
}
