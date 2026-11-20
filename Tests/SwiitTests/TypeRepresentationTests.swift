import Testing

@testable import Swiit

// What a value of each bridged type is: the core's kinds keep storage of their own, and every other
// type is a Swift value held as it is.

@Test func theCoresKindsAreBuiltInAndTheRestAreHeld() throws {
    func representation(of name: String) -> ImplementedType.Representation? {
        Bridge.types[name]?.representation
    }

    for (name, kind) in [
        ("Int", ImplementedType.Representation.int), ("Double", .double), ("Bool", .bool),
        ("String", .string), ("Array", .list), ("Dictionary", .dictionary),
    ] {
        #expect(representation(of: name) == kind)
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

@Test func aTypesRepresentationIsHowItsValuesAreStored() throws {
    let samples: [ImplementedType.Representation: Value] = [
        .bool: .bool(true), .int: .int(1), .double: .double(1), .string: .string("a"),
        .list: .list([]), .dictionary: .dictionary([:]),
    ]
    #expect(Set(samples.keys) == Set(ImplementedType.Representation.allCases).subtracting([.held]))

    for (kind, sample) in samples {
        let name = try #require(kind.name)
        let type = try #require(Bridge.types[name])

        #expect(type.representation == kind)
        #expect(type.representation.encodes(sample.storage))
        #expect(sample.representation == kind)
    }
    // A held value is stored as the Swift value it is.
    let held = SwiftValue.make(Set<Value>(), as: "Set")
    let set = try #require(Bridge.types["Set"])

    #expect(set.representation.encodes(held.storage))
    #expect(!set.representation.encodes(Value.int(1).storage))
}
