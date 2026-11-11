import Foundation
import Swiit
import Testing

// Swift types registered for scripts: host objects, enums, foreign types, comparable and sequence types.

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

private final class Node: ScriptConvertible, CustomStringConvertible, @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
    var description: String { "Node(\(label))" }
    func shout() -> String { label.uppercased() }

    static let scriptTypeID = Symbol.ID(hostType: "Node")
    static let type = HostType.Builder<Node>("Node")
        .property("label", \.label)
        .method("shout", Node.shout)
}

extension Value {
    /// The entry named `name` of a structured value.
    fileprivate func entry(_ name: String) -> Value? {
        Mirror(reflecting: self).children.first { $0.label == name }?.value as? Value
    }

    /// What a host reads of a value's shape and children, as it would of any Swift value.
    fileprivate var mirror: Mirror { Mirror(reflecting: self) }
}

struct Bytes: Comparable, Hashable, Sendable, ScriptConvertible {
    var count: Int
    static func < (a: Bytes, b: Bytes) -> Bool { a.count < b.count }
}

extension URL: ScriptConvertible {}

enum Shade: String, CaseIterable, Comparable, Hashable, Sendable, ScriptConvertible {
    case light, dark

    static func < (a: Shade, b: Shade) -> Bool { a == .light && b == .dark }
}

struct Swatch: Hashable, Sendable, ScriptConvertible {
    var shade: Shade
    func flipped() -> Shade { shade == .light ? .dark : .light }
}

/// A thing: a class, which is equal only to itself, and says its members at run time.
private final class Pair: ScriptConvertible, CustomStringConvertible, CustomDebugStringConvertible,
    @unchecked Sendable
{
    let a: Int, b: Int
    init(_ a: Int, _ b: Int) { (self.a, self.b) = (a, b) }
    var description: String { "Pair" }
    var debugDescription: String { "Pair(\(a), \(b))" }
    var memberNames: [String]? { ["a", "b"] }
    func member(_ name: String) -> Value? { name == "a" ? Value(a) : name == "b" ? Value(b) : nil }
}

/// Data: a struct, which is equal to another that holds the same.
private struct DataPair: ScriptConvertible, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, Sendable
{
    let a: Int, b: Int
    init(_ a: Int, _ b: Int) { (self.a, self.b) = (a, b) }
    var description: String { "DataPair" }
    var debugDescription: String { "DataPair(\(a), \(b))" }
    var memberNames: [String]? { ["a", "b"] }
    func member(_ name: String) -> Value? { name == "a" ? Value(a) : name == "b" ? Value(b) : nil }
}

@Test func aHostObjectIsTypedByTheTypeThatIsRegisteredForIt() throws {
    let log = Log()
    let swiit = interpreter(log: log)
    swiit["nodes"] = [Value(Node("a")), Value(Node("b"))]
    swiit.register(Node.type)
    // It is used as the protocol says, and passes where one is asked for.
    #expect(try swiit.evaluate("nodes.map { $0.shout() }") == ["A", "B"])
    #expect(
        try swiit.evaluate("func first(_ node: Node) -> String { node.label }; first(nodes[0])")
            == "a"
    )
    #expect(try swiit.evaluate("let kept: [Node] = nodes; kept.count") == 2)
    // A mistake is found before anything runs.
    #expect(throws: (any Error).self) {
        try swiit.evaluate(#"print("ran1"); nodes.map { $0.nosuch }"#)
    }
    #expect(log.text == "")
    #expect(throws: (any Error).self) {
        try swiit.evaluate(#"print("ran2"); nodes.map { $0.label + 1 }"#)
    }
    #expect(log.text == "")
    #expect(throws: (any Error).self) { try swiit.evaluate(#"print("ran3"); nodes[0].shout(1)"#) }
    #expect(log.text == "")
}

@Test func aHostObjectsMembersAreTheRegisteredOnes() throws {
    let swiit = interpreter()
    let node = Node("a")
    swiit["node"] = Value(node)
    swiit.register(Node.type)
    #expect(
        Set(ScriptType.named(Node.scriptTypeID).members(in: swiit).map(\.name))
            .isSuperset(of: ["label", "shout"])
    )
    #expect(try swiit.evaluate("node.shout()") == "A")
    #expect(throws: (any Error).self) { try swiit.evaluate("node.nosuch") }
}

@Test func anEnumIsRegisteredOnItsOwn() throws {
    // For declarations that name it, before anything registered takes one.
    let swiit = interpreter()
    swiit.register(Shade.self)
    try swiit.declare(
        "func paint(_ shade: Shade) -> String",
        bodies: [
            "paint": { arguments in Value("painted \(try Shade(arguments["shade"]!).rawValue)") }
        ]
    )
    #expect(try swiit.evaluate("paint(.dark)") == "painted dark")
    #expect(try swiit.evaluate("Shade.allCases.count") == 2)

    // Comparable in Swift, so in scripts too: by the cases' order.
    #expect(try swiit.evaluate("Shade.light < .dark") == true)
    #expect(
        try swiit.evaluate("[Shade.dark, .light].sorted().map { $0.rawValue }") == [
            "light", "dark",
        ]
    )
}

@Test func anEnumATypesMembersUseIsDeclaredWithIt() throws {
    // Nothing else registered names `Shade`: registering `Swatch` declares it, as registering a
    // function that takes one does.
    let swiit = interpreter()
    swiit.register(
        HostType.Builder<Swatch>()
            .property("shade", \.shade)
            .method("flipped", Swatch.flipped)
    )
    swiit["swatch"] = Value(Swatch(shade: .dark))

    #expect(try swiit.evaluate("swatch.shade == .dark") == true)
    #expect(try swiit.evaluate("swatch.flipped() == Shade.light") == true)
    #expect(
        try swiit.evaluate(
            "func f(_ s: Shade) -> String { switch s { case .light: return \"l\"; case .dark: return \"d\" } }; f(swatch.shade)"
        ) == "d"
    )
    #expect(try swiit.evaluate("Shade.dark.rawValue") == "dark")
    #expect(try Shade(swiit.evaluate("swatch.shade")) == .dark)

    // It's an enum to a host too: its cases are listed, and a case is had by name.
    let shade = Symbol.ID(named: "Shade", in: swiit)
    #expect(shade != nil)
    let cases = ScriptType.named(shade!).members(in: swiit)
        .filter { if case .enumCase = $0.kind { true } else { false } }
    #expect(cases.map(\.name) == ["light", "dark"])
    #expect(try shade.flatMap { $0.enumCase(named: "light", in: swiit) }.map(Shade.init) == .light)
}

@Test func aForeignTypeIsRegisteredFromKeyPathsAndMethodReferences() throws {
    let swiit = interpreter()
    swiit.register(
        HostType.Builder<URL>()
            .property("host", \.host)
            .property("path", \.path)
            .method("appending", labels: [nil], URL.appendingPathComponent(_:))
            .initializer(labels: ["string"]) { (text: String) in URL(string: text)! }
    )
    #expect(
        try swiit.evaluate(#"URL(string: "https://example.com/a").appending("b").path"#) == "/a/b"
    )
    #expect(try swiit.evaluate(#"URL(string: "https://example.com/a").host"#) == "example.com")
    #expect(throws: Diagnostic.self) { try swiit.evaluate(#"URL(string: "x").nosuch"#) }
}

@Test func aComparableNativeTypeNeedsNoOperatorsOfItsOwn() throws {
    let swiit = interpreter()
    swiit.register(
        HostType.Builder<Bytes>("Bytes")
            .initializer(labels: ["count"]) { (count: Int) in Bytes(count: count) }
            .failableInitializer { (text: String) in Int(text).map { Bytes(count: $0) } }
    )
    #expect(try swiit.evaluate(#"Bytes("5") != nil"#) == true)
    #expect(try swiit.evaluate(#"Bytes("x") == nil"#) == true)
    #expect(try swiit.evaluate("Bytes(count: 1) < Bytes(count: 2)") == true)
    #expect(try swiit.evaluate("Bytes(count: 3) >= Bytes(count: 2)") == true)
    #expect(try swiit.evaluate("Bytes(count: 3) != Bytes(count: 2)") == true)
    #expect(
        try swiit.evaluate("[Bytes(count: 3), Bytes(count: 1)].sorted().first == Bytes(count: 1)")
            == true
    )
    #expect(
        try swiit.evaluate("(Bytes(count: 1)...Bytes(count: 3)).contains(Bytes(count: 2))") == true
    )
}

@Test func aSequenceNativeTypeHasWhatAListHasOverItsItems() throws {
    struct Lines: Sequence, Sendable, Hashable {
        var lines: [String];
        func makeIterator() -> IndexingIterator<[String]> { lines.makeIterator() }
    }
    let swiit = interpreter()
    swiit.register(
        HostType.Builder<Lines>("Lines")
            .initializer(labels: ["lines"]) { (lines: [String]) in Lines(lines: lines) }
    )
    #expect(try swiit.evaluate(#"Lines(lines: ["b", "a"]).sorted()"#) == ["a", "b"])
    #expect(try swiit.evaluate(#"Lines(lines: ["b", "a"]).count"#) == 2)
    #expect(try swiit.evaluate(#"Lines(lines: ["b", "a"]).map { $0 + "!" }"#) == ["b!", "a!"])
    #expect(
        try swiit.call("sorted", on: swiit.evaluate(#"Lines(lines: ["b", "a"])"#)) == ["a", "b"]
    )
}

@Test func aHostTypeIsEqualToItselfOrByWhatItHolds() {
    // A class is equal only to itself; a struct is equal to one that holds the same.
    #expect(Value(Pair(1, 2)) != Value(Pair(1, 2)))
    let thing = Pair(1, 2)
    #expect(Value(thing) == Value(thing))
    #expect(Value(DataPair(1, 2)) == Value(DataPair(1, 2)))
    #expect(Value(DataPair(1, 2)) != Value(DataPair(2, 1)))
    #expect(Set([Value(DataPair(1, 2)), Value(DataPair(1, 2))]).count == 1)
    // Both say their members, so both are read as a record by their mirrors.
    #expect(Value(DataPair(1, 2)).mirror.displayStyle == .class)
    #expect(Value(DataPair(1, 2)).mirror.children.map(\.label) == ["a", "b"])
    #expect(Value(thing).mirror.children.map(\.label) == ["a", "b"])
}

@Suite struct NativeTypeTests {
    static func bytesType() -> HostType.Builder<Bytes> {
        let bytes = Symbol.ID(hostType: "Bytes")
        @Sendable func box(_ b: Bytes) -> Value { Value(b) }
        return HostType.Builder<Bytes>("Bytes")
            .member(
                .initializer(
                    parameters: [.init(label: "count", name: "count", type: Int.self)],
                    returns: .named(bytes)
                ) { box(Bytes(count: try Int($0[0]))) }
            )
            .member(.property("count", type: .int) { try Bytes($0).count.value })
            .member(
                .staticMethod(
                    "<",
                    parameters: [
                        .init(name: "lhs", type: .named(bytes)),
                        .init(name: "rhs", type: .named(bytes)),
                    ],
                    returns: .bool
                ) { (try Bytes($0[0]) < Bytes($0[1])).value }
            )
    }

    @Test func aRegisteredTypeIsOneScriptsUse() throws {
        let interpreter = Interpreter()
        interpreter.register(Self.bytesType())
        let value = try interpreter.evaluate(
            "let a = Bytes(count: 3); let b = Bytes(count: 5); a.count + b.count"
        )
        #expect(try Int(value) == 8)
        #expect(try Bool(interpreter.evaluate("a < b")) == true)
        #expect(try Bool(interpreter.evaluate("a == Bytes(count: 3)")) == true)
        let held = try Bytes(interpreter.evaluate("a"))
        #expect(held == Bytes(count: 3))
    }

    @Test func aWrongUseIsCaughtBeforeItRuns() throws {
        let interpreter = Interpreter()
        interpreter.register(Self.bytesType())
        #expect(throws: Diagnostic.self) { try interpreter.evaluate("Bytes(count: \"x\")") }
        #expect(throws: Diagnostic.self) { try interpreter.evaluate("Bytes(count: 1).nope") }
    }
}

@Test func aTypeWrittenByHandSaysWhatItIsGenericOverAndWhatItConformsTo() throws {
    let swiit = interpreter()
    var pile = HostType(name: "Pile")
    pile.genericParameters = ["Element"]
    pile.conformances = ["Hashable": [], "Sequence": [Symbol.GenericParameter(name: "Element")]]
    pile.associatedTypes["Element"] = .parameter("Element")
    pile.arrayLiteral = { _ in .nothing }
    let id = swiit.register(pile)

    #expect(id == Symbol.ID(hostType: "Pile"))
    #expect(ScriptType.named(id, [.int]).conforms(to: Symbol.ID(hostType: "Hashable"), in: swiit))
    #expect(ScriptType.named(id, [.int]).conforms(to: .sequence, in: swiit))
}
