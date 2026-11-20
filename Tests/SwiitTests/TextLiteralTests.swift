import Swiit
import Testing

// A string literal is whatever type with literal initializers is wanted, made by that type's own
// initializer, as Swift's compiler does.

@Test func aTextLiteralIsACharacterWhenACharacterIsWanted() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("let c: Character = \"a\"\nString(c)") == "a")
    #expect(try swiit.evaluate("let e: Character = \"é\"\nString(e)") == "é")
}

@Test func aTextLiteralOfSeveralCharactersIsNotACharacter() {
    let swiit = Interpreter()
    #expect(throws: Diagnostic.self) { try swiit.evaluate("let c: Character = \"ab\"") }
}

@Test func aTextLiteralIsAUnicodeScalarAndASubstringAndAFilePath() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("let u: Unicode.Scalar = \"a\"\nu.value") == 97)
    #expect(try swiit.evaluate("let s: Substring = \"abc\"\ns.count") == 3)
    #expect(try swiit.evaluate("let p: FilePath = \"/tmp/a\"\np.lastComponent!.string") == "a")
}

@Test func anOptionalOfATypeWithLiteralInitializersTakesTheLiteral() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("let c: Character? = \"x\"\nString(c!)") == "x")
}

private struct Tag: BridgedValue, Hashable, Sendable, LosslessStringConvertible,
    ExpressibleByStringLiteral
{
    let name: String
    init?(_ description: String) { name = description.uppercased() }
    init(stringLiteral value: String) { name = "literal " + value }
    var description: String { name }
}

@Test func aTextReadsAsATypeThroughItsOwnInitializers() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("Double(\"2.5\")") == 2.5)
    #expect(try swiit.evaluate("Int(\"nope\")") == .nothing)

    swiit.register(ImplementedType.Builder<Tag>())
    #expect(try swiit.evaluate("String(describing: Tag(\"a\")!)") == "A")
    #expect(try swiit.evaluate("let t: Tag = \"b\"\nString(describing: t)") == "literal b")
}
