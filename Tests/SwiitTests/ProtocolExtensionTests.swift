import Foundation
import Swiit
import Testing

// An extension of one of Swift's protocols reaches every value that conforms to it, the built-in
// kinds among them, by the rule that applies to any type.

@Test func anExtensionOfCollectionReachesEveryCollection() throws {
    let source = "extension Collection { func size() -> Int { count } }\n"
    let swiit = Interpreter()
    _ = try swiit.evaluate(source)
    #expect(try swiit.evaluate("[1, 2].size()") == 2)
    #expect(try swiit.evaluate("\"abc\".size()") == 3)
    #expect(try swiit.evaluate("[1: 2].size()") == 1)
    #expect(try swiit.evaluate("(1...4).size()") == 4)
}

@Test func anExtensionOfSequenceReachesWhatIteratesOnly() throws {
    let swiit = Interpreter()
    _ = try swiit.evaluate("extension Sequence { func marked() -> Int { 1 } }")
    #expect(try swiit.evaluate("(1..<3).marked()") == 1)
    // A range of Doubles is not a sequence.
    #expect(throws: Error.self) { try swiit.evaluate("(1.0...2.0).marked()") }
}

@Test func theBuiltInKindsConformToTheProtocolsSwiftGivesThem() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("[1] is Collection") == true)
    #expect(try swiit.evaluate("\"a\" is Collection") == true)
    #expect(try swiit.evaluate("[1: 2] is Sequence") == true)
}

@Test func theViewsOfADictionaryAndOfTextAreDeclaredMembers() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("[1: 2].keys") == [1])
    #expect(try swiit.evaluate("[1: 2].values") == [2])
    #expect(try swiit.evaluate("\"a\\nb\".lines") == Value(["a", "b"] as [String]))
    #expect(try swiit.evaluate("\"\".lines") == Value([] as [String]))
    // They are found as any extension's members are, so a script can read them in its own.
    _ = try swiit.evaluate("extension Dictionary { var firstKey: Int { keys[0] } }")
    #expect(try swiit.evaluate("[7: 8].firstKey") == 7)
}

@Test func anExtensionOfABuiltInTypeAddsStaticMembers() throws {
    let swiit = Interpreter()
    _ = try swiit.evaluate(
        """
        extension Int {
            static var answer: Int { 42 }
            static func make(_ n: Int) -> Int { n + 1 }
        }
        """
    )
    #expect(try swiit.evaluate("Int.answer") == 42)
    #expect(try swiit.evaluate("Int.make(6)") == 7)
    // Swift's own static members are still found.
    #expect(try swiit.evaluate("Int.max") == Value(Int.max))
}

@Test func anExtensionOfABuiltInTypeAddsSubscripts() throws {
    let swiit = Interpreter()
    _ = try swiit.evaluate(
        """
        extension Array {
            subscript(safe position: Int) -> Element? {
                position >= 0 && position < count ? self[position] : nil
            }
        }
        extension String {
            subscript(position: Int) -> Character { Array(self)[position] }
        }
        """
    )
    #expect(try swiit.evaluate("[7, 8][safe: 1]") == 8)
    #expect(try swiit.evaluate("[7, 8][safe: 5]") == .nothing)
    #expect(try swiit.evaluate("String(\"abc\"[1])") == Value("b"))
    // The type's own subscripts are still its own.
    #expect(try swiit.evaluate("[7, 8][0]") == 7)
}

@Test func anEntryOfAListOfClosuresCanBeCalled() throws {
    let swiit = Interpreter()
    #expect(
        try swiit.evaluate("var fs: [() -> Int] = [{ 10 }, { 20 }]\nfs[1]()") == 20
    )
}
