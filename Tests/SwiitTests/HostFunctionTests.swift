import Foundation
@_spi(Layer) import Swiit
import Testing

// A function built by hand (a layer's, which has a description of the command at run time) and bound with `set`.

private final class Log: @unchecked Sendable {
    var text = ""
}

@Test func aFunctionTheHostBoundIsCheckedBeforeTheScriptRuns() throws {
    let log = Log()
    let swish = Interpreter(host: Interpreter.Host(output: OutputSink(write: { log.text += $0; return true }),
                                            error: OutputSink(write: { log.text += "err: " + $0; return true })))
    swish["described"] = .function(Function(
        name: "described", parameters: [Parameter(label: nil, name: "x", type: .int)], returnType: .int,
        body: .native { _, arguments in arguments["x"] ?? .nothing }, isThrowing: true))
    #expect(try swish.evaluate("try described(1)") == .int(1))
    // A wrong argument, and a call without `try`, are found before anything runs.
    #expect(throws: (any Error).self) { try swish.evaluate(#"print("ran"); try described("a")"#) }
    #expect(throws: (any Error).self) { try swish.evaluate(#"print("ran"); described(1)"#) }
    #expect(log.text == "")
}

