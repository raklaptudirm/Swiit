import SwiitKit
import Testing

private enum Level: String, CaseIterable, SwiitEnum {
    case low, high
}

private struct Entry: Encodable {
    let name: String
    let size: Int
}

@Test func swiftValuesConvert() throws {
    #expect(try [Int](swiitValue: .list([.int(1), .int(2)])) == [1, 2])
    #expect(try Int?(swiitValue: .nothing) == nil)
    #expect(try Double(swiitValue: .int(3)) == 3)
    #expect(try String(swiitValue: .output(Output(text: "hi", code: 0))) == "hi")
    #expect([String].swiitType == .list(.string))
    #expect(throws: SwiitError.self) { try Int(swiitValue: .string("x")) }
}

@Test func swishEnumsBridgeTheirCases() throws {
    let type = Level.swiitEnumType
    #expect(type === Level.swiitEnumType) // One type, so values compare equal.
    #expect(type.name == "Level")
    #expect(type.cases.map(\.name) == ["low", "high"])
    #expect(type.cases.map(\.rawValue) == [.string("low"), .string("high")])
    #expect(Level.high.swiitValue == .enumValue(EnumValue(type: type, name: "high")))
    #expect(try Level(swiitValue: .enumValue(EnumValue(type: type, name: "low"))) == .low)
    #expect([Level].swiitEnums.map(\.name) == ["Level"])
}

@Test func resultsOfAnyKindBecomeValues() throws {
    #expect(try Value(returning: ()) == .nothing)
    #expect(try Value(returning: [1, 2]) == .list([.int(1), .int(2)]))
    #expect(try Value(returning: Entry(name: "a", size: 2)) == .record(Record(["name": .string("a"), "size": .int(2)])))
    #expect(try Value(returning: Level.low) == Level.low.swiitValue)
}
