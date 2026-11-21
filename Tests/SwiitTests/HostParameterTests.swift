import Testing

@testable import Swiit

// What a host's function says of its parameters is checked as a script's own are: a default that is
// a script enum's case, and a parameter of function type.

private func interpreterWithEnums() throws -> Interpreter {
    let swiit = Interpreter()
    try swiit.evaluate(
        "enum KeyTarget { case app, node }\nenum mtree { enum Mode { case normal, insert } }"
    )
    return swiit
}

private func registerCase(
    _ swiit: Interpreter,
    named function: String,
    of typeName: String,
    default defaultCase: String
) throws {
    let type = try #require(TypeRef(named: typeName, in: swiit))
    let value = try swiit.evaluate(defaultCase)
    swiit.register(
        ImplementedSymbol.function(
            name: function,
            parameters: [
                Symbol.Parameter(
                    label: "of",
                    name: "of",
                    type: .named(type),
                    arity: .defaulted(.value(value))
                )
            ],
            returns: .string
        ) { arguments in Value("\(arguments[0])") }
    )
}

@Test func aHostParameterDefaultedToAScriptEnumsCaseTakesItWhenTheArgumentIsLeftOut() throws {
    let swiit = try interpreterWithEnums()
    try registerCase(swiit, named: "target", of: "KeyTarget", default: "KeyTarget.app")
    try registerCase(swiit, named: "mode", of: "mtree.Mode", default: "mtree.Mode.normal")

    #expect(try swiit.evaluate("target()") == Value("app"))
    #expect(try swiit.evaluate("target(of: .node)") == Value("node"))
    #expect(try swiit.evaluate("mode()") == Value("normal"))
    #expect(try swiit.evaluate("mode(of: .insert)") == Value("insert"))
}

@Test func aHostParameterOfFunctionTypeTakesAScriptFunctionThatGivesNothing() throws {
    let swiit = Interpreter()
    swiit.register(
        ImplementedSymbol.function(
            name: "each",
            parameters: [
                Symbol.Parameter(name: "body", type: .function(parameters: [.int], returns: .void))
            ],
            returns: .int
        ) { arguments in
            _ = try Interpreter.running!.call(arguments[0], with: [.int(1)])
            return .int(1)
        }
    )

    // `()` and `Void` are one type, however the function says it.
    #expect(try swiit.evaluate("func a(_ n: Int) { }\neach(a)") == .int(1))
    #expect(try swiit.evaluate("func b(_ n: Int) -> Void { }\neach(b)") == .int(1))
    #expect(try swiit.evaluate("func c(_ n: Int) -> () { }\neach(c)") == .int(1))
    #expect(try swiit.evaluate("each { _ in }") == .int(1))
}
