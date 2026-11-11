import Foundation
import Swiit
import Testing

// The conversions generated bridges are made of, called as a bridge written outside Swiit would.

@Test func aBridgeUnwrapsWhatAScriptPassedAndWrapsWhatItGivesBack() throws {
    let swiit = Interpreter()
    let list = try swiit.evaluate("[3, 1, 2]")
    let items = try Value.Bridging.list(list)
    #expect(items.count == 3)
    #expect(try items.map { try Int($0) } == [3, 1, 2])

    let optional = try Value.Bridging.optional(.nothing) { try Int($0) }
    #expect(optional == nil)
    #expect(try Value.Bridging.optional(Value(integerLiteral: 4)) { try Int($0) } == 4)

    let word = try Value.Bridging.sequence(try swiit.evaluate(#""ab""#))
    #expect(word.count == 2)

    #expect(throws: (any Error).self) { try Value.Bridging.list(Value(integerLiteral: 1)) }
}

@Test func aBridgeBoxesARangeAsTheTypeItSaysAndReadsItBack() throws {
    let swiit = Interpreter()
    let boxed = Value.Bridging.box(1...3, as: Symbol.ID(hostType: "ClosedRange")) {
        ClosedRange<Value>(
            uncheckedBounds: (
                Value(integerLiteral: $0.lowerBound), Value(integerLiteral: $0.upperBound)
            )
        )
    }
    let range = try Value.Bridging.closedRange(boxed) { try Int($0) }
    #expect(range == 1...3)
    _ = swiit
}

@Test func aTextLiteralIsOnlyWhatTheTypeCanBe() {
    #expect(Value.Bridging.textLiteral(Character.self, "a") == "a")
    #expect(Value.Bridging.textLiteral(Character.self, "ab") == nil)
}
