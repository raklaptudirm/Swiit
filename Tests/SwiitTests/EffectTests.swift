@testable import Swiit
import Testing

// `async` and `await` as Swift has them (Docs/async.md, step 3): only
// the checker's answers are new; the interpreter waits at every wait anyway.

private func interpreter() -> Interpreter {
    Interpreter(host: Interpreter.Host(output: OutputSink({ _ in true }), error: OutputSink({ _ in true })))
}

/// The type error the source gives, or nil if it checks.
private func typeError(_ source: String) -> String? {
    do {
        _ = try interpreter().evaluate(source)
        return nil
    } catch let error as Diagnostic {
        return error.kind == .type ? error.message : "not a type error: \(error.message)"
    } catch {
        return "\(error)"
    }
}

@Test func anAsyncFunctionIsAwaited() throws {
    #expect(try interpreter().evaluate("func f() async -> Int { 1 }; let x = await f(); x + 1") == .int(2))
    #expect(typeError("func f() async -> Int { 1 }; f()") == "'f' is async, but isn't marked with 'await'")
    // `try` and `await` together, as Swift writes them.
    #expect(try interpreter().evaluate("func f() async throws -> Int { 3 }; try await f()") == .int(3))
}

@Test func awaitIsWrittenInAnAsyncContext() throws {
    let source = "func f() async -> Int { 1 }; "
    #expect(typeError(source + "func g() -> Int { await f() }") == "'await' in a function that isn't async: declare it 'async'")
    #expect(try interpreter().evaluate(source + "func g() async -> Int { await f() + 1 }; await g()") == .int(2))
    // A closure that awaits is async itself, and is awaited too.
    #expect(try interpreter().evaluate(source + "let c = { await f() }; await c()") == .int(1))
    #expect(typeError(source + "let c = { await f() }; c()") == "c is async, but isn't marked with 'await'")
    // Nothing async in it: nothing to await.
    #expect(typeError("await 1")?.hasPrefix("there is nothing to await here") == true)
}

@Test func anAsyncFunctionIsntPassedWhereASyncOneIsWanted() {
    let source = "func f() async -> Int { 1 }; func twice(_ g: () -> Int) -> Int { g() + g() }; "
    #expect(typeError(source + "twice({ await f() })") != nil)
    #expect(typeError(source + "twice({ 1 })") == nil)
}

@Test func asyncIsWrittenInTypesAndPrinted() throws {
    let program = try SwiftSyntaxFrontEnd().parse("func f(_ g: () async -> Int) async throws -> Int { await g() }", bound: [:])
    guard case .function(let decl) = program.statements[0] else { Issue.record(); return }
    #expect(decl.isAsync && decl.isThrowing)
    #expect(decl.parameters[0].type == .functionType([], .int, async: .async))
    #expect(SwiftPrinter().source(program).hasPrefix("func f(_ g: () async -> Int) async throws -> Int"))
}

// Tasks on threads, one at a time behind the interpreter's lock.

@Test func aTaskRunsWhenTheLockIsLetGoAndIsJoined() throws {
    let swiit = interpreter()
    let value = try onLargeStack {
        try swiit.lock.withLock { () throws -> Value in
            let task = try swiit.startTask(host: nil) { .int(21 * 2) }
            // Joining lets go of the lock, so the task can run.
            return try swiit.join(task)
        }
    }
    #expect(value == .int(42))
}

@Test func aTasksErrorIsWhatJoiningThrows() throws {
    let swiit = interpreter()
    #expect(throws: Diagnostic.self) {
        try onLargeStack {
            try swiit.lock.withLock { () throws -> Value in
                let task = try swiit.startTask(host: nil) { throw RuntimeError("no") }
                return try swiit.join(task)
            }
        }
    }
}

@Test func closingAScopeCancelsAndWaitsForItsTasks() throws {
    let swiit = interpreter()
    try onLargeStack {
        try swiit.withMainTask {
            let task = try swiit.startTask(host: nil) {
                // It never ends on its own; it stops when it's cancelled.
                while true { try swiit.checkInterrupt() }
            }
            #expect(swiit.task.children.count == 1)
            swiit.closeTasks(above: -1)
            #expect(swiit.task.children.isEmpty)
            #expect(task.isFinished)
        }
    }
}

// A function that waits, a plugin's, lets the lock go through SwiitKit's
// `Waiting` (Docs/async.md, step 6).
@Test func waitingLetsTheLockGo() {
    let swiit = interpreter()
    #expect(Waiting.host == nil || Waiting.host !== swiit)
    swiit.withMainTask {
        #expect(Waiting.host === swiit)
        #expect(swiit.lock.isHeldByCurrentThread)
        let held = Waiting.whileWaiting { swiit.lock.isHeldByCurrentThread }
        #expect(!held)
        #expect(swiit.lock.isHeldByCurrentThread)
        // A read with no host saying whose turn it is just reads.
        #expect(Waiting.forInput { "line" } == "line")
    }
    #expect(Waiting.host !== swiit)
}
