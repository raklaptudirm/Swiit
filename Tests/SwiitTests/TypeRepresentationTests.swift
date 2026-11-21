import Testing

@testable import Swiit

// What a value of each bridged type is: the core's kinds keep storage of their own, and every other
// type is a Swift value held as it is.

@Test func theCoresKindsAreBuiltInAndTheRestAreHeld() throws {
    func representation(of name: String) -> TypeImplementation.Representation? {
        Bridge.types[name]?.representation
    }

    for (name, kind) in [
        ("Int", TypeImplementation.Representation.int), ("Double", .double), ("Bool", .bool),
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
    swiit.register(TypeImplementation(name: name))

    guard case .held? = Bridge.types[name]?.representation else {
        Issue.record("\(name) should be held")
        return
    }
}

@Test func aTypesRepresentationIsHowItsValuesAreStored() throws {
    let samples: [TypeImplementation.Representation: Value] = [
        .bool: .bool(true), .int: .int(1), .double: .double(1), .string: .string("a"),
        .list: .list([]), .dictionary: .dictionary([:]),
    ]
    #expect(
        Set(samples.keys)
            == Set(TypeImplementation.Representation.allCases)
            .subtracting([.held, .record, .enumeration, .reference, .requirements])
    )

    for (kind, sample) in samples {
        let name = try #require(kind.name)
        let type = try #require(Bridge.types[name])

        #expect(type.representation == kind)
        #expect(type.representation.encodes(sample.storage))
        #expect(sample.representation == kind)
    }
    // A struct's values are records, and the type says so.
    let swiit = Interpreter()
    _ = try swiit.evaluate("struct Pair { var a: Int }")
    let pair = try swiit.evaluate("Pair(a: 1)")

    #expect(pair.representation == .record)
    #expect(TypeImplementation.Representation.record.encodes(pair.storage))
    #expect(!TypeImplementation.Representation.record.encodes(Value.int(1).storage))

    // An enum's values are one of its cases, and the type says so.
    _ = try swiit.evaluate("enum Axis { case x, y }")
    let axis = try swiit.evaluate("Axis.x")

    #expect(axis.representation == .enumeration)
    #expect(TypeImplementation.Representation.enumeration.encodes(axis.storage))

    // A class instance is a reference, and the type says so.
    _ = try swiit.evaluate("class Node { var n = 0 }")
    let node = try swiit.evaluate("Node()")

    #expect(node.representation == .reference)
    #expect(TypeImplementation.Representation.reference.encodes(node.storage))
    #expect(!TypeImplementation.Representation.reference.encodes(pair.storage))

    // No value is of a protocol, so its requirements have no storage.
    for sample in [pair, axis, node, Value.int(1)] {
        #expect(!TypeImplementation.Representation.requirements.encodes(sample.storage))
    }

    // A held value is stored as the Swift value it is.
    let held = SwiftValue.make(Set<Value>(), as: "Set")
    let set = try #require(Bridge.types["Set"])

    #expect(set.representation.encodes(held.storage))
    #expect(!set.representation.encodes(Value.int(1).storage))
}
