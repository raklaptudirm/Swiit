import Foundation
import Swiit
import Testing

// What a script cannot do: limits, cancellation, and one interpreter not seeing another.

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

@Test func theSandboxRefusesWhatItWasNotGiven() {
    let swiit = interpreter()
    func message(_ source: String) -> String? {
        do { _ = try swiit.evaluate(source); return nil } catch {
            return (error as? Diagnostic)?.message
        }
    }
    // Commands and `$(…)` aren't syntax here; files, the process and the
    // environment aren't names.
    #expect(message("git status") != nil)
    #expect(message("$(date)") != nil)
    #expect(message("ls()")?.contains("ls") == true)
    #expect(message("readLine()")?.contains("readLine") == true)
    #expect(message(#"env["HOME"]"#)?.contains("env") == true)
}

@Test func anInfiniteLoopStopsAtItsLimit() {
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 10_000))
    do {
        _ = try swiit.evaluate("var n = 0; while true { n += 1 }")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .limit)
        #expect(error.message.contains("step limit"))
    } catch {
        Issue.record("\(error)")
    }
    // The interpreter is still usable afterward.
    #expect((try? swiit.evaluate("1 + 1")) == 2)
}

@Test func aScriptCannotCatchALimit() {
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 1_000))
    do {
        _ = try swiit.evaluate("do { while true {} } catch { 0 }")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .limit)
    } catch {
        Issue.record("\(error)")
    }
}

@Test func deepRecursionStopsAtTheDepthLimit() {
    let swiit = interpreter(limits: Interpreter.Limits(maxCallDepth: 200))
    do {
        _ = try swiit.evaluate("func down(_ n: Int) -> Int { down(n + 1) }; down(0)")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.message.contains("maximum call depth (200)"))
    } catch {
        Issue.record("\(error)")
    }
    // The default depth fits the stack eval runs on.
    let deep = interpreter()
    #expect(
        (try? deep.evaluate("func sum(_ n: Int) -> Int { n == 0 ? 0 : n + sum(n - 1) }; sum(5000)"))
            == 12_502_500
    )
}

@Test func timeAndOutputAreLimitedToo() {
    let slow = interpreter(limits: Interpreter.Limits(timeLimit: .milliseconds(50)))
    do {
        _ = try slow.evaluate("while true {}")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.message == "time limit exceeded")
    } catch {
        Issue.record("\(error)")
    }
    let chatty = interpreter(limits: Interpreter.Limits(maxOutputBytes: 100))
    do {
        _ = try chatty.evaluate(#"for i in 1...100000 { print("xxxxxxxxxx") }"#)
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .limit)
    } catch {
        Issue.record("\(error)")
    }
}

@Test func cancellingFromAnotherThreadStopsARun() {
    let swiit = interpreter()
    // The run is on another thread; this one waits for it and cancels it.
    nonisolated(unsafe) let running = swiit
    nonisolated(unsafe) var result: Diagnostic?
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        do { _ = try running.evaluate("while true {}") } catch { result = error as? Diagnostic }
        done.signal()
    }
    thread.start()
    Thread.sleep(forTimeInterval: 0.1)
    swiit.cancel()
    done.wait()
    #expect(result?.kind == .cancelled)
}

@Test func twoInterpretersDontSeeEachOther() throws {
    let a = interpreter()
    let b = interpreter()
    a.register("only") { (x: Int) in x }
    _ = try a.evaluate("let shared = 1")
    #expect((try? b.evaluate("shared")) == nil)
    #expect((try? b.evaluate("only(1)")) == nil)
    #expect(try a.evaluate("only(shared)") == 1)
}

@Test func interpretersOnDifferentThreadsDontShareKeyPathReads() {
    // `map(\.n)` reads fields through a reader set for the length of
    // the call; two runs at once must each have their own.
    let program = #"[(n: 3, s: "c"), (n: 1, s: "a"), (n: 2, s: "b")].map(\.s)"#
    let expected: Value = ["c", "a", "b"]
    nonisolated(unsafe) var wrong = 0
    let lock = NSLock()
    let group = DispatchGroup()
    for _ in 0..<4 {
        group.enter()
        Thread {
            let swiit = interpreter()
            for _ in 0..<150 where (try? swiit.evaluate(program)) != expected {
                lock.withLock { wrong += 1 }
            }
            group.leave()
        }
        .start()
    }
    group.wait()
    #expect(wrong == 0)
}

@Test func aWaitThatSaysHowToWakeEndsWhenTheScriptIsCancelled() throws {
    let swiit = interpreter()
    swiit.register("block") { () -> Int in
        let gate = DispatchSemaphore(value: 0)
        return Interpreter.whileWaiting(wake: { gate.signal() }) {
            gate.wait(timeout: .now() + 10) == .timedOut ? 0 : 1
        }
    }
    // From a thread of its own: a busy runner can hold the global queue's block up for seconds,
    // and the test is of the cancel, not of the queue.
    let canceller = Thread {
        Thread.sleep(forTimeInterval: 0.2)
        swiit.cancel()
    }
    canceller.start()
    let start = Date()
    _ = try? swiit.evaluate("block()")
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func aRunTakesTheLimitsItIsGiven() throws {
    let swiit = interpreter()
    let loop = "var n = 0; while true { n += 1 }"
    #expect(throws: Diagnostic.self) {
        try swiit.evaluate(loop, limits: Interpreter.Limits(maxSteps: 1_000))
    }
    // The next run has the interpreter's own.
    #expect(try swiit.evaluate("1 + 1") == Value(2))
}

@Test func aCallOutsideARunStartsWithTheLimitsOfOne() throws {
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 2_000))
    _ = try swiit.evaluate("func f() -> Int { var n = 0; for i in 0..<300 { n += i }; return n }")
    for _ in 0..<20 { _ = try swiit.call("f") }
}

@Test func callingAFunctionValueOutsideARunStartsARun() throws {
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 2_000))
    _ = try swiit.evaluate("let f = { var n = 0; for i in 0..<300 { n += i }; return n }")
    let f = try swiit.evaluate("f")
    for _ in 0..<20 { _ = try swiit.call(f, with: []) }
}
