import Foundation
import Synchronization
import Testing

@testable import Swiit

// Swift's concurrency, (Docs/async.md, step 7): `Task`,
// `async let`, `for await`.

private func interpreter() -> Interpreter {
    Interpreter(
        host: Interpreter.Host(output: OutputSink({ _ in true }), error: OutputSink({ _ in true }))
    )
}

private func eval(_ source: String) throws -> Value {
    let swiit = interpreter()
    return try onLargeStack { try swiit.evaluate(source) }
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
    #expect(
        try eval("func f() async -> Int { 5 }; let t = Task { await f() * 2 }; await t.value")
            == .int(10)
    )
    #expect(
        typeError("let t = Task { 1 }; t.value")
            == "'value' is async, but isn't marked with 'await'"
    )
}

@Test func aThrowingTasksValueThrows() throws {
    let source = "let t = Task { try Task.checkCancellation(); return 1 }; "
    #expect(typeError(source + "await t.value") == "'value' can throw, but isn't marked with 'try'")
    #expect(try eval(source + "try await t.value") == .int(1))
    #expect(
        try eval(
            "let t = Task { try Task.checkCancellation(); return 1 }; t.cancel(); var failed = false; do { let r = try await t.value } catch { failed = true }; failed"
        ) == .bool(true)
    )
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
    // Unlike a job's, Swift's `Task { }` isn't structured: it goes on.
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
    #expect(
        typeError("async let x = Task.checkCancellation(); await x")
            == "'value' can throw, but isn't marked with 'try'"
    )
    #expect(
        typeError("func f() -> Int { async let x = 1; return 2 }")
            == "'await' in a function that isn't async: declare it 'async'"
    )
    // A closure reading it keeps it, as it keeps any variable.
    #expect(try eval("async let x = 5; let c = { await x * 2 }; await c()") == .int(10))
}

@Test func forTryAwaitReadsAnAsyncSequence() throws {
    #expect(
        try eval(
            """
            struct Counter {
                let limit: Int
                func makeAsyncIterator() -> Counting { Counting(limit: limit) }
            }
            final class Counting {
                let limit: Int
                var at = 0
                init(limit: Int) { self.limit = limit }
                func next() async throws -> Int? {
                    at += 1
                    return at <= limit ? at : nil
                }
            }
            var total = 0
            for try await n in Counter(limit: 3) { total += n }
            total
            """
        )
            == .int(6)
    )
    #expect(
        typeError("for await n in [1, 2] { }")
            == "'for await' reads an AsyncSequence, and [Int] isn't one"
    )
    #expect(
        typeError(
            """
            struct Counter { func makeAsyncIterator() -> Counter { self }
                func next() async throws -> Int? { nil } }
            for await n in Counter() { }
            """
        ) == "reading a Counter can throw: write 'for try await'"
    )
}

@Test func aValueIsThrownAway() throws {
    #expect(
        try eval(
            "var n = 0; func bump() -> Int { n += 1; return n }; _ = bump(); let _ = bump(); n"
        ) == .int(2)
    )
}

@Test func awaitCoversWhatFollows() throws {
    #expect(try eval("func f() async -> Int { 2 }; await f() + f() * 3") == .int(8))
}

/// A Swift `async` function, bridged as the generator bridges one: it calls
/// back into Swiit through an `async` closure.
@Test func aBridgedAsyncFunctionRunsWhileOthersWaitAndCallsBack() throws {
    let swiit = interpreter()
    let twice = Function(
        name: "twice",
        parameters: [
            Parameter(
                label: nil,
                name: "f",
                type: .function(parameters: [.int], returns: .int, isAsync: true)
            )
        ],
        returnType: .int,
        body: .native { swiit, args in
            try Value.Bridging.awaiting(in: swiit) { () async throws -> Value in
                let f = Value.Bridging.asyncClosure(for: args["f"]!, in: swiit)
                try await Task.sleep(nanoseconds: 100_000_000)
                let once = try Int(try await f([.int(10)]))
                return .int(try Int(try await f([.int(once)])))
            }
        },
        effect: .async
    )
    swiit.scopes[0].declare(twice, named: "twice")
    let source =
        "let t = Task { await twice { $0 + 1 } }; let u = Task { await twice { $0 * 2 } }; [await t.value, await u.value]"
    let start = Date()
    #expect(try onLargeStack { try swiit.evaluate(source) } == .list([.int(12), .int(40)]))
    // Not timed closely: CI's machines are slow to start threads and tasks.
    #expect(Date().timeIntervalSince(start) < 10)
    #expect(typeError("func g() -> Int { 1 }; g()") == nil)
}

@Test func anActorsStateIsReachedWithAwait() throws {
    let actor =
        "actor A { var n = 0; func inc() { n += 1 }; func twice() { inc(); inc() }; nonisolated func id() -> Int { 7 } }; let a = A(); "
    #expect(try eval(actor + "await a.twice(); await a.n") == .int(2))
    #expect(try eval(actor + "a.id()") == .int(7))
    #expect(
        typeError(actor + "a.inc()")
            == "'inc' of the actor A is async, but isn't marked with 'await'"
    )
    #expect(
        typeError(actor + "a.n") == "'n' of the actor A is async, but isn't marked with 'await'"
    )
}

@Test func aTypedThrowThrowsOnlyItsType() throws {
    let head =
        "enum A: Error { case x }; enum B: Error { case y }; func fa() throws(A) { throw .x }; func fb() throws { throw B.y }; "
    #expect(
        typeError(head + "func g() throws(A) { try fb() }")?
            .contains("throws any Error, but this function throws only A") == true
    )
    #expect(typeError(head + "func g() throws(A) { throw B.y }") != nil)
    #expect(
        try eval(
            head
                + "func g() throws(A) -> Int { try fa(); return 1 }; do { try g() } catch { switch error { case .x: print(1) } }; 2"
        ) == .int(2)
    )
}

@Test func aTaskStartedWithAPriorityRunsAtIt() throws {
    #expect(try eval("Task.currentPriority.rawValue") == .int(Int(TaskPriority.medium.rawValue)))
    #expect(
        try eval("await Task(priority: .high) { Task.currentPriority.rawValue }.value")
            == .int(Int(TaskPriority.high.rawValue))
    )
    // A task has the priority of the one that made it, and a detached one the default.
    #expect(
        try eval(
            """
            let outer = Task(priority: .low) {
                await Task { Task.currentPriority.rawValue }.value
            }
            await outer.value
            """
        ) == .int(Int(TaskPriority.low.rawValue))
    )
    #expect(
        try eval(
            """
            let outer = Task(priority: .low) {
                await Task.detached { Task.currentPriority.rawValue }.value
            }
            await outer.value
            """
        ) == .int(Int(TaskPriority.medium.rawValue))
    )
}

@Test func aDurationIsMadeAddedAndComparedAndTaskSleepTakesOne() throws {
    #expect(
        try eval("Duration.seconds(2) + Duration.milliseconds(500) == .seconds(2.5)") == .bool(true)
    )
    #expect(try eval("Duration.seconds(3) / 3 == .seconds(1)") == .bool(true))
    let start = Date()
    #expect(try eval("try await Task.sleep(for: .milliseconds(40)); 1") == .int(1))
    #expect(Date().timeIntervalSince(start) >= 0.04)
}

@Test func aLeadingDotNamesAStaticMemberOfTheTypeWanted() throws {
    #expect(
        try eval(
            """
            struct Point { var x: Int; static let origin = Point(x: 0); static func at(_ x: Int) -> Point { Point(x: x) } }
            let a: Point = .origin
            let b: Point = .at(4)
            a.x + b.x
            """
        ) == .int(4)
    )
    #expect(typeError("let x: Int = .nope")?.contains("nope") == true)
}

// Two runs on one interpreter take turns at their waits, and each keeps its own limits and its
// own stop.

@Test func aRunKeepsItsOwnTimeLimitWhileAnotherBegins() async throws {
    // The first run has half a second, which it spends waiting in short turns of 10 ms. The second
    // begins meanwhile, with half a minute, and must not move the first's deadline: if it did, the
    // first would go round thousands of times, not the fifty that half a second holds.
    let passes = Mutex(0)
    let swiit = Interpreter(
        host: Interpreter.Host(
            output: OutputSink({ text in
                if text.contains("x") { passes.withLock { $0 += 1 } }
                return true
            }),
            error: OutputSink({ _ in true })
        )
    )
    let first = Task { () async throws -> Value in
        try await swiit.evaluate(
            "while true { print(\"x\"); try await Task.sleep(nanoseconds: 10_000_000) }",
            limits: Interpreter.Limits(timeLimit: .milliseconds(500))
        )
    }
    try await Task.sleep(nanoseconds: 250_000_000)
    let second = Task { () async throws -> Value in
        try await swiit.evaluate(
            "try await Task.sleep(nanoseconds: 600_000_000); 1",
            limits: Interpreter.Limits(timeLimit: .seconds(30))
        )
    }

    let ended = await first.result
    guard case .failure(let error) = ended else {
        Issue.record("the first run was not stopped")
        return
    }
    #expect((error as? Diagnostic)?.message.contains("time limit") == true)
    let total = passes.withLock { $0 }
    #expect(total < 200, "the first run went round \(total) times")
    _ = try await second.value
}

@Test func aTimeLimitIsSeenRightAfterAWaitEnds() async throws {
    // Each pass of the loop waits 10 ms, so the deadline is over after about 20 of them. The steps
    // between two checks of the limits are a hundred passes: a check that waited for them would let
    // the run go on for that long past the deadline.
    let passes = Mutex(0)
    let swiit = Interpreter(
        host: Interpreter.Host(
            output: OutputSink({ text in
                if text.contains("x") { passes.withLock { $0 += 1 } }
                return true
            }),
            error: OutputSink({ _ in true })
        )
    )
    let ended = await Task { () async throws -> Value in
        try await swiit.evaluate(
            "while true { print(\"x\"); try await Task.sleep(nanoseconds: 10_000_000) }",
            limits: Interpreter.Limits(timeLimit: .milliseconds(200))
        )
    }
    .result
    guard case .failure(let error) = ended else {
        Issue.record("the run was not stopped")
        return
    }
    #expect((error as? Diagnostic)?.message.contains("time limit") == true)
    let total = passes.withLock { $0 }
    #expect(total < 35, "the loop went round \(total) times")
}

@Test func stoppingOneRunLeavesTheOtherGoing() async throws {
    let swiit = interpreter()
    let first = Task { () async throws -> Value in
        try await swiit.evaluate("try await Task.sleep(nanoseconds: 400_000_000); 1")
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let second = Task { () async throws -> Value in
        try await swiit.evaluate("try await Task.sleep(nanoseconds: 5_000_000_000); 2")
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    second.cancel()

    #expect(try await first.value == .int(1))
    switch await second.result {
    case .success: Issue.record("the cancelled run finished")
    case .failure(let error): #expect((error as? Diagnostic)?.message.contains("cancelled") == true)
    }
}
