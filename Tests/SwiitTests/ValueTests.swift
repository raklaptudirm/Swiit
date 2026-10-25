import Testing

@testable import Swiit

@Test func rendersScalars() {
    #expect(Value.int(42).description == "42")
    #expect(Value.string("hi").description == "hi")
    #expect(Value.nothing.description == "")
}

@Test func rendersNestedLists() {
    let value = Value.list([.int(1), .list([.bool(true), .string("x")])])
    #expect(value.description == "[1, [true, x]]")
}

private final class Stub: Callable {
    var description: String { "stub" }
}

@Test func functionsCompareByIdentity() {
    let stub = Stub()
    #expect(Value.function(stub) == .function(stub))
    #expect(Value.function(stub) != .function(Stub()))
    #expect(Set([Value.function(stub), .function(stub)]).count == 1)
    #expect(Value.function(stub).description == "stub")
}

private final class Thing: HostObject {
    var typeName: String { "Thing" }
    var memberNames: [String] { ["size"] }
    var description: String { "a thing" }
    func member(_ name: String) -> Value? { name == "size" ? .int(3) : nil }
}

@Test func objectsCompareByIdentity() {
    let thing = Thing()
    #expect(Value.object(thing) == .object(thing))
    #expect(Value.object(thing) != .object(Thing()))
    #expect(Value.object(thing).description == "a thing")
}

@Test func enumsCompareByTypeAndCase() {
    let kind = Value.EnumCase.Enumeration(
        name: "Kind",
        cases: [.init(name: "file"), .init(name: "directory")]
    )
    let other = Value.EnumCase.Enumeration(name: "Kind", cases: [.init(name: "file")])
    #expect(
        Value.enumValue(Value.EnumCase(type: kind, name: "file"))
            == .enumValue(Value.EnumCase(type: kind, name: "file"))
    )
    #expect(
        Value.enumValue(Value.EnumCase(type: kind, name: "file"))
            != .enumValue(Value.EnumCase(type: other, name: "file"))
    )
    #expect(kind.allCases?.map(\.name) == ["file", "directory"])
    #expect(kind.member("directory") == .enumValue(Value.EnumCase(type: kind, name: "directory")))
}

@Test func enumsWithRawAndAssociatedValues() {
    let level = Value.EnumCase.Enumeration(
        name: "Level",
        cases: [.init(name: "low", rawValue: .int(1)), .init(name: "high", rawValue: .int(2))]
    )
    #expect(level.case(rawValue: .int(2))?.name == "high")
    #expect(level.case(rawValue: .int(3)) == nil)
    let result = Value.EnumCase.Enumeration(
        name: "Result",
        cases: [.init(name: "ok"), .init(name: "failed", labels: ["code", nil])]
    )
    #expect(result.allCases == nil)
    #expect(result.member("failed") == nil)  // made by calling
    #expect(
        Value.EnumCase(type: result, name: "failed", values: [.int(2), .string("x")]).description
            == "failed(code: 2, x)"
    )
}
