import Foundation
import Swiit
import Testing

// What a host can ask: the symbols a script can name, a member's overloads, and types as values.

extension Interpreter {
    /// A type a script or the host declared, as a reference.
    fileprivate func type(_ name: String) -> TypeExpression {
        .named(TypeRef(named: name, in: self)!)
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

@Test func aHostCanListTheSymbolsAScriptCanName() throws {
    let swiit = interpreter()
    swiit.register("greet", labels: ["name"]) { (name: String) in "hello, \(name)" }
    swiit.register("check", throwing: true) { (x: Int) throws -> Int in x }
    _ = try swiit.evaluate("func area(width: Int, height: Int = 1) -> Int { width * height }")
    let names = Set(swiit.globals().map(\.name))
    #expect(names.isSuperset(of: ["area", "check", "greet"]))
    #expect(names.contains("print"))
    let area = try #require(swiit.globals(named: "area").first)
    let function = try #require(area.function).signature
    #expect(function.parameters.map(\.label) == ["width", "height"])
    #expect(function.parameters.map(\.arity) == [.required, .defaulted(.value(1))])
    #expect(function.returns == .int)
    #expect(try #require(swiit.globals(named: "check").first?.function).signature.isThrowing)
    // The interpreter's own are found by name, not listed.
    #expect(!swiit.globals(named: "print").isEmpty)
    #expect(swiit.globals(named: "nosuch").isEmpty)
}

@Test func aHostAsksWhatAMembersAreAndWhichOverloadACallMeans() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate(
        """
        struct Point { var x: Int; func scaled(by k: Int) -> Point { Point(x: x * k) }; func scaled(by k: Double) -> Double { Double(x) * k } }
        func f(_ n: Int) -> String { "int" }
        func f(_ s: String) -> String { "string" }
        """
    )
    let members = swiit.type("Point").members(in: swiit)
    #expect(
        Set(
            members.filter {
                if case .initializer = $0 { false } else { true }
            }
            .map(\.name)
        ) == ["x", "scaled"]
    )
    // A type's functions and variables are methods and properties; a global's are not.
    #expect(
        members.contains {
            if case .method(let method) = $0 {
                $0.name == "scaled" && !method.isStatic
            } else {
                false
            }
        }
    )
    #expect(
        members.contains {
            if case .property(let property) = $0 {
                $0.name == "x" && property.isSettable
            } else {
                false
            }
        }
    )
    #expect(
        swiit.globals(named: "f").allSatisfy { $0.function != nil }
    )
    // And what belongs to the type: its memberwise initializer.
    let initializers = members.filter {
        if case .initializer = $0 { true } else { false }
    }
    #expect(initializers.count == 1)
    #expect(try swiit.typeExpression(ofExpression: "Point(x: 1)") == swiit.type("Point"))
    #expect(try swiit.typeExpression(ofExpression: "[1, 2].map { $0 + 1 }") == .list(.int))
    let overloads = swiit.globals(named: "f").compactMap(\.function)
    #expect(
        try overloads.overload(arguments: [.init(type: .string)], in: swiit).signature
            .returns == .string
    )
    #expect(
        try overloads.overload(arguments: [.init(type: .int)], in: swiit).signature
            .parameters.first?
            .type
            == .int
    )
    #expect(throws: Diagnostic.self) {
        try overloads.overload(arguments: [.init(type: .bool)], in: swiit)
    }
    let sorted = TypeExpression.list(.int).members(named: "sorted", in: swiit)
    #expect(!sorted.isEmpty)
}

@Test func aCallByNameChoosesTheOverloadAsAScriptsCallWould() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate(
        """
        struct Point { var x: Int; func scaled(by k: Int) -> Point { Point(x: x * k) }; static func origin() -> Point { Point(x: 0) } }
        func f(_ n: Int) -> String { "int" }
        func f(_ s: String) -> String { "string" }
        func g(a: Int, b: Int = 10) -> Int { a + b }
        """
    )
    #expect(try swiit.call("f", arguments: [(nil, Value(1))]) == "int")
    #expect(try swiit.call("f", arguments: [(nil, Value("x"))]) == "string")
    #expect(try swiit.call("g", arguments: [("a", Value(1))]) == 11)
    let point = try swiit.evaluate("Point(x: 3)")
    #expect(
        try swiit.call("scaled", on: point, arguments: [("by", Value(2))]).entry("x") == 6
    )
    #expect(try swiit.call("origin", on: swiit["Point"]!).entry("x") == 0)
    #expect(try swiit.call("uppercased", on: Value("ab")) == "AB")
    #expect(try swiit.call("sorted", on: [3, 1, 2]) == [1, 2, 3])
    #expect(throws: Diagnostic.self) { try swiit.call("f", arguments: [(nil, Value(true))]) }
    #expect(throws: Diagnostic.self) { try swiit.call("nosuch") }
}

@Test func aCallByNameFindsTheBridgedOverloadByItsArguments() throws {
    let swiit = interpreter()
    #expect(try swiit.call("contains", on: [1, 2], arguments: [(nil, Value(2))]) == true)
    #expect(
        try swiit.call("joined", on: ["a", "b"], arguments: [("separator", Value("-"))]) == "a-b"
    )
}

@Test func aCallWithArgumentsMeansTheMethodNotTheProperty() throws {
    let swiit = interpreter()
    #expect(
        try swiit.call(
            "count",
            on: [1, 2, 3],
            arguments: [("where", try swiit.evaluate("{ $0 > 1 }"))]
        ) == 2
    )
    #expect(
        try swiit.call(
            "reduce",
            on: [1, 2, 3],
            arguments: [(nil, Value(0)), (nil, try swiit.evaluate("{ $0 + $1 }"))]
        ) == 6
    )
    let reduce = TypeExpression.list(.int).members(named: "reduce", in: swiit)
        .compactMap(\.method)
    #expect(
        try reduce
            .overload(arguments: [.init(type: .int), .init(type: .callable)], in: swiit)
            .name
            == "reduce"
    )
}

@Test func typeParametersCarryTheirConstraintsAsTypes() throws {
    let swiit = interpreter()
    // A host function's own type parameters, with and without constraints.
    let t = Symbol.GenericParameter(name: "T", constraints: [.comparable, .hashable])
    let u = Symbol.GenericParameter(name: "U")
    swiit.register(
        ImplementedSymbol.function(
            name: "pick",
            parameters: [
                Symbol.Parameter(name: "a", type: .parameter("T")),
                Symbol.Parameter(name: "b", type: .parameter("U")),
            ],
            returns: .parameter("T"),
            generics: [t, u],
            body: { $0[0] }
        )
    )
    let pick = swiit.globals(named: "pick").first?.function
    #expect(pick?.signature.generics == [t, u])
    // A Swift member's, with what it asks of its type: `sorted()` needs a Comparable element.
    let sorted = TypeExpression.list(.int).members(named: "sorted", in: swiit)
        .compactMap(\.signature)
    #expect(
        sorted.contains {
            $0.generics.contains {
                $0.name == "Element" && $0.constraints.contains(.comparable)
            }
        }
    )
}

@Test func aSwiftHostNamesTypesWithMetatypes() throws {
    #expect(TypeExpression(Int.self) == .int)
    #expect(TypeExpression([String].self) == .list(.string))
    #expect(TypeExpression([String: Int].self) == .dictionary(.string, .int))
    let swiit = interpreter()
    swiit.register(
        ImplementedSymbol.function(
            name: "scale",
            summary: "Multiplies.",
            parameters: [
                .init(name: "n", type: Int.self), .init(label: "by", name: "k", type: Int.self),
            ],
            returns: Int.self
        ) { arguments in
            Value(
                (arguments[0].casting(to: Int.self) ?? 0)
                    * (arguments[1].casting(to: Int.self) ?? 0)
            )
        }
    )
    #expect(try swiit.evaluate("scale(3, by: 4)") == 12)
    #expect(throws: Diagnostic.self) { try swiit.evaluate(#"scale("a", by: 4)"#) }
    let scale = try #require(swiit.globals(named: "scale").first)
    let signature = try #require(scale.function).signature
    #expect(signature.parameters.map(\.type) == [.int, .int] && signature.returns == .int)
    #expect(!TypeExpression([Int].self).members(named: "sorted", in: swiit).isEmpty)
    #expect(
        try [try #require(scale.function)]
            .overload(
                arguments: [.init(type: Int.self), .init(label: "by", type: Int.self)],
                in: swiit
            )
            .name == "scale"
    )
    // A function symbol is also a function type, and a call's arguments are the elements of a tuple
    // type.
    #expect(
        try #require(scale.function).typeExpression
            == .function(parameters: [.int, .int], returns: .int)
    )
}

@Test func aTypeIsANameWithArgumentsAFunctionOrATuple() throws {
    let swiit = interpreter()
    #expect(TypeExpression.list(.int) == .named(.array, [.int]))
    #expect(TypeExpression.optional(.string) == .named(.optional, [.string]))
    #expect(TypeExpression.list(.optional(.int)).description == "[Int?]")
    #expect(try swiit.typeExpression(ofExpression: "[1, 2]") == .list(.int))
    #expect(try swiit.typeExpression(ofExpression: #"["a": 1]"#) == .dictionary(.string, .int))
    #expect(
        try swiit.typeExpression(ofExpression: "(a: 1, b: \"x\")")
            == .tuple([.init(label: "a", type: .int), .init(label: "b", type: .string)])
    )
    _ = try swiit.evaluate("func twice(_ n: Int) -> Int { n * 2 }")
    #expect(
        try swiit.typeExpression(ofExpression: "twice")
            == .function(parameters: [.int], returns: .int)
    )
}

@Test func aTypeNameHasTheTypeOfTheType() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum Tools { static func go() {}; func other() {} }")
    let type = try swiit.typeExpression(ofExpression: "Tools")
    #expect(type == .metatype(swiit.type("Tools")))
    #expect(type.members(in: swiit).map(\.name).contains("go"))
    #expect(!type.members(in: swiit).map(\.name).contains("other"))
}

extension Symbol {
    /// The symbol, if it is a global function: what a test asks of a name that may be anything.
    fileprivate var function: Symbol.Function? {
        if case .function(let function) = self { function } else { nil }
    }
}

extension Symbol {
    /// What a call to the symbol takes and gives, if it is a function, a method or an initializer.
    fileprivate var signature: Symbol.Signature? {
        switch self {
        case .function(let symbol): symbol.signature
        case .method(let symbol): symbol.signature
        case .initializer(let symbol): symbol.signature
        default: nil
        }
    }

    fileprivate var method: Symbol.Method? {
        if case .method(let method) = self { method } else { nil }
    }
}
