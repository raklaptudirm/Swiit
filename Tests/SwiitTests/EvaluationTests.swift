import Foundation
import Swiit
import Testing

// Evaluating source: the value of the last expression, errors, the host being told as statements finish, and checking without running.

private final class Log: @unchecked Sendable {
    var text = ""
}

private func interpreter(
    limits: Interpreter.Limits = Interpreter.Limits(),
    log: Log = Log()
) -> Interpreter {
    Interpreter(
        host: Interpreter.Host(
            output: OutputSink({
                log.text += $0; return true
            }),
            error: OutputSink({
                log.text += "err: " + $0; return true
            })
        ),
        limits: limits
    )
}

@Test func printWritesToTheHostsOutput() throws {
    let log = Log()
    let swiit = interpreter(log: log)
    _ = try swiit.evaluate(#"print("hello", 1 + 1); print([1, 2])"#)
    #expect(log.text == "hello 2\n[1, 2]\n")
}

@Test func evalGivesTheValueOfTheLastExpression() throws {
    let swiit = interpreter()
    #expect(try swiit.evaluate("1 + 2") == 3)
    #expect(try swiit.evaluate("let xs = [3, 1, 2]; xs.sorted()") == [1, 2, 3])
    // A declaration gives nothing, and stays for the next call.
    #expect(try swiit.evaluate("let answer = 42") == .nothing)
    #expect(try swiit.evaluate("answer * 2") == 84)
    // A value statement shows nothing: values come back from eval.
    let log = Log()
    _ = try interpreter(log: log).evaluate("1; 2; 3")
    #expect(log.text == "")
}

@Test func errorsAreDiagnosticsWithAKind() {
    let swiit = interpreter()
    func diagnostic(_ source: String) -> Diagnostic? {
        do { _ = try swiit.evaluate(source); return nil } catch { return error as? Diagnostic }
    }
    #expect(diagnostic("let = 1")?.isSyntax == true)
    #expect(diagnostic("let x: Int = \"a\"")?.kind == .type)
    #expect(diagnostic("1 / 0")?.isRuntime == true)
    #expect(diagnostic("1 / 0")?.message == "division by zero")
    // A multi-line program says which line.
    #expect(diagnostic("let a = 1\nlet b: Int = \"x\"")?.range?.start.line == 2)
}

@Test func evaluateCanBeAwaitedAndIsCancelledWithItsTask() async throws {
    let swiit = interpreter()
    #expect(try await swiit.evaluate("1 + 2") == 3)
    let running = Task { try await swiit.evaluate("var n = 0; while true { n += 1 }") }
    try await Task.sleep(for: .milliseconds(150))
    running.cancel()
    do {
        _ = try await running.value
        Issue.record("expected the run to be cancelled")
    } catch let error as Diagnostic {
        #expect(error.kind == .cancelled)
    }
}

@Test func aRunCancelledBeforeItStartsDoesNotRun() async throws {
    let swiit = interpreter()
    // Cancelled at once, whichever of the request and the start of the run comes first.
    for _ in 0..<20 {
        let running = Task { try await swiit.evaluate("var n = 0; while true { n += 1 }") }
        running.cancel()
        do {
            _ = try await running.value
            Issue.record("expected the run to be cancelled")
        } catch let error as Diagnostic {
            #expect(error.kind == .cancelled)
        }
    }
}

@Test func evaluateGivesBackTheLastValueWhateverIsWatching() throws {
    let swiit = interpreter()
    nonisolated(unsafe) var seen: [String] = []
    // The last expression is told to `onValue` and given back too.
    let value = try swiit.evaluate(
        "1\n2 + 3",
        onValue: { value, _ in seen.append(value.description) }
    )
    #expect(value == 5)
    #expect(seen == ["1", "5"])
    // Nothing is given back when the last statement is not an expression, or failed and was let go.
    #expect(try swiit.evaluate("1\nlet y = 2", onValue: { _, _ in }) == .nothing)
    #expect(try swiit.evaluate("1\n2 / 0", onError: { _ in true }) == .nothing)
    // `completion` runs after the last statement.
    nonisolated(unsafe) var finished = false
    try swiit.evaluate("1", completion: { finished = true })
    #expect(finished)
}

@Test func theAsyncEvaluateTakesTheSameClosures() async throws {
    let swiit = interpreter()
    nonisolated(unsafe) var told = 0
    let value = try await swiit.evaluate("40 + 2", onValue: { _, _ in told += 1 })
    #expect(value == 42 && told == 1)
}

@Test func aCheckFindsMistakesAndRunsNothing() throws {
    let log = Log()
    let swiit = interpreter(log: log)
    let declared = try swiit.check(
        """
        print("ran")
        /// Says f.
        func f(a: Int, b: Bool = false) -> String { "x" }
        enum Kind { case a, b }
        """
    )
    #expect(log.text == "")
    #expect(declared.symbols.map(\.name) == ["Kind", "f"])
    // An enum it declares has its cases to ask for, before it exists to run.
    let cases = declared.members["Kind"]?
        .filter {
            if case .enumCase = $0.kind { true } else { false }
        }
    #expect(cases?.map(\.name) == ["a", "b"])
    #expect(declared.symbols.first { $0.name == "f" }?.summary == "Says f.")
    let f = declared.symbols.first { $0.name == "f" }?.function
    #expect(f?.parameters.map(\.label) == ["a", "b"])
    #expect(f?.parameters[1].arity == .defaulted(.value(false)))
    #expect(throws: Diagnostic.self) { try swiit.check(#"print("ran"); let x: Int = "s""#) }
    #expect(log.text == "")
    // Nothing was declared by checking.
    #expect(swiit.globals(named: "f").isEmpty)
}

@Test func theHostIsToldAsStatementsFinish() throws {
    let swiit = interpreter()
    nonisolated(unsafe) var told: [String] = []
    swiit.host.didFinishStatement = { value, caught in
        told.append(caught ? "caught" : value.map { $0.description } ?? "-")
    }
    _ = try swiit.evaluate(
        """
        let x = 1
        x + 1
        func f() -> Int { 7 }
        f()
        try? Int("z")
        if x == 1 { x + 10 }
        """
    )
    // Values of the expression statements, in order; `if` is told as it starts, and what is in it
    // as it runs.
    #expect(told.filter { $0 != "-" } == ["2", "7", "caught", "11"])
}

@Test func aReplHostIsToldTheValueOfEachExpressionStatement() throws {
    let swiit = interpreter()
    nonisolated(unsafe) var seen: [String] = []
    try swiit.evaluate(
        """
        let x = 2
        x * 3
        true
        [1, 2].map { $0 + x }
        await Task { 5 }.value
        for i in 1...2 { i }
        """,
        onValue: { value, _ in seen.append(value.description) }
    )
    #expect(seen == ["6", "[3, 4]", "5"])
    // A failure stops the run, unless the host says to go on.
    seen = []
    #expect(throws: Diagnostic.self) {
        try swiit.evaluate("1\n2 / 0\n3", onValue: { value, _ in seen.append(value.description) })
    }
    #expect(seen == ["1"])
    seen = []
    nonisolated(unsafe) var errors: [String] = []
    // A `try!` that fails is fatal: the host is told, and the run ends.
    #expect(throws: Diagnostic.self) {
        try swiit.evaluate(
            "struct E: Error {}\nfunc boom() throws { throw E() }\n1\n2 / 0\n3\ntry! boom()\n4",
            onValue: { value, _ in seen.append(value.description) },
            onError: {
                errors.append($0.message + ($0.isFatal ? " (fatal)" : "")); return !$0.isFatal
            }
        )
    }
    #expect(seen == ["1", "3"])
    #expect(errors.count == 2 && errors[1].hasSuffix("(fatal)"))
}

@Test func aHostAsksTheFunctionAStatementCalledForItsAttributes() throws {
    let swiit = interpreter()
    swiit.register(
        HostSymbol.function(
            name: "quiet",
            returns: Int.self,
            attributes: [Symbol.Attribute(name: "discardableResult")],
            body: { _ in Value(10) }
        )
    )
    swiit.register("loud") { () -> Int in 20 }
    nonisolated(unsafe) var told: [String: [String]] = [:]
    try swiit.evaluate(
        """
        @discardableResult func bump() -> Int { 30 }
        @available(*, deprecated) func old() -> Int { 40 }
        var xs = [7, 8, 9]
        bump()
        old()
        quiet()
        loud()
        xs.removeLast()
        xs.count
        """,
        onValue: { value, callee in
            told[value.description, default: []] = (callee?.attributes ?? [])
                .map {
                    $0.name
                        + ($0.arguments.isEmpty
                            ? "" : "(" + $0.arguments.joined(separator: ",") + ")")
                }
        }
    )
    // A script's own attributes, with their arguments as written; a host function's; a bridged
    // Swift member's; and none for a call without any, or a statement that is no call.
    #expect(told["30"] == ["discardableResult"])
    #expect(told["40"] == ["available(*, deprecated)"])
    #expect(told["10"] == ["discardableResult"])
    #expect(told["20"] == [])
    #expect(told["9"] == ["discardableResult"])
    #expect(told["2"] == [])
    // And a symbol lookup says the same of what is declared.
    let bump = swiit.globals(named: "bump").first
    #expect(bump?.attributes.contains(named: "discardableResult") == true)
}

@Test func anExtensionAddsAStaticMethodToAnEnum() throws {
    let swiit = interpreter()
    #expect(
        try swiit.evaluate(
            "enum Namespace {}; extension Namespace { static func answer() -> Int { 42 } }; Namespace.answer()"
        ) == 42
    )
    // Declared by separate evaluations, and beside a case.
    _ = try swiit.evaluate("enum Level { case low }")
    _ = try swiit.evaluate("extension Level { static func make() -> Level { .low } }")
    #expect(try swiit.evaluate("Level.make() == .low") == true)
}

@Test func aNestedTypeIsReachedByALaterEvaluation() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate(
        "struct Code { struct Size { static func bigger() -> Int { 2 } }; enum Kind { case a } }"
    )
    #expect(try swiit.evaluate("Code.Size.bigger()") == 2)
    #expect(try swiit.evaluate("Code.Kind.a == .a") == true)
}
