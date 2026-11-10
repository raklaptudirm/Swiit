import Foundation
import Swiit
import Testing

// Telling types apart: a declared type from another of the same name, IDs across interpreters, instances.

private final class Log: @unchecked Sendable {
    var text = ""
}

private func interpreter(
    limits: Interpreter.Limits = Interpreter.Limits(),
    log: Log = Log()
) -> Interpreter {
    Interpreter(
        host: Interpreter.Host(
            output: OutputSink({
                log.text += $0; return true
            }),
            error: OutputSink({
                log.text += "err: " + $0; return true
            })
        ),
        limits: limits
    )
}

private struct Point: Encodable { var x: Int }

@Test func aDeclaredTypeIsToldApartFromAnotherOfTheSameName() throws {
    let swiit = interpreter()
    try swiit.evaluate("struct Point { var x = 0 }")
    let first = try #require(Symbol.ID(named: "Point", in: swiit))
    try swiit.evaluate("struct Point { var y = 0 }")
    let second = try #require(Symbol.ID(named: "Point", in: swiit))
    #expect(first != second)
    // Both IDs still resolve, to their own declarations; a type written with the stale one is no
    // longer the type its name means.
    #expect(first.symbol(in: swiit)?.kind == .structure)
    #expect(second.symbol(in: swiit)?.id == second)
    #expect(ScriptType.named(first).members(in: swiit).isEmpty)
    #expect(!ScriptType.named(second).members(in: swiit).isEmpty)
}

@Test func anIDFromAnotherInterpreterNamesNothing() throws {
    let one = interpreter(), two = interpreter()
    try one.evaluate("struct Point { var x = 0 }")
    try two.evaluate("struct Point { var x = 0 }")
    let id = try #require(Symbol.ID(named: "Point", in: one))
    #expect(id != Symbol.ID(named: "Point", in: two))
    #expect(id.symbol(in: two) == nil)
}

@Test func hostAndParameterIDsAreByName() throws {
    let swiit = interpreter()
    #expect(Symbol.ID.int.symbol(in: swiit)?.name == "Int")
    #expect(Symbol.ID(named: "Int", in: swiit) == .int)
    #expect(Symbol.ID(hostType: "Int") == .int)
    // A host type nobody registered names nothing, and a script's type is never a host's.
    #expect(Symbol.ID(hostType: "Nope").symbol(in: swiit) == nil)
    try swiit.evaluate("struct Int2 { var x = 0 }")
    #expect(Symbol.ID(named: "Int2", in: swiit) != Symbol.ID(hostType: "Int2"))
    // A parameter is a reference with nothing under it.
    let element = Symbol.GenericParameter(name: "Element").type
    guard case .named(let parameter, _) = element else { return }
    #expect(parameter.symbol(in: swiit) == nil)
    #expect(parameter != Symbol.ID(hostType: "Element"))
}

@Test func aValueHasTheIDOfItsType() throws {
    let swiit = interpreter()
    try swiit.evaluate(
        """
        struct Point { var x = 0 }
        enum Level { case low, high }
        class Animal { }
        class Dog: Animal { }
        """
    )
    #expect(Value(3).typeID == .int)
    #expect(Value("x").typeID == .string)
    #expect(Value([Value(1)]).typeID == .array)
    #expect(Value.nothing.typeID == .optional)
    #expect(try interpreter().evaluate("(a: 1)").typeID == nil)
    let point = try swiit.evaluate("Point(x: 1)")
    #expect(point.typeID == Symbol.ID(named: "Point", in: swiit))
    #expect(try swiit.evaluate("Level.low").typeID == Symbol.ID(named: "Level", in: swiit))
    #expect(try swiit.evaluate("Dog()").typeID == Symbol.ID(named: "Dog", in: swiit))
    // A struct value of a Swift type is a host ID, by name, and names nothing registered.
    let encoded = try Value(encoding: Point(x: 1))
    #expect(encoded.typeID == Symbol.ID(hostType: "Point"))
    #expect(encoded.typeID != point.typeID)
}

@Test func isInstanceFollowsSwiftsIs() throws {
    let swiit = interpreter()
    try swiit.evaluate(
        """
        struct Point { var x = 0 }
        class Animal { }
        class Dog: Animal { }
        """
    )
    let point = try #require(Symbol.ID(named: "Point", in: swiit))
    let animal = try #require(Symbol.ID(named: "Animal", in: swiit))
    let dog = try #require(Symbol.ID(named: "Dog", in: swiit))
    #expect(try swiit.evaluate("Point(x: 1)").isInstance(of: point))
    #expect(try swiit.evaluate("Dog()").isInstance(of: dog))
    #expect(try swiit.evaluate("Dog()").isInstance(of: animal))  // a subclass is its superclass
    #expect(try !swiit.evaluate("Animal()").isInstance(of: dog))
    #expect(Value(3).isInstance(of: .any))
    #expect(Value(3).isInstance(of: .int))
    #expect(!Value(3).isInstance(of: .string))
    #expect(Value(3).isInstance(of: Int.self))
    #expect(try swiit.evaluate("{ (x: Int) in x }").isInstance(of: .function))
    // A struct value of a Swift type stands for the same-named type a script declares.
    #expect(
        try Value(encoding: Point(x: 1)).isInstance(of: point)
    )
}

@Test func aStructValueKeepsItsOwnDeclarationWhenTheTypeIsDeclaredAgain() throws {
    let swiit = interpreter()
    try swiit.evaluate("struct Point { var x = 0; var twice: Int { x * 2 } }")
    let old = try swiit.evaluate("Point(x: 2)")
    try swiit.evaluate("struct Point { var x = 0; var twice: Int { x * 3 } }")
    swiit["old"] = old
    // The old value still has the old type's members, and is not an instance of the new one.
    #expect(try swiit.evaluate("old.twice") == 4)
    #expect(try swiit.evaluate("Point(x: 2).twice") == 6)
    #expect(!old.isInstance(of: try #require(Symbol.ID(named: "Point", in: swiit))))
}
