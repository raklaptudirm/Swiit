@_spi(Layer) @testable import Swiit
import Testing

private func interpreter() -> Interpreter {
    Interpreter(host: Interpreter.Host(output: OutputSink({ _ in true }), error: OutputSink({ _ in true })))
}

// What a host that is more than an embedder (the shell) builds on: SPI, not part of the embedding API.

@Test func errorsAreReportedUnderTheHostsName() {
    final class Log: @unchecked Sendable { var text = "" }
    let log = Log()
    let sink = OutputSink({ log.text += $0; return true })
    Interpreter(host: Interpreter.Host(error: sink)).report("error: no")
    Interpreter(host: Interpreter.Host(name: "tool", error: sink)).report("error: no")
    #expect(log.text == "swiit: error: no\ntool: error: no\n")
}

@Test func aComputedGlobalIsReadFreshAndCannotBeAssigned() throws {
    let swish = interpreter()
    nonisolated(unsafe) var reads = 0
    swish.register(computed: "counter", type: .int) { reads += 1; return .int(reads) }
    #expect(try swish.evaluate("counter") == .int(1))
    #expect(try swish.evaluate("counter + counter") == .int(5)) // 2 + 3: read each time
    do {
        _ = try swish.evaluate("counter = 9")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .type)
    }
}

@Test func awaitNeedsAHostThatHasSomethingToWaitFor() throws {
    let swish = interpreter()
    do {
        _ = try swish.evaluate("await 1")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.message.contains("nothing to await"))
    }
    swish.register(Awaiting(operand: .int, result: .int) { value, _ in .int((value.flatMap { v -> Int? in if case .int(let n) = v { n } else { nil } } ?? 0) * 2) })
    #expect(try swish.evaluate("await 21") == .int(42))
}
