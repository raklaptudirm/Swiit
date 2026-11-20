import Testing

@testable import Swiit

// What a value of each bridged type is: the core's kinds keep storage of their own, and every other
// type is a Swift value held as it is.

@Test func theCoresKindsAreBuiltInAndTheRestAreHeld() throws {
    func representation(of name: String) -> ImplementedType.Representation? {
        Bridge.types[name]?.representation
    }

    for (name, kind) in [
        ("Int", Value.Builtin.int), ("Double", .double), ("Bool", .bool),
        ("String", .string), ("Array", .list), ("Dictionary", .dictionary),
    ] {
        guard case .builtin(let found)? = representation(of: name) else {
            Issue.record("\(name) should be builtin")
            continue
        }
        #expect(found == kind)
    }
    for name in ["Set", "Substring", "Character", "Range", "ClosedRange", "Date"] {
        guard case .held? = representation(of: name) else {
            Issue.record("\(name) should be held")
            continue
        }
    }
}

@Test func aTypeAHostRegistersIsHeld() {
    let swiit = Interpreter()
    let name = "Held\(Int.random(in: 0..<1_000_000))"
    swiit.register(ImplementedType(name: name))

    guard case .held? = Bridge.types[name]?.representation else {
        Issue.record("\(name) should be held")
        return
    }
}
