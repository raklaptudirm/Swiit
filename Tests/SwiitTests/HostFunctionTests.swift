import Foundation
import Testing

@testable import Swiit

// A function built by hand (a layer's, which has a description of the command at run time) and
// bound with `set`.

private final class Log: @unchecked Sendable {
    var text = ""
}

@Test func aFunctionTheHostBoundIsCheckedBeforeTheScriptRuns() throws {
    let log = Log()
    let swiit = Interpreter(
        host: Interpreter.Host(
            output: OutputSink({
                log.text += $0; return true
            }),
            error: OutputSink({
                log.text += "err: " + $0; return true
            })
        )
    )
    swiit["described"] = .function(
        Function(
            name: "described",
            parameters: [Parameter(label: nil, name: "x", type: .int)],
            returnType: .int,
            body: .native { _, arguments in arguments["x"] ?? .nothing },
            isThrowing: true
        )
    )
    #expect(try swiit.evaluate("try described(1)") == .int(1))
    // A wrong argument, and a call without `try`, are found before anything runs.
    #expect(throws: (any Error).self) { try swiit.evaluate(#"print("ran"); try described("a")"#) }
    #expect(throws: (any Error).self) { try swiit.evaluate(#"print("ran"); described(1)"#) }
    #expect(log.text == "")
}

@Test func aHostFunctionChangesTheVariablesItIsGivenInPlace() throws {
    let swiit = Interpreter()
    swiit.register(
        HostSymbol.function(
            name: "exchange",
            signature: Symbol.Function(
                parameters: [
                    Symbol.Parameter(label: nil, name: "a", type: .inOut(.int)),
                    Symbol.Parameter(label: nil, name: "b", type: .inOut(.int)),
                    Symbol.Parameter(label: "plus", name: "extra", type: .int),
                ],
                returns: .int
            ),
            updating: { arguments in
                (arguments[0], arguments[1]) = (arguments[1], arguments[0])
                return arguments[2]
            }
        )
    )
    #expect(
        try swiit.evaluate("var x = 1; var y = 2; exchange(&x, &y, plus: 7); [x, y]").description
            == "[2, 1]"
    )
    #expect(
        try swiit.evaluate("var p = 1; var q = 2; exchange(&p, &q, plus: 7)").description == "7"
    )
    // Without the marks a call is refused, as for any function with `inout` parameters.
    #expect(throws: (any Error).self) {
        try swiit.evaluate("var m = 1; var n = 2; exchange(m, n, plus: 1)")
    }
}

@Test func aSubscriptOfAHostTypeIsAMemberNamedSubscript() throws {
    let swiit = Interpreter()
    var type = HostType(
        name: "Ruler",
        members: [
            .initializer(
                summary: "A ruler.",
                signature: Symbol.Function(parameters: [], returns: .named("Ruler"))
            ) { _ in SwiftValue.make(3, as: "Ruler") },
            .method(
                "subscript",
                summary: "The mark at a position.",
                parameters: [Symbol.Parameter(label: nil, name: "position", type: .int)],
                returns: .string
            ) { _, arguments in .string("mark \(try Int(arguments[0]))") },
            .method(
                "subscript",
                summary: "The mark from a position.",
                parameters: [Symbol.Parameter(label: "from", name: "start", type: .int)],
                returns: .string
            ) { _, arguments in .string("from \(try Int(arguments[0]))") },
        ]
    )
    type.genericParameters = []
    swiit.register(type)
    #expect(try swiit.evaluate("let r = Ruler(); r[2]").description == "mark 2")
}
