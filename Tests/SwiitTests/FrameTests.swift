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

@Test func aBodyWithAGuardOrALocalFunctionRunsByName() throws {
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
