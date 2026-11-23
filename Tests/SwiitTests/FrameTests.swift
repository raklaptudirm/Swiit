import Testing

@testable import Swiit

// Locals in frames (`FrameResolver`): what a body given a frame must do as one run by name did.

private func run(_ source: String) throws -> String {
    let output = OutputBox()
    let swiit = Interpreter(
        host: Interpreter.Host(
            output: OutputSink({
                output.text += $0; return true
            }),
            error: OutputSink({ _ in true })
        ),
        limits: Interpreter.Limits()
    )
    _ = try onLargeStack { try swiit.evaluate(source) }
    return output.text
}

private final class OutputBox: @unchecked Sendable {
    var text = ""
}

@Test func anInnerLocalShadowsAnOuterOneUntilItsBlockEnds() throws {
    let source = """
        func f() {
            let x = 1
            if true {
                let x = 2
                print(x)
            }
            print(x)
            for x in 3...3 { print(x) }
            print(x)
        }
        f()
        """
    #expect(try run(source) == "2\n1\n3\n1\n")
}

@Test func blocksSideBySideHaveTheirOwnLocals() throws {
    let source = """
        func f() -> Int {
            var total = 0
            if true { let a = 10; total += a }
            if true { let b = 5; total += b }
            return total
        }
        print(f())
        """
    #expect(try run(source) == "15\n")
}

@Test func aClosureMadeInALoopKeepsThatIterationsVariable() throws {
    let source = """
        func f() -> [Int] {
            var made: [() -> Int] = []
            for i in 0..<3 { let j = i * 10; made.append { i + j } }
            return made.map { $0() }
        }
        print(f())
        var top: [() -> Int] = []
        for i in 0..<3 { top.append { i } }
        print(top.map { $0() })
        """
    #expect(try run(source) == "[0, 11, 22]\n[0, 1, 2]\n")
}

@Test func aClosureSharesTheVariableItCaptures() throws {
    let source = """
        func counter() -> () -> Int {
            var n = 0
            let next = { n += 1; return n }
            n = 10
            return next
        }
        let c = counter()
        print(c(), c())
        """
    #expect(try run(source) == "11 12\n")
}

@Test func whatAnExpressionBindsShadowsTheFrame() throws {
    let source = """
        func f(_ o: Int?) -> Int {
            let x = 1
            let y = if let x = o { x * 100 } else { x }
            switch o {
            case let x? where x > 2: return y + x
            default: return y
            }
        }
        print(f(3), f(nil))
        """
    #expect(try run(source) == "303 1\n")
}

@Test func catchAndDeferSeeTheirLocals() throws {
    let source = """
        struct E: Error {}
        func f() {
            let label = "done"
            defer { let tail = "!"; print(label + tail) }
            do { throw E() } catch { let what = "caught"; print(what, error) }
        }
        f()
        """
    #expect(try run(source) == "caught E()\ndone!\n")
}

@Test func eachCallHasItsOwnFrame() throws {
    let source = """
        func fact(_ n: Int) -> Int {
            let here = n
            if here <= 1 { return 1 }
            let below = fact(here - 1)
            return here * below
        }
        print(fact(6))
        """
    #expect(try run(source) == "720\n")
}

@Test func aDefaultArgumentDoesNotSeeItsCallersLocals() throws {
    let source = """
        let x = 1
        func f(_ v: Int = x) -> Int { v }
        func g() -> Int { let x = 99; return f() }
        print(g())
        """
    #expect(try run(source) == "1\n")
}

@Test func aBodyWithALocalFunctionRunsByName() throws {
    let source = """
        func f(_ o: Int?) -> Int {
            guard let v = o else { return 0 }
            func twice(_ n: Int) -> Int { n * 2 }
            let r = twice(v)
            return r
        }
        print(f(4), f(nil))
        """
    #expect(try run(source) == "8 0\n")
}

@Test func aLocalIsChangedInPlace() throws {
    let source = """
        func f() -> [Int] {
            var xs = [1, 2]
            if true { var ys = xs; ys.append(3); xs = ys }
            xs[0] = 9
            xs += [4]
            return xs
        }
        print(f())
        """
    #expect(try run(source) == "[9, 2, 3, 4]\n")
}

@Test func parametersLiveInTheFrame() throws {
    let source = """
        func bump(_ x: inout Int, by step: Int) { x += step }
        var n = 1
        bump(&n, by: 4)
        func shadow(_ v: Int) -> Int { if true { let v = v * 10; return v }; return 0 }
        func adder(_ base: Int) -> (Int) -> Int { { base + $0 } }
        func pick<T>(_ a: T, _ b: T, first: Bool) -> T { first ? a : b }
        struct S { var k = 2; func times(_ m: Int) -> Int { k * m } }
        func ignore(_: Int, _ kept: Int) -> Int { kept }
        print(n, shadow(3), adder(5)(6), pick("a", "b", first: false), S().times(7), ignore(1, 2))
        """
    #expect(try run(source) == "5 30 11 b 14 2\n")
}

@Test func aLocalCapturedLaterIsTheSameVariable() throws {
    let source = """
        func bump(_ v: inout Int) { v += 100 }
        func f() -> [Int] {
            var x = 1
            x = { x + 10 }()
            var y = 2
            let read = { y }
            y = 3
            var z = 4
            bump(&z)
            var w = 5
            w += { w }()
            return [x, read(), y, z, w]
        }
        print(f())
        """
    #expect(try run(source) == "[11, 3, 3, 104, 10]\n")
}

// A guard's bindings live in slots too, so a body with one is still given a frame.

@Test func aBodyWithAGuardIsGivenAFrame() throws {
    let swiit = Interpreter()
    let source = """
        func f(_ o: Int?) -> Int {
            guard let v = o else { return 0 }
            while let w = Optional(v), w < 0 { break }
            return v
        }
        """
    guard case .success(let program) = swiit.parse(source),
        case .function(let decl)? = FrameResolver.resolve(program: program).statements.first
    else {
        Issue.record("the source did not read as a function")
        return
    }
    #expect(decl.body.frameSize != nil)
}

@Test func whatAGuardBindsLivesForTheRestOfItsBlock() throws {
    let source = """
        func f(_ o: Int?, _ p: Int?) -> Int {
            guard let a = o else { return -1 }
            guard let b = p, b > 0 else { return -2 }
            return a + b
        }
        print(f(1, 2), f(nil, 2), f(1, nil), f(1, 0))
        """
    #expect(try run(source) == "3 -1 -2 -2\n")
}

@Test func aGuardMayShadowAnOuterNameAndItsElseCannotSeeTheNewOne() throws {
    let source = """
        func f(_ x: Int?) -> Int {
            let y = 100
            guard let y = x else { return y }
            return y
        }
        print(f(5), f(nil))
        """
    #expect(try run(source) == "5 100\n")
}

@Test func eachIterationOfALoopBindsAGuardAfresh() throws {
    let source = """
        func f() -> [Int] {
            var seen: [Int] = []
            var made: [() -> Int] = []
            for n in [1, nil, 3] {
                guard let v = n else { continue }
                seen.append(v)
                made.append { v * 10 }
            }
            return seen + made.map { $0() }
        }
        print(f())
        """
    #expect(try run(source) == "[1, 3, 10, 30]\n")
}

@Test func aWhileLetAndAGuardCasePatternBindInSlots() throws {
    let source = """
        func f() -> Int {
            var items: [Int?] = [1, 2, 3]
            var total = 0
            while let item = items.popLast() {
                guard case let v? = item else { continue }
                total += v
            }
            return total
        }
        print(f())
        """
    #expect(try run(source) == "6\n")
}
