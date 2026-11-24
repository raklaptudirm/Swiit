import Testing

@testable import Swiit

// The checker and the evaluator name a type by its text, a script's own names by its declaration.
// `byReference` turns the first into the second, and `byName` back.

private func inARun<T: Sendable>(_ body: @escaping @Sendable (Interpreter) throws -> T) throws -> T
{
    nonisolated(unsafe) let swiit = Interpreter()
    return try onLargeStack { try swiit.withRun { try body(swiit) } }
}

@Test func aDeclaredTypeIsNamedByItsDeclarationAndComesBackByItsText() throws {
    try inARun { swiit in
        try swiit.declare(StructDecl(name: "Point", properties: [], methods: [], initializers: []))
        let checked = TypeExpression.optional(.list(.named("Point")))

        let named = swiit.byReference(checked)

        guard let list = named.optionalWrapped, let point = list.arrayElement,
            case .named(let reference) = point
        else {
            Issue.record("the type did not keep its shape: \(named)")
            return
        }
        #expect(reference.reference == swiit.structType(named: "Point")?.typeRef)
        #expect(swiit.byName(named) == checked)
    }
}

@Test func aTypeTheCheckerDoesNotKnowIsAnyToAScript() throws {
    try inARun { swiit in
        #expect(swiit.byReference(.unknown) == .any)
        #expect(swiit.byReference(.optional(.list(.unknown))) == .optional(.list(.any)))
    }
}

@Test func aDeclaredTypeThatWasDeclaredAgainHasGoneStale() throws {
    try inARun { swiit in
        try swiit.declare(StructDecl(name: "Point", properties: [], methods: [], initializers: []))
        let first = swiit.byReference(.named("Point"))
        try swiit.declare(StructDecl(name: "Point", properties: [], methods: [], initializers: []))

        #expect(swiit.byName(first) == nil)
        #expect(swiit.byName(swiit.byReference(.named("Point"))) == .named("Point"))
    }
}

@Test(
    arguments: [
        TypeExpression.int,
        .optional(.list(.string)),
        .dictionary(.string, .parameter("Value")),
        .named("Set", [.parameter("Element")]),
        .tuple([.init(label: "x", type: .int), .init(label: nil, type: .double)]),
        .metatype(.parameter("T")),
        .someSequence(.parameter("E")),
        .function(parameters: [.int, .string], returns: .bool, isThrowing: true),
        .keyPath(.named("Point"), .int),
    ]
)
func aTypeKeepsItsShapeWhenNamedByItsText(_ type: TypeExpression) {
    #expect(type.byText == type)
}
