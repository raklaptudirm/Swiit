import Testing

@testable import Swiit

// A type a program declares is named by one reference from the moment the program is read: it is
// reserved for the declaration, which takes it when it runs.

private func inARun<T: Sendable>(_ body: @escaping @Sendable (Interpreter) throws -> T) throws -> T
{
    nonisolated(unsafe) let swiit = Interpreter()
    return try onLargeStack { try swiit.withRun { try body(swiit) } }
}

@Test func aProgramReservesAReferenceForEachTypeItDeclaresAtItsTopLevel() throws {
    let swiit = Interpreter()
    let source = """
        struct S {}
        class C {}
        enum E { case a }
        protocol P {}
        func f() { struct Inner {} }
        let x = 1
        """
    guard case .success(let program) = swiit.parse(source) else {
        Issue.record("the source did not read")
        return
    }
    let reserved = swiit.reservations(for: program)
    #expect(Set(reserved.keys) == ["S", "C", "E", "P"])
    #expect(reserved.allSatisfy { $0.value.name == $0.key })
}

@Test func aDeclarationTakesTheReferenceReservedForIt() throws {
    try inARun { swiit in
        let ref = TypeRef.declare("S")
        swiit.reservedRefs = ["S": ref]
        try swiit.declare(StructDecl(name: "S", properties: [], methods: [], initializers: []))
        #expect(swiit.structType(named: "S")?.typeRef == ref)
        #expect(swiit.reservedRefs["S"] == nil)

        let enumRef = TypeRef.declare("E")
        swiit.reservedRefs = ["E": enumRef]
        try swiit.declare(EnumDecl(name: "E", cases: []))
        #expect(swiit.declaredTypes[enumRef] != nil)
    }
}

@Test func aDeclarationWithNothingReservedMakesItsOwnReference() throws {
    try inARun { swiit in
        try swiit.declare(StructDecl(name: "S", properties: [], methods: [], initializers: []))
        try swiit.declare(StructDecl(name: "S", properties: [], methods: [], initializers: []))
        // The second declares another type of the same name.
        let refs = swiit.declaredTypes.values.compactMap { $0 as? StructType }
            .filter { $0.name == "S" }.map(\.typeRef)
        #expect(refs.count == 2 && refs[0] != refs[1])
    }
}

@Test func aRunsReservationsAreItsOwnAndEndWithIt() throws {
    let swiit = Interpreter()
    _ = try onLargeStack { try swiit.evaluate("struct Point { var x = 1 }; Point().x") }
    #expect(swiit.reservedRefs.isEmpty)
}
