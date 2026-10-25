import Testing

@testable import Swiit

private func run(_ source: String) throws -> Value {
    let swiit = Interpreter(
        host: Interpreter.Host(output: OutputSink({ _ in true }), error: OutputSink({ _ in true }))
    )
    return try swiit.evaluate(source)
}

private let environment = """
    @dynamicMemberLookup
    final class Environment {
        var store: [String: String] = [:]
        subscript(dynamicMember name: String) -> String? {
            get { store[name] }
            set { store[name] = newValue }
        }
        var fixed: Int { 7 }
    }
    let env = Environment()

    """

@Test func aMissingMemberIsTheDynamicSubscript() throws {
    #expect(try run(environment + #"env.HOME = "/h"; env.HOME!"#) == "/h")
    #expect(try run(environment + "env.MISSING == nil") == true)
    // A real member comes first, and `nil` removes.
    #expect(try run(environment + "env.fixed") == 7)
    #expect(try run(environment + #"env.A = "1"; env.A = nil; env.A == nil"#) == true)
}

@Test func dynamicMembersChainOptionally() throws {
    let box = """
        @dynamicMemberLookup
        struct Box {
            let items: [String: Box?]
            let n: Int
            subscript(dynamicMember name: String) -> Box? { items[name] ?? nil }
        }
        let b = Box(items: ["a": Box(items: [:], n: 2)], n: 1)

        """
    #expect(try run(box + "b.a?.n ?? -1") == 2)
    #expect(try run(box + "b.a?.zz?.n ?? -1") == -1)
}

@Test func withoutTheAttributeAMissingMemberIsAnError() {
    let source = "struct Box { subscript(dynamicMember name: String) -> String { name } }; Box().x"
    #expect(throws: Diagnostic.self) { try run(source) }
}
