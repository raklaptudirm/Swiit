@_spi(Layer) @testable import Swiit
import Foundation
import SwiitKit
import Testing

// Swift's concurrency, from Swish (Docs/Design/async.md, step 7): `Task`,
// `async let`, `for await`.

private func interpreter() -> Interpreter {
    Interpreter(host: SwiitHost(output: OutputSink(write: { _ in true }), error: OutputSink(write: { _ in true })))
}

private func eval(_ source: String) throws -> Value {
    let swish = interpreter()
    return try onLargeStack { try swish.eval(source) }
}

private func typeError(_ source: String) -> String? {
    do {
        _ = try eval(source)
        return nil
    } catch let error as Diagnostic {
        return error.kind == .type ? error.message : "not a type error: \(error.message)"
    } catch {
        return "\(error)"
    }
}

@Test func aTaskGivesItsValue() throws {
    #expect(try eval("let t = Task { 20 + 22 }; await t.value") == .int(42))
    #expect(try eval("func f() async -> Int { 5 }; let t = Task { await f() * 2 }; await t.value") == .int(10))
    #expect(typeError("let t = Task { 1 }; t.value") == "'value' is async, but isn't marked with 'await'")
}

@Test func aThrowingTasksValueThrows() throws {
    let source = "let t = Task { try Task.checkCancellation(); return 1 }; "
    #expect(typeError(source + "await t.value") == "'value' can throw, but isn't marked with 'try'")
    #expect(try eval(source + "try await t.value") == .int(1))
    #expect(try eval("let t = Task { try Task.checkCancellation(); return 1 }; t.cancel(); var failed = false; do { let r = try await t.value } catch { failed = true }; failed") == .bool(true))
    // A task that can't throw is awaited without `try`.
    #expect(typeError("let t = Task { 1 }; await t.value") == nil)
}

@Test func tasksRunWhileOthersSleep() throws {
    let start = Date()
    let source = """
    let a = Task { try await Task.sleep(nanoseconds: 300_000_000); return 1 }
    let b = Task { try await Task.sleep(nanoseconds: 300_000_000); return 2 }
    try await a.value + b.value
    """
    #expect(try eval(source) == .int(3))
    #expect(Date().timeIntervalSince(start) < 0.55)
}

@Test func aCancelledTaskStops() throws {
    let start = Date()
    let source = """
    let t = Task { try await Task.sleep(nanoseconds: 100_000_000_000); return 1 }
    t.cancel()
    var caught = false
    do { let r = try await t.value } catch { caught = error is CancellationError }
    [t.isCancelled, caught]
    """
    #expect(try eval(source) == .list([.bool(true), .bool(true)]))
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(try eval("Task.isCancelled") == .bool(false))
    #expect(try eval("try Task.checkCancellation(); await Task.yield(); 1") == .int(1))
}

@Test func aTaskOutlivesTheScopeThatMadeIt() throws {
    // Unlike a shell job's, Swift's `Task { }` isn't structured: it goes on.
    let source = """
    func start() -> Task<Int, Never> { Task { await Task.yield(); return 7 } }
    let t = start()
    await t.value
    """
    #expect(try eval(source) == .int(7))
}

@Test func asyncLetStartsAChildTaskThatReadingAwaits() throws {
    let start = Date()
    let source = """
    func slow(_ n: Int) async -> Int { try? await Task.sleep(nanoseconds: 300_000_000); return n }
    async let a = slow(1)
    async let b = slow(2)
    await a + b
    """
    #expect(try eval(source) == .int(3))
    #expect(Date().timeIntervalSince(start) < 0.55)
    // Reading it waits, and throws what it threw, as in Swift.
    #expect(typeError("async let x = 1; x") == "'value' is async, but isn't marked with 'await'")
    #expect(typeError("async let x = Task.checkCancellation(); await x") == "'value' can throw, but isn't marked with 'try'")
    #expect(typeError("func f() -> Int { async let x = 1; return 2 }") == "'await' in a function that isn't async: declare it 'async'")
    // A closure reading it keeps it, as it keeps any variable.
    #expect(try eval("async let x = 5; let c = { await x * 2 }; await c()") == .int(10))
}

@Test func forTryAwaitReadsAnAsyncSequence() throws {
    #expect(try eval("var total = 0; for try await n in Flow([1, 2, 3]) { total += n }; total") == .int(6))
    #expect(typeError("for await n in [1, 2] { }") == "'for await' reads an AsyncSequence, and [Int] isn't one")
    #expect(typeError("for await n in Flow([1]) { }") == "reading a Flow<Int> can throw: write 'for try await'")
}

@Test func aValueIsThrownAway() throws {
    #expect(try eval("var n = 0; func bump() -> Int { n += 1; return n }; _ = bump(); let _ = bump(); n") == .int(2))
}

@Test func awaitCoversWhatFollows() throws {
    #expect(try eval("func f() async -> Int { 2 }; await f() + f() * 3") == .int(8))
}

/// A Swift `async` function, bridged as the generator bridges one: it calls
/// back into Swish through an `async` closure.
@Test func aBridgedAsyncFunctionRunsWhileOthersWaitAndCallsBack() throws {
    let swish = interpreter()
    let twice = Function(
        name: "twice", parameters: [Parameter(label: nil, name: "f", type: .functionType([.int], .int, async: .async))],
        returnType: .int,
        body: .native { shell, args in
            try bridgeAsync(shell) { () async throws -> Value in
                let f = bridgeAsyncClosure(shell, args["f"]!)
                try await Task.sleep(nanoseconds: 100_000_000)
                let once = try Int(swiitValue: try await f([.int(10)]))
                return .int(try Int(swiitValue: try await f([.int(once)])))
            }
        },
        effect: .async
    )
    swish.scopes[0].declare(twice, named: "twice")
    let source = "let t = Task { await twice { $0 + 1 } }; let u = Task { await twice { $0 * 2 } }; [await t.value, await u.value]"
    let start = Date()
    #expect(try onLargeStack { try swish.eval(source) } == .list([.int(12), .int(40)]))
    // Not timed closely: CI's machines are slow to start threads and tasks.
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(typeError("func g() -> Int { 1 }; g()") == nil)
}
