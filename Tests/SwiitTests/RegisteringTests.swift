import Foundation
import Swiit
import Testing

// Giving scripts Swift functions and values: closures, globals, failures, per-task state and tasks.

extension Interpreter {
    /// A type a script or the host declared, as a reference.
    fileprivate func type(_ name: String) -> ScriptType {
        .named(Symbol.ID(named: name, in: self)!)
    }
}

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

private struct Stop: Error {}

private struct Status: Error { var code: Int32 }

private final class Mark: @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
}

private final class Handle: ScriptConvertible, CustomStringConvertible, @unchecked Sendable {
    let task: ScriptTask
    init(_ task: ScriptTask) { self.task = task }
    var description: String { "Handle" }
}

/// Swift types a host encodes into struct values, by their own names.
private struct Failure: Encodable { var code: Int }

@Test func aRegisteredClosureIsAnOrdinaryFunction() throws {
    let swiit = interpreter()
    swiit.register("clamp") { (x: Int, lo: Int, hi: Int) in min(max(x, lo), hi) }
    swiit.register("greet", labels: ["name"]) { (name: String) in "hello, \(name)" }
    swiit.register("twice") { (xs: [Int]) in xs + xs }
    #expect(try swiit.evaluate("clamp(15, 0, 10)") == 10)
    #expect(try swiit.evaluate(#"greet(name: "Rak")"#) == "hello, Rak")
    #expect(try swiit.evaluate("twice([1, 2]).count") == 4)
    // A wrong argument is the usual type error.
    do {
        _ = try swiit.evaluate(#"clamp("a", 0, 10)"#)
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .type)
        #expect(error.message.contains("Int"))
    }
}

@Test func aRegisteredClosureThatThrowsIsARuntimeDiagnostic() throws {
    struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }
    let swiit = interpreter()
    swiit.register("check", throwing: true) { (x: Int) throws -> Int in
        if x < 0 { throw Refused() }
        return x
    }
    #expect(try swiit.evaluate("try check(1)") == 1)
    do {
        _ = try swiit.evaluate("try check(-1)")
        Issue.record("expected a diagnostic")
    } catch let error {
        guard case .runtime = error.kind else {
            Issue.record("expected a run-time failure"); return
        }
        #expect(error.message.contains("refused"))
    }
}

@Test func valuesSetByTheHostAreReadByTheScript() throws {
    struct Config: Encodable { var volume = 7; var name = "main" }
    let swiit = interpreter()
    swiit["config"] = try Value(encoding: Config())
    swiit["limit"] = 10
    #expect(try swiit.evaluate("config.volume * 2") == 14)
    #expect(try swiit.evaluate("limit + 1") == 11)
    #expect(swiit["limit"] == 10)
}

@Test func removingAGlobalRemovesIt() throws {
    let swiit = interpreter()
    swiit["answer"] = Value(42)
    #expect(try swiit.evaluate("answer") == 42)
    swiit["answer"] = nil
    #expect(throws: Diagnostic.self) { try swiit.evaluate("answer") }
}

@Test func aHostFunctionFailsWithADiagnosticOrEndsTheRun() throws {
    let log = Log()
    let swiit = interpreter(log: log)
    swiit.register(
        HostSymbol.function(name: "fail", returns: .int, isThrowing: true) { _ in
            throw Diagnostic.runtime(
                "nope",
                thrown: try Value(encoding: Failure(code: 7)),
                cause: Status(code: 3)
            )
        }
    )
    swiit.register(
        HostSymbol.function(name: "stop", isThrowing: true) { _ in
            throw Diagnostic.fatal("stopped", cause: Stop())
        }
    )
    // A script can catch a script error, and what it carries.
    _ = try swiit.evaluate("struct Failure: Error { let code: Int }")
    #expect(
        try swiit.evaluate(
            "var r = -1; do { _ = try fail() } catch let f as Failure { r = f.code } catch { r = -2 }; r"
        ) == 7
    )
    #expect(try swiit.evaluate("(try? fail()) == nil") == true)
    let failure = #expect(throws: Diagnostic.self) { try swiit.evaluate("try fail()") }
    #expect(failure?.message == "nope")
    guard case .runtime(let ran)? = failure?.kind, case .hostError(let own) = ran.origin else {
        Issue.record("expected a run-time failure with an error of the host's own")
        return
    }
    #expect((own as? Status)?.code == 3)
    // A fatal failure is not caught, runs the defers, and reaches the host.
    let stopped = #expect(throws: Diagnostic.self) {
        try swiit.evaluate(
            #"func f() throws { defer { print("deferred") }; try stop() }; do { try f() } catch { print("caught") }"#
        )
    }
    guard case .fatal(let ended)? = stopped?.kind, case .hostError(let cause) = ended.origin else {
        Issue.record("expected a fatal failure with an error of the host's own")
        return
    }
    #expect(cause is Stop)
    #expect(log.text == "deferred\n")
}

@Test func theHostKeepsStateForEachTask() throws {
    let swiit = interpreter()
    swiit.host.makeTaskState = { Mark("task") }
    swiit.taskState = Mark("main")
    nonisolated(unsafe) let running = swiit
    swiit.register("who") { () -> String in (running.taskState as? Mark)?.label ?? "none" }
    #expect(try swiit.evaluate("who()") == "main")
    #expect(try swiit.evaluate("await Task { who() }.value") == "task")
    #expect((swiit.taskState as? Mark)?.label == "main")
}

@Test func aHostFunctionCanSayItGivesAScriptsStruct() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("struct P { var x: Int }")
    let id = try #require(Symbol.ID(named: "P", in: swiit))
    swiit.register(
        HostSymbol.function(name: "hostP", returns: .named(id)) { _ in
            try swiit.make(id, arguments: [("x", Value(5))])
        }
    )
    #expect(try swiit.evaluate("hostP().x + 1") == Value(6))
}

@Test func aDictionaryIsAParameterAndAResult() throws {
    let swiit = interpreter()
    swiit.register("shout") { (words: [String: String]) in words.mapValues { $0.uppercased() } }
    #expect(try swiit.evaluate(#"shout(["a": "x"])["a"]"#) == "X")
    // The checker knows its type: a wrong one is found before the script runs.
    #expect(throws: (any Error).self) { try swiit.evaluate(#"shout(["a": 1])"#) }
    #expect(throws: (any Error).self) { try swiit.evaluate("shout([1, 2])") }
}

@Test func wordsAndValuesConvertToTheTypeAParameterNames() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum Kind { case file, directory }")
    #expect(
        Symbol.ID(named: "Kind", in: swiit)!.enumCase(named: "file", in: swiit)?.description
            == "file"
    )
    #expect(Symbol.ID(named: "Kind", in: swiit)!.enumCase(named: "nope", in: swiit) == nil)
    #expect(swiit.converted(Value(3), to: .int) == 3)
    #expect(swiit.converted(Value("3"), to: .int) == nil)
    // A Character is held as a one-letter String. Any other Swift type text is not, as in Swift,
    // where only a literal is one.
    #expect(swiit.converted(Value("a"), to: swiit.type("Character")) == "a")
    #expect(swiit.converted(Value("ab"), to: swiit.type("Character")) == nil)
    #expect(swiit.converted(Value("x"), to: swiit.type("Substring")) == nil)
    #expect(swiit.scriptType(of: Value(3)) == .int)
    #expect(swiit.scriptType(of: [1, 2]) == .list(.int))
}

@Test func aHostStartsAndJoinsTasksAndLetsScriptsAwaitThem() throws {
    let swiit = interpreter()
    nonisolated(unsafe) let running = swiit
    let handle = Symbol.ID(hostType: "Handle")
    swiit.register(
        HostSymbol.function(name: "spawn", returns: .named(handle)) { _ in
            Value(Handle(try running.startTask(state: nil) { Value(42) }))
        }
    )
    swiit.register(computed: "clock", type: .int) { Value(7) }
    // A handle is awaited by its `async` member, as Swift says it.
    swiit.register(
        HostType.Builder<Handle>("Handle")
            .member(
                .method("wait", returns: .int, isAsync: true) { receiver, _ in
                    guard let handle = try? Handle(receiver) else {
                        throw Diagnostic.runtime("nothing to await")
                    }
                    return try running.join(handle.task)
                }
            )
    )
    #expect(try swiit.evaluate("clock + clock") == 14)
    #expect(try swiit.evaluate("await spawn().wait()") == 42)
    swiit.cancelAndJoinTasks()
}
