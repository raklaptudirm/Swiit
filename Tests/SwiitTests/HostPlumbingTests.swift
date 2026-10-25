import Testing

@testable import Swiit

private func interpreter() -> Interpreter {
    Interpreter(
        host: Interpreter.Host(output: OutputSink({ _ in true }), error: OutputSink({ _ in true }))
    )
}

// What a host that is more than an embedder builds on: internals, tested with @testable.

@Test func errorsAreReportedUnderTheHostsName() {
    final class Log: @unchecked Sendable { var text = "" }
    let log = Log()
    let sink = OutputSink({
        log.text += $0; return true
    })
    Interpreter(host: Interpreter.Host(error: sink)).report("error: no")
    Interpreter(host: Interpreter.Host(name: "tool", error: sink)).report("error: no")
    #expect(log.text == "swiit: error: no\ntool: error: no\n")
}

@Test func aComputedGlobalIsReadFreshAndCannotBeAssigned() throws {
    let swiit = interpreter()
    nonisolated(unsafe) var reads = 0
    swiit.register(computed: "counter", type: .int) {
        reads += 1; return .int(reads)
    }
    #expect(try swiit.evaluate("counter") == .int(1))
    #expect(try swiit.evaluate("counter + counter") == .int(5))  // 2 + 3: read each time
    do {
        _ = try swiit.evaluate("counter = 9")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .type)
    }
}

@Test func anAwaitWithNothingAsyncInItGivesTheValue() throws {
    // Swift only warns of it, as of one in a function that is not async.
    #expect(try interpreter().evaluate("func f() -> Int { await 1 }; f()") == .int(1))
}
