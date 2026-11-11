import Foundation
import Swiit
import Synchronization
import Testing

// What a Swift body a host gives the interpreter can rely on (Swiit.docc/NativeBodies.md). Each test
// is one promise. An evaluator that replaces the tree walker, a bytecode machine say, keeps the
// promises or says it does not, and these are how that is found out.

private final class Log: @unchecked Sendable {
    var text = ""
}

private func interpreter(
    limits: Interpreter.Limits = Interpreter.Limits(),
    log: Log = Log()
)
    -> Interpreter
{
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

private struct Boom: Error, CustomStringConvertible {
    var description: String { "boom" }
}

// MARK: How a body is called

@Test func aBodyIsCalledWithItsArgumentsInDeclaredOrderAndDefaultsFilled() throws {
    let swiit = interpreter()
    let seen = Mutex<[[Value]]>([])
    swiit.register(
        HostSymbol.function(
            name: "f",
            parameters: [
                .init(label: nil, name: "a", type: .int),
                .init(label: "b", name: "b", type: .int, arity: .defaulted(.value(Value(5)))),
                .init(label: "c", name: "c", type: .string),
            ],
            returns: .int
        ) { arguments in
            seen.withLock { $0.append(arguments) }
            return Value(arguments.count)
        }
    )
    // Written in any order the labels allow, and with a default left out.
    #expect(try swiit.evaluate(#"f(1, c: "x")"#) == 3)
    #expect(try swiit.evaluate(#"f(2, b: 7, c: "y")"#) == 3)
    #expect(seen.withLock { $0 } == [[1, 5, "x"], [2, 7, "y"]])
}

@Test func aBodyCanCallBackIntoTheScriptItIsRunningIn() throws {
    let swiit = interpreter()
    nonisolated(unsafe) let running = swiit
    // Calls a script function with a value, and evaluates source that sees what the script has.
    swiit.register(
        HostSymbol.function(
            name: "twice",
            parameters: [.init(label: nil, name: "f", type: .callable)],
            returns: .int
        ) { arguments in
            let once = try running.call(arguments[0], with: [Value(1)])
            return try running.call(arguments[0], with: [once])
        }
    )
    swiit.register(
        HostSymbol.function(name: "peek", returns: .int) { _ in
            try running.evaluate("hidden + 1")
        }
    )
    #expect(try swiit.evaluate("let hidden = 41; twice { $0 + 10 }") == 21)
    #expect(try swiit.evaluate("peek()") == 42)
    // A script function that calls a body that calls a script function, three levels down.
    #expect(
        try swiit.evaluate(
            "func g(_ n: Int) -> Int { n == 0 ? 0 : 1 + twice { _ in g(n - 1) } }; g(3)"
        )
            == 3
    )
}

@Test func aBodyFindsTheInterpreterThatCalledItWithoutHoldingOne() throws {
    let swiit = interpreter()
    let other = interpreter()
    swiit.register(
        HostSymbol.function(name: "sameAsMine", returns: .bool) { _ in
            Value(Interpreter.running === swiit)
        }
    )
    other.register(
        HostSymbol.function(name: "sameAsMine", returns: .bool) { _ in
            Value(Interpreter.running === swiit)
        }
    )
    #expect(try swiit.evaluate("sameAsMine()") == true)
    #expect(try other.evaluate("sameAsMine()") == false)
    // On a thread running no script's code there is none.
    #expect(Interpreter.running == nil)
    // A body reaches the script through it, as a function that holds the interpreter does.
    swiit.register(
        HostSymbol.function(
            name: "twiceViaRunning",
            parameters: [.init(label: nil, name: "f", type: .callable)],
            returns: .int
        ) { arguments in
            let running = try #require(Interpreter.running)
            let once = try running.call(arguments[0], with: [Value(1)])
            return try running.call(arguments[0], with: [once])
        }
    )
    #expect(try swiit.evaluate("twiceViaRunning { $0 + 10 }") == 21)
}

@Test func whatABodyChangesInTheScriptIsSeenWhenItReturns() throws {
    let swiit = interpreter()
    nonisolated(unsafe) let running = swiit
    swiit.register(
        HostSymbol.function(
            name: "bump",
            parameters: [.init(label: nil, name: "f", type: .callable)]
        ) { arguments in
            _ = try running.call(arguments[0], with: [])
            _ = try running.call(arguments[0], with: [])
            return .nothing
        }
    )
    #expect(try swiit.evaluate("var n = 0; bump { n += 1 }; n") == 2)
}

// MARK: What happens when a body fails

@Test func anErrorABodyThrowsIsOneAScriptCanCatch() throws {
    let swiit = interpreter()
    swiit.register(HostSymbol.function(name: "plain", isThrowing: true) { _ in throw Boom() })
    swiit.register(
        HostSymbol.function(name: "diagnosed", isThrowing: true) { _ in
            throw Diagnostic.runtime("nope")
        }
    )
    let caught = try swiit.evaluate(
        """
        var seen: [String] = []
        do { try plain() } catch { seen.append(error.localizedDescription) }
        do { try diagnosed() } catch { seen.append(error.localizedDescription) }
        seen
        """
    )
    guard let messages = caught.casting(to: [String].self) else {
        Issue.record("expected the messages the script caught")
        return
    }
    #expect(messages.count == 2)
    #expect(messages[0].contains("boom") && messages[0].contains("plain"))
    #expect(messages[1].contains("nope"))
    // Uncaught, it ends the statement with a diagnostic the host reads.
    #expect(throws: Diagnostic.self) { try swiit.evaluate("try plain()") }
}

@Test func aFatalErrorIsNotCaughtAndTheDefersRun() throws {
    struct Stop: Error {}
    let log = Log()
    let swiit = interpreter(log: log)
    swiit.register(
        HostSymbol.function(name: "stop", isThrowing: true) { _ in
            throw Diagnostic.fatal("stopped", cause: Stop())
        }
    )
    let failure = #expect(throws: Diagnostic.self) {
        try swiit.evaluate(
            #"func f() throws { defer { print("deferred") }; try stop() }; do { try f() } catch { print("caught") }"#
        )
    }
    guard case .fatal? = failure?.kind else {
        Issue.record("expected a fatal failure")
        return
    }
    #expect(log.text == "deferred\n")
}

// MARK: Stopping

@Test func aBodyThatLoopsStopsWhereItChecks() throws {
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 1_000))
    nonisolated(unsafe) let running = swiit
    let ran = Mutex(0)
    swiit.register(
        HostSymbol.function(name: "spin", isThrowing: true) { _ in
            for _ in 0..<1_000_000 {
                try running.checkForStop()
                ran.withLock { $0 += 1 }
            }
            return .nothing
        }
    )
    let failure = #expect(throws: Diagnostic.self) { try swiit.evaluate("try spin()") }
    guard case .limit? = failure?.kind else {
        Issue.record("expected the step limit")
        return
    }
    #expect(ran.withLock { $0 } < 1_000_000)
}

// MARK: Running beside other tasks

@Test func bodiesOfDifferentTasksNeverRunAtOnce() throws {
    let swiit = interpreter()
    let inside = Mutex((now: 0, most: 0))
    swiit.register(
        HostSymbol.function(name: "work", returns: .int) { _ in
            inside.withLock {
                $0.now += 1
                $0.most = max($0.most, $0.now)
            }
            usleep(2_000)  // not `whileWaiting`: it holds the others up
            inside.withLock { $0.now -= 1 }
            return Value(1)
        }
    )
    let total = try swiit.evaluate(
        """
        async let a = work(); async let b = work(); async let c = work(); async let d = work()
        await a + b + c + d
        """
    )
    #expect(total == 4)
    #expect(inside.withLock { $0.most } == 1)
}

@Test func aBodyThatWaitsLetsOtherTasksRun() throws {
    let swiit = interpreter()
    let gate = DispatchSemaphore(value: 0)
    swiit.register(
        HostSymbol.function(name: "block", returns: .int) { _ in
            Interpreter.whileWaiting { gate.wait() }
            return Value(1)
        }
    )
    swiit.register(
        HostSymbol.function(name: "release", returns: .int) { _ in
            gate.signal()
            return Value(2)
        }
    )
    // `block` waits for what a task that runs while it waits gives.
    #expect(try swiit.evaluate("async let a = block(); async let b = release(); await a + b") == 3)
}

// MARK: Values and receivers

private struct ContractTally: Hashable, Sendable, ScriptConvertible {
    var n: Int
}

@Test func aMutatingMemberChangesItsReceiverInPlaceAndGivesItsResult() throws {
    let swiit = interpreter()
    swiit.register(
        HostType.Builder<ContractTally>("ContractTally")
            .member(
                .initializer(returns: .named(Symbol.ID(hostType: "ContractTally"))) { _ in
                    Value(ContractTally(n: 0))
                }
            )
            .member(.property("n", type: .int) { try Value(ContractTally($0).n) })
            .member(
                .mutatingMethod("bump", returns: .int) { receiver, _ in
                    let next = ContractTally(n: try ContractTally(receiver).n + 1)
                    receiver = Value(next)
                    return Value(next.n)
                }
            )
            .member(
                .mutatingMethod("fail", isThrowing: true) { _, _ in throw Boom() }
            )
            .member(
                .mutatingMethod("bumpThenFail", isThrowing: true) { receiver, _ in
                    receiver = Value(ContractTally(n: try ContractTally(receiver).n + 1))
                    throw Boom()
                }
            )
            .member(
                .property(
                    "double",
                    type: .int,
                    get: { try Value(ContractTally($0).n * 2) },
                    set: { receiver, newValue in Value(ContractTally(n: try Int(newValue) / 2)) }
                )
            )
    )
    #expect(try swiit.evaluate("var c = ContractTally(); let one = c.bump(); c.bump(); c.n") == 2)
    #expect(try swiit.evaluate("one") == 1)
    // The copy a `let` holds is not changed by the `var`'s.
    #expect(try swiit.evaluate("var a = ContractTally(); let b = a; a.bump(); a.n") == 1)
    #expect(try swiit.evaluate("b.n") == 0)
    // A body that fails leaves the receiver as it had changed it by then, as in Swift.
    #expect(
        try swiit.evaluate("var f = ContractTally(); f.bump(); do { try f.fail() } catch {}; f.n")
            == 1
    )
    #expect(
        try swiit.evaluate(
            "var g = ContractTally(); do { try g.bumpThenFail() } catch {}; g.n"
        ) == 1
    )
    // A property a script assigns is a mutating member too.
    #expect(try swiit.evaluate("var d = ContractTally(); d.double = 10; d.n") == 5)
}

@Test func aValueABodyIsGivenIsACopy() throws {
    let swiit = interpreter()
    swiit.register(
        HostSymbol.function(
            name: "tamper",
            parameters: [.init(label: nil, name: "items", type: .list(.int))],
            returns: .int
        ) { arguments in
            // Whatever a body does with the list it was given, the script's own is as it was.
            var items = arguments[0].casting(to: [Int].self) ?? []
            items.append(99)
            return Value(items.count)
        }
    )
    #expect(try swiit.evaluate("let xs = [1, 2]; tamper(xs)") == 3)
    #expect(try swiit.evaluate("xs.count") == 2)
}

@Test func checkingAProgramRunsNoBody() throws {
    let swiit = interpreter()
    let calls = Mutex(0)
    swiit.register(
        HostSymbol.function(name: "count", returns: .int) { _ in
            calls.withLock { $0 += 1 }
            return Value(1)
        }
    )
    _ = try swiit.check("let x = count() + count()")
    #expect(calls.withLock { $0 } == 0)
    _ = try swiit.evaluate("count()")
    #expect(calls.withLock { $0 } == 1)
}

@Test func recursionThroughABodyEndsWithADiagnostic() throws {
    let swiit = interpreter(limits: Interpreter.Limits(maxCallDepth: 200))
    nonisolated(unsafe) let running = swiit
    swiit.register(
        HostSymbol.function(
            name: "twice",
            parameters: [.init(label: nil, name: "f", type: .callable)],
            returns: .int
        ) { arguments in
            _ = try running.call(arguments[0], with: [Value(1)])
            return try running.call(arguments[0], with: [Value(1)])
        }
    )
    #expect(throws: Diagnostic.self) {
        try swiit.evaluate("func g(_ n: Int) -> Int { twice { _ in g(n + 1) } }; g(0)")
    }
}

@Test func aLimitIsNotCaughtByTheScript() throws {
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 100))
    nonisolated(unsafe) let running = swiit
    swiit.register(
        HostSymbol.function(name: "spin", isThrowing: true) { _ in
            while true { try running.checkForStop() }
        }
    )
    let failure = #expect(throws: Diagnostic.self) {
        try swiit.evaluate("do { try spin() } catch { print(\"caught\") }")
    }
    guard case .limit? = failure?.kind else {
        Issue.record("expected the step limit to end the run")
        return
    }
}

@Test func aBodyThatCanThrowIsCalledWithTry() throws {
    let swiit = interpreter()
    swiit.register(HostSymbol.function(name: "risky", isThrowing: true) { _ in .nothing })
    let failure = #expect(throws: Diagnostic.self) { try swiit.evaluate("risky()") }
    #expect(failure?.kind == .type)
    _ = try swiit.evaluate("try risky()")
}
