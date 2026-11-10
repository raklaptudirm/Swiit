import Foundation
import Swiit
import Testing

// How a host reads and makes values: by kind, by cast, by reflection, and from initializers.

extension Interpreter {
    /// A type a script or the host declared, as a reference.
    fileprivate func type(_ name: String) -> ScriptType {
        .named(Symbol.ID(named: name, in: self)!)
    }
}

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

extension Value {
    /// The entry named `name` of a structured value.
    fileprivate func entry(_ name: String) -> Value? {
        Mirror(reflecting: self).children.first { $0.label == name }?.value as? Value
    }

    /// What a host reads of a value's shape and children, as it would of any Swift value.
    fileprivate var mirror: Mirror { Mirror(reflecting: self) }
}

private struct Point: Encodable { var x: Int }

@Test func aDictionaryIsSwiftsAndComparesByWhatItHolds() throws {
    var dictionary: [Value: Value] = ["z": 1, "a": 2]
    dictionary["z"] = 3
    #expect(dictionary == ["a": 2, "z": 3])
    #expect(Value(dictionary).mirror.children.count == 2)
    dictionary["z"] = nil
    #expect(Value(dictionary) == Value(["a": 2] as [Value: Value]))
}

@Test func aValueIsReflectedAsAnySwiftValueIs() throws {
    struct Row: Encodable { var name = "a"; var size = 3; var kind = "file" }
    let swiit = interpreter()
    swiit["row"] = try Value(encoding: Row())
    // A script reads the fields by name; a host reads them in order, through a mirror.
    #expect(try swiit.evaluate("row.size + 1") == 4)
    let row = try swiit.evaluate("row").mirror
    #expect(row.displayStyle == .struct)
    #expect(row.children.map(\.label) == ["name", "size", "kind"])
    #expect(row.children.map { $0.value as? Value } == [Value("a"), Value(3), Value("file")])
    // A tuple's unlabeled elements have no label.
    let tuple = try swiit.evaluate("(a: 1, 2)").mirror
    #expect(tuple.displayStyle == .tuple)
    #expect(tuple.children.map(\.label) == ["a", nil])
    #expect(try swiit.evaluate("[1, 2]").mirror.displayStyle == .collection)
    #expect(try swiit.evaluate("[1, 2]").mirror.children.count == 2)
    let dictionary = try swiit.evaluate("[\"b\": 1, \"a\": 2]").mirror
    #expect(dictionary.displayStyle == .dictionary)
    #expect(dictionary.children.count == 2)
    #expect(Value.nothing.mirror.displayStyle == .optional)
    // A scalar has no shape of its own, and no children.
    #expect(Value(1).mirror.displayStyle == nil && Value(1).mirror.children.isEmpty)
}

@Test func aHostReadsAValueByItsKindAndCastsItToATypeItExpects() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate(
        """
        struct Point { var x: Int; var y: Int }
        enum Level: Int { case low = 1, high }
        func twice(_ n: Int) -> Int { n * 2 }
        """
    )
    #expect(try swiit.evaluate("3").typeID == .int)
    #expect(try swiit.evaluate("[1, 2]").typeID == .array)
    #expect(try swiit.evaluate("(a: 1, b: 2)").mirror.displayStyle == .tuple)
    #expect(try swiit.evaluate("Point(x: 1, y: 2)").mirror.displayStyle == .struct)
    #expect(try swiit.evaluate("Level.high").typeID?.name == "Level")
    #expect(try swiit.evaluate("twice").isInstance(of: .function))
    #expect(Value.nothing.typeID == .optional)
    // `cast` is `as?`: an Int is an Int, not a Double; a list casts if every element does.
    let three = try swiit.evaluate("3")
    #expect(three.casting(to: Int.self) == 3)
    #expect(three.casting(to: Double.self) == nil)
    #expect(three.casting(to: String.self) == nil)
    #expect(try swiit.evaluate("[1, 2]").casting(to: [Int].self) == [1, 2])
    #expect(
        try swiit.evaluate(#"let mixed: [Any] = [1, "a"]; mixed"#).casting(to: [Int].self) == nil
    )
    // `try T(value)` is the throwing form, which converts as a call does.
    #expect(try Double(three) == 3)
    #expect(throws: (any Error).self) { try String(three) }
    // A script type by name, and a structured type by shape.
    let point = try swiit.evaluate("Point(x: 1, y: 2)")
    #expect(point.casting(to: swiit.type("Point")) != nil)
    #expect(point.casting(to: swiit.type("Level")) == nil)
    #expect(try swiit.evaluate("[1, 2]").casting(to: .list(.int)) != nil)
    #expect(try swiit.evaluate("[1, 2]").casting(to: .list(.string)) == nil)
    #expect(
        try swiit.evaluate("(a: 1, b: 2)")
            .casting(to: .tuple([.init(label: "a", type: .int), .init(label: "b", type: .int)]))
            != nil
    )
    // An enum's case, and the declaration kind of a type.
    let high = try swiit.evaluate("Level.high")
    #expect(high.typeID?.name == "Level" && high.mirror.displayStyle == .enum)
    #expect((try? swiit.value(forMember: "rawValue", of: high)) == Value(2))
    #expect(swiit.globals(named: "Point").first?.kind == .structure)
    #expect(swiit.globals(named: "Level").first?.kind == .enumeration)
    #expect(swiit.globals(named: "twice").first?.function != nil)
    swiit["limit"] = 3
    #expect(
        swiit.globals(named: "limit").first?.kind == .variable(Symbol.Variable(type: .int))
    )
}

@Test func aHostReadsAValueThroughCastAndTheViews() throws {
    let swiit = interpreter()
    // `cast` is strict, as `as?` is, and fast for the plain ones.
    #expect(Value(3).casting(to: Int.self) == 3)
    #expect(Value(3).casting(to: Double.self) == nil)
    #expect(Value(3.5).casting(to: Double.self) == 3.5)
    #expect(Value("x").casting(to: String.self) == "x")
    #expect(Value(true).casting(to: Bool.self) == true)
    #expect(Value([Value(1), Value("x")]).casting(to: [Value].self)?.count == 2)
    #expect(Value([Value(1), Value("x")]).casting(to: [Int].self) == nil)
    #expect(Value(3).casting(to: Value.self) == Value(3))
    // A tuple, a struct and a function are told apart by their mirrors and their types.
    let tuple = try swiit.evaluate("(a: 1)")
    #expect(tuple.mirror.displayStyle == .tuple && tuple.typeID == nil)
    #expect(tuple.entry("a") == Value(1))
    try swiit.evaluate("struct Point { var x = 1 }")
    let point = try swiit.evaluate("Point(x: 1)")
    #expect(point.mirror.displayStyle == .struct)
    #expect(point.entry("x") == Value(1))
    #expect(try swiit.evaluate("{ (x: Int) in x }").isInstance(of: .function))
    // A Swift value held as it is has the host ID of its registered name.
    #expect(Value(Bytes(count: 1)).typeID == Symbol.ID(hostType: "Bytes"))
}

@Test func anEnumCaseIsItsTypeAndNameAndWhatItCarries() throws {
    let swiit = interpreter()
    try swiit.evaluate(
        """
        enum Level: Int { case low = 1, high }
        enum Outcome { case done, failed(code: Int, String) }
        """
    )
    let high = try swiit.evaluate("Level.high")
    #expect(high.typeID == Symbol.ID(named: "Level", in: swiit))
    #expect((try? swiit.value(forMember: "rawValue", of: high)) == Value(2))
    #expect(high.mirror.children.isEmpty)  // a case that carries nothing is its description
    // What it carries is one child labeled with the case's name, as Swift's own mirror has it: a
    // tuple of the values, each under its label or, without one, its position.
    let failedValue = try swiit.evaluate("Outcome.failed(code: 2, \"no\")")
    #expect(failedValue.mirror.displayStyle == .enum)
    #expect(failedValue.mirror.children.map(\.label) == ["failed"])
    let carried = try #require(failedValue.mirror.children.first?.value as? Value)
    #expect(carried.entry("code") == Value(2))
    #expect(carried.entry("1") == nil)  // an unlabeled one has no label
    #expect((try? swiit.value(forMember: "rawValue", of: failedValue)) == nil)
    #expect((try? swiit.value(forMember: "rawValue", of: Value(3))) == nil)
    // An enum with a raw type is RawRepresentable, as in Swift; the others are not.
    let level = ScriptType.named(try #require(Symbol.ID(named: "Level", in: swiit)))
    let outcome = ScriptType.named(try #require(Symbol.ID(named: "Outcome", in: swiit)))
    #expect(level.conforms(to: .rawRepresentable, in: swiit))
    #expect(!outcome.conforms(to: .rawRepresentable, in: swiit))
    // One unlabeled value is the child itself.
    try swiit.evaluate("enum Wrapped { case one(Int) }")
    #expect(try swiit.evaluate("Wrapped.one(5)").mirror.children.first?.value as? Value == Value(5))
    // Its type resolves to a declaration with the cases and their labels, as a symbol says.
    let symbol = try #require(failedValue.typeID.flatMap { $0.symbol(in: swiit) })
    #expect(symbol.kind == .enumeration)
    let cases = ScriptType.named(try #require(failedValue.typeID)).members(in: swiit)
        .filter { if case .enumCase = $0.kind { true } else { false } }
    #expect(cases.map(\.name).contains("failed"))
}

@Test func aStreamIsMadeOfWhatAValueGives() throws {
    let swiit = interpreter()
    func items(_ value: Value) throws -> [Value]? {
        guard let sequence = try? AnySequence<Value>(value) else { return nil }
        return Array(sequence)
    }
    // A list, a range (one at a time, so a huge one is never a list), a set; not a scalar or nil.
    #expect(try items(Value([Value(1), Value(2)])) == [Value(1), Value(2)])
    #expect(try items(swiit.evaluate("1...3")) == [Value(1), Value(2), Value(3)])
    #expect(try items(swiit.evaluate("(1...1000000000).count")) == nil)
    #expect(try items(swiit.evaluate("Set([4])")) == [Value(4)])
    #expect(try items(Value(3)) == nil)
    #expect(try items(.nothing) == nil)
    #expect(try items(swiit.evaluate("[1, 2].map { $0 * 2 }")) == [Value(2), Value(4)])
}

@Test func aThrownErrorShowsItsDescription() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate(
        #"struct Nope: Error, CustomStringConvertible { var description: String { "custom text" } }"#
    )
    do {
        _ = try swiit.evaluate("throw Nope()")
        Issue.record("it should throw")
    } catch {
        #expect(error.message == "custom text")
    }
}

@Test func aDoubleIsMadeFromAString() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate(#"let s = "1.5""#)
    #expect(try swiit.evaluate("Double(s)") == Value(1.5))
    #expect(try swiit.evaluate(#"Double("x")"#) == .nothing)
    #expect(try swiit.evaluate("Double(Substring(s))") == Value(1.5))
}

@Test func aCaseNamedLikeAKeywordNeedsNoBackticks() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum E { case `default`, other }")
    #expect(try swiit.evaluate("E.default == E.`default`") == Value(true))
    #expect(try swiit.evaluate("let e: E = .default\ne == .default") == Value(true))
}

@Test func aFunctionValueIsCalledWithoutLabels() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("func count(nodes: [Int]) -> Int { nodes.count }")
    _ = try swiit.evaluate("let f: ([Int]) -> Int = count")
    #expect(try swiit.evaluate("f([1, 2])") == Value(2))
    #expect(try swiit.evaluate("[[1], [1, 2]].map(count)") == Value([Value(1), Value(2)]))
    let value = try swiit.evaluate("f")
    #expect(try swiit.call(value, with: [Value([Value(1)])]) == Value(1))
    #expect(throws: Diagnostic.self) { try swiit.evaluate("count([1])") }
}

@Test func aHostMakesAValueOfADeclaredTypeByCallingItsInitializer() throws {
    let swiit = interpreter()
    try swiit.evaluate("struct Point { var x: Int; var y = 0 }")
    let point = try swiit.call("Point", arguments: [("x", Value(1)), ("y", Value(2))])
    #expect(point.typeID == Symbol.ID(named: "Point", in: swiit))
    #expect(point.mirror.children.map(\.label) == ["x", "y"])
    #expect(try swiit.evaluate("Point(x: 1, y: 2)") == point)
    // Through the ID, which must be a type the program declares and still means.
    let id = try #require(Symbol.ID(named: "Point", in: swiit))
    #expect(try swiit.make(id, arguments: [("x", Value(3))]).typeID == id)
    try swiit.evaluate("struct Point { var z: Int }")
    #expect(throws: Diagnostic.self) { try swiit.make(id, arguments: [("x", Value(3))]) }
}

@Test func aHostMakesAValueOfASwiftTypeByCallingItsInitializer() throws {
    let swiit = interpreter()
    #expect(try swiit.call("Int", arguments: [(nil, Value("5"))]) == 5)
    // A failable initializer's nil is the call's result, as in a script.
    #expect(try swiit.call("Int", arguments: [(nil, Value("x"))]) == .nothing)
    #expect(try swiit.call("Int", arguments: [(nil, Value("7"))]) == swiit.evaluate(#"Int("7")"#))
    #expect(try swiit.make(.int, arguments: [(nil, Value("9"))]) == 9)
    // Not a type, or a Swift type nothing registered.
    if case .named(let parameter, _) = Symbol.GenericParameter(name: "Element").type {
        #expect(throws: Diagnostic.self) { try swiit.make(parameter) }
    }
    #expect(throws: Diagnostic.self) { try swiit.call("NoSuchType", arguments: [(nil, Value(1))]) }
}

@Test func aDeclaredTypesMembersBuildValuesFromInitializers() throws {
    let swiit = interpreter()
    try swiit.declare("struct S { var w: String { String(1) }; var n: Int { Int(2.0) } }")
    try swiit.declare(
        "enum E { case a; var w: String { String(3) }; static func s() -> String { String(4) } }"
    )
    #expect(try swiit.evaluate("S().w + String(S().n)") == Value("12"))
    #expect(try swiit.evaluate("E.a.w + E.s()") == Value("34"))
    // The host's own call of a type's name chooses the same initializer.
    #expect(try swiit.call("String", arguments: [(nil, Value(5))]) == Value("5"))
}

@Test func aFunctionNamedLikeAKeywordNeedsNoBackticksAfterADot() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum editor { static func `default`() -> Int { 1 } }")
    #expect(try swiit.evaluate("editor.default() + editor.`default`()") == Value(2))
    _ = try swiit.evaluate("func `repeat`() -> Int { 3 }\nlet `class` = 4")
    #expect(try swiit.evaluate("`repeat`() + `class`") == Value(7))
    _ = try swiit.evaluate("struct Q { var `in` = 5; func `case`() -> Int { `in` } }")
    #expect(try swiit.evaluate("Q().in + Q().case()") == Value(10))
}
