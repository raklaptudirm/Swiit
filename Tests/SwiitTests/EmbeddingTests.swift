import Foundation
import Swiit
import Testing

// The embedding API: what a host does with an `Interpreter` and nothing else.

private final class Log: @unchecked Sendable {
    var text = ""
}

private func interpreter(limits: Interpreter.Limits = Interpreter.Limits(), log: Log = Log()) -> Interpreter {
    Interpreter(
        host: Interpreter.Host(output: OutputSink({ log.text += $0; return true }),
                        error: OutputSink({ log.text += "err: " + $0; return true })),
        limits: limits)
}

@Test func printWritesToTheHostsOutput() throws {
    let log = Log()
    let swish = interpreter(log: log)
    _ = try swish.evaluate(#"print("hello", 1 + 1); print([1, 2])"#)
    #expect(log.text == "hello 2\n[1, 2]\n")
}

@Test func evalGivesTheValueOfTheLastExpression() throws {
    let swish = interpreter()
    #expect(try swish.evaluate("1 + 2") == 3)
    #expect(try swish.evaluate("let xs = [3, 1, 2]; xs.sorted()") == [1, 2, 3])
    // A declaration gives nothing, and stays for the next call.
    #expect(try swish.evaluate("let answer = 42") == .null)
    #expect(try swish.evaluate("answer * 2") == 84)
    // A value statement shows nothing: values come back from eval.
    let log = Log()
    _ = try interpreter(log: log).evaluate("1; 2; 3")
    #expect(log.text == "")
}

@Test func errorsAreDiagnosticsWithAKind() {
    let swish = interpreter()
    func diagnostic(_ source: String) -> Diagnostic? {
        do { _ = try swish.evaluate(source); return nil } catch { return error as? Diagnostic }
    }
    #expect(diagnostic("let = 1")?.kind == .syntax)
    #expect(diagnostic("let x: Int = \"a\"")?.kind == .type)
    #expect(diagnostic("1 / 0")?.kind == .runtime)
    #expect(diagnostic("1 / 0")?.message == "division by zero")
    // A multi-line program says which line.
    #expect(diagnostic("let a = 1\nlet b: Int = \"x\"")?.range?.startLine == 2)
}

@Test func aRegisteredClosureIsAnOrdinaryFunction() throws {
    let swish = interpreter()
    swish.register("clamp") { (x: Int, lo: Int, hi: Int) in min(max(x, lo), hi) }
    swish.register("greet", labels: ["name"]) { (name: String) in "hello, \(name)" }
    swish.register("twice") { (xs: [Int]) in xs + xs }
    #expect(try swish.evaluate("clamp(15, 0, 10)") == 10)
    #expect(try swish.evaluate(#"greet(name: "Rak")"#) == "hello, Rak")
    #expect(try swish.evaluate("twice([1, 2]).count") == 4)
    // A wrong argument is the usual type error.
    do {
        _ = try swish.evaluate(#"clamp("a", 0, 10)"#)
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .type)
        #expect(error.message.contains("Int"))
    }
}

@Test func aRegisteredClosureThatThrowsIsARuntimeDiagnostic() throws {
    struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }
    let swish = interpreter()
    swish.register("check", throwing: true) { (x: Int) throws -> Int in
        if x < 0 { throw Refused() }
        return x
    }
    #expect(try swish.evaluate("try check(1)") == 1)
    do {
        _ = try swish.evaluate("try check(-1)")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .runtime)
        #expect(error.message.contains("refused"))
    }
}

@Test func valuesSetByTheHostAreReadByTheScript() throws {
    struct Config: Encodable { var volume = 7; var name = "main" }
    let swish = interpreter()
    swish["config"] = try Value(encoding: Config())
    swish["limit"] = 10
    #expect(try swish.evaluate("config.volume * 2") == 14)
    #expect(try swish.evaluate("limit + 1") == 11)
    #expect(swish["limit"] == 10)
}

@Test func theSandboxRefusesWhatItWasNotGiven() {
    let swish = interpreter()
    func message(_ source: String) -> String? {
        do { _ = try swish.evaluate(source); return nil } catch { return (error as? Diagnostic)?.message }
    }
    // Commands and `$(…)` aren't syntax here; files, the process and the
    // environment aren't names.
    #expect(message("git status") != nil)
    #expect(message("$(date)") != nil)
    #expect(message("ls()")?.contains("ls") == true)
    #expect(message("readLine()")?.contains("readLine") == true)
    #expect(message(#"env["HOME"]"#)?.contains("env") == true)
}

@Test func anInfiniteLoopStopsAtItsLimit() {
    let swish = interpreter(limits: Interpreter.Limits(steps: 10_000))
    do {
        _ = try swish.evaluate("var n = 0; while true { n += 1 }")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .limit)
        #expect(error.message.contains("step limit"))
    } catch {
        Issue.record("\(error)")
    }
    // The interpreter is still usable afterward.
    #expect((try? swish.evaluate("1 + 1")) == 2)
}

@Test func aScriptCannotCatchALimit() {
    let swish = interpreter(limits: Interpreter.Limits(steps: 1_000))
    do {
        _ = try swish.evaluate("do { while true {} } catch { 0 }")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .limit)
    } catch {
        Issue.record("\(error)")
    }
}

@Test func deepRecursionStopsAtTheDepthLimit() {
    let swish = interpreter(limits: Interpreter.Limits(depth: 200))
    do {
        _ = try swish.evaluate("func down(_ n: Int) -> Int { down(n + 1) }; down(0)")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.message.contains("maximum call depth (200)"))
    } catch {
        Issue.record("\(error)")
    }
    // The default depth fits the stack eval runs on.
    let deep = interpreter()
    #expect((try? deep.evaluate("func sum(_ n: Int) -> Int { n == 0 ? 0 : n + sum(n - 1) }; sum(5000)")) == 12_502_500)
}

@Test func timeAndOutputAreLimitedToo() {
    let slow = interpreter(limits: Interpreter.Limits(time: .milliseconds(50)))
    do {
        _ = try slow.evaluate("while true {}")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.message == "time limit exceeded")
    } catch {
        Issue.record("\(error)")
    }
    let chatty = interpreter(limits: Interpreter.Limits(output: 100))
    do {
        _ = try chatty.evaluate(#"for i in 1...100000 { print("xxxxxxxxxx") }"#)
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .limit)
    } catch {
        Issue.record("\(error)")
    }
}

@Test func cancellingFromAnotherThreadStopsARun() {
    let swish = interpreter()
    // The run is on another thread; this one waits for it and cancels it.
    nonisolated(unsafe) let running = swish
    nonisolated(unsafe) var result: Diagnostic?
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        do { _ = try running.evaluate("while true {}") } catch { result = error as? Diagnostic }
        done.signal()
    }
    thread.start()
    Thread.sleep(forTimeInterval: 0.1)
    swish.cancel()
    done.wait()
    #expect(result?.kind == .cancelled)
}

@Test func twoInterpretersDontSeeEachOther() throws {
    let a = interpreter()
    let b = interpreter()
    a.register("only") { (x: Int) in x }
    _ = try a.evaluate("let shared = 1")
    #expect((try? b.evaluate("shared")) == nil)
    #expect((try? b.evaluate("only(1)")) == nil)
    #expect(try a.evaluate("only(shared)") == 1)
}

/// A bag of settings: every member is an Int, assigned through a `let`.
private final class Settings: DynamicObject, @unchecked Sendable {
    var values: [String: Int] = ["volume": 7]

    var typeName: String { "Settings" }
    var readType: ValueType { .optional(.int) }
    var writeType: ValueType { .optional(.int) }
    var memberNames: [String] { values.keys.sorted() }
    var description: String { "Settings" }
    func member(_ name: String) -> Value? { values[name].map { Value($0) } }
    func read(_ name: String) throws -> Value { values[name].map { Value($0) } ?? .null }
    func write(_ name: String, _ value: Value) throws {
        guard let number = value.cast(to: Int.self) else { values[name] = nil; return }
        values[name] = number
    }
}

@Test func aDynamicObjectAnswersForItsOwnMembers() throws {
    let swish = interpreter()
    let settings = Settings()
    swish["settings"] = Value(settings)
    #expect(try swish.evaluate("settings.volume") == 7)
    #expect(try swish.evaluate(#"settings["volume"]"#) == 7)
    #expect(try swish.evaluate("settings.missing") == .null)
    // Assigned through a `let`, as a class would be; nil removes.
    _ = try swish.evaluate("settings.brightness = 3; settings.volume = settings.volume! + 1")
    #expect(settings.values == ["volume": 8, "brightness": 3])
    _ = try swish.evaluate(#"settings["volume"] = nil"#)
    #expect(settings.values == ["brightness": 3])
    // The checker knows the members' type.
    do {
        _ = try swish.evaluate(#"settings.volume = "loud""#)
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .type)
    }
    #expect((try? swish.evaluate("let v: String = settings.volume")) == nil)
}

@Test func interpretersOnDifferentThreadsDontShareKeyPathReads() {
    // `sorted(by: \.n)` reads fields through a reader set for the length of
    // the call; two runs at once must each have their own.
    let program = #"[(n: 3, s: "c"), (n: 1, s: "a"), (n: 2, s: "b")].sorted(by: \.n).map { $0.s }"#
    let expected: Value = ["a", "b", "c"]
    nonisolated(unsafe) var wrong = 0
    let lock = NSLock()
    let group = DispatchGroup()
    for _ in 0..<4 {
        group.enter()
        Thread {
            let swish = interpreter()
            for _ in 0..<150 where (try? swish.evaluate(program)) != expected {
                lock.withLock { wrong += 1 }
            }
            group.leave()
        }.start()
    }
    group.wait()
    #expect(wrong == 0)
}




@Test func anExtensionAddsAStaticMethodToAnEnum() throws {
    let swish = interpreter()
    #expect(try swish.evaluate("enum Namespace {}; extension Namespace { static func answer() -> Int { 42 } }; Namespace.answer()") == 42)
    // Declared by separate evaluations, and beside a case.
    _ = try swish.evaluate("enum Level { case low }")
    _ = try swish.evaluate("extension Level { static func make() -> Level { .low } }")
    #expect(try swish.evaluate("Level.make() == .low") == true)
}

@Test func aNestedTypeIsReachedByALaterEvaluation() throws {
    let swish = interpreter()
    _ = try swish.evaluate("struct Code { struct Size { static func bigger() -> Int { 2 } }; enum Kind { case a } }")
    #expect(try swish.evaluate("Code.Size.bigger()") == 2)
    #expect(try swish.evaluate("Code.Kind.a == .a") == true)
}

private final class HostNode: HostObject, @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
    var typeName: String { "Node" }
    var memberNames: [String] { ["label", "shout"] }
    func member(_ name: String) -> Value? {
        switch name {
        case "label": Value(label)
        case "shout": Value(HostFunction(name: "shout", returns: .string) { [label] _ in Value(label.uppercased()) })
        default: nil
        }
    }
    var description: String { "Node(\(label))" }
}

@Test func aHostObjectIsTypedByTheProtocolThatDescribesIt() throws {
    let log = Log()
    let swish = interpreter(log: log)
    swish["nodes"] = [Value(HostNode("a")), Value(HostNode("b"))]
    _ = try swish.evaluate("protocol Node { var label: String { get }; func shout() -> String }")
    // It is used as the protocol says, and passes where one is asked for.
    #expect(try swish.evaluate("nodes.map { $0.shout() }") == ["A", "B"])
    #expect(try swish.evaluate("func first(_ node: Node) -> String { node.label }; first(nodes[0])") == "a")
    #expect(try swish.evaluate("let kept: [Node] = nodes; kept.count") == 2)
    // A mistake is found before anything runs.
    #expect(throws: (any Error).self) { try swish.evaluate(#"print("ran"); nodes.map { $0.nosuch }"#) }
    #expect(throws: (any Error).self) { try swish.evaluate(#"print("ran"); nodes.map { $0.label + 1 }"#) }
    #expect(throws: (any Error).self) { try swish.evaluate(#"print("ran"); nodes[0].shout(1)"#) }
    #expect(log.text == "")
}

@Test func aDictionaryIsAParameterAndAResult() throws {
    let swish = interpreter()
    swish.register("shout") { (words: [String: String]) in words.mapValues { $0.uppercased() } }
    #expect(try swish.evaluate(#"shout(["a": "x"])["a"]"#) == "X")
    // The checker knows its type: a wrong one is found before the script runs.
    #expect(throws: (any Error).self) { try swish.evaluate(#"shout(["a": 1])"#) }
    #expect(throws: (any Error).self) { try swish.evaluate("shout([1, 2])") }
}

@Test func aHostCanListTheSymbolsAScriptCanName() throws {
    let swish = interpreter()
    swish.register("greet", labels: ["name"]) { (name: String) in "hello, \(name)" }
    swish.register("check", throwing: true) { (x: Int) throws -> Int in x }
    _ = try swish.evaluate("func area(width: Int, height: Int = 1) -> Int { width * height }")
    let names = swish.symbols().map(\.name).sorted()
    #expect(names == ["area", "check", "greet"])
    let area = try #require(swish.symbols(named: "area").first)
    #expect(area.kind == .function)
    #expect(area.parameters.map(\.label) == ["width", "height"])
    #expect(area.parameters.map(\.hasDefault) == [false, true])
    #expect(area.returns == .int)
    #expect(try #require(swish.symbols(named: "check").first).isThrowing)
    // The interpreter's own are found by name, not listed.
    #expect(!swish.symbols(named: "print").isEmpty)
    #expect(swish.symbols(named: "nosuch").isEmpty)
}

@Test func aHostAsksWhatAMembersAreAndWhichOverloadACallMeans() throws {
    let swish = interpreter()
    _ = try swish.evaluate("""
    struct Point { var x: Int; func scaled(by k: Int) -> Point { Point(x: x * k) }; func scaled(by k: Double) -> Double { Double(x) * k } }
    func f(_ n: Int) -> String { "int" }
    func f(_ s: String) -> String { "string" }
    """)
    let members = swish.symbols(of: .named("Point"))
    #expect(Set(members.map(\.name)) == ["x", "scaled"])
    #expect(try swish.valueType(of: "Point(x: 1)") == .named("Point"))
    #expect(try swish.valueType(of: "[1, 2].map { $0 + 1 }") == .list(.int))
    let overloads = swish.symbols(named: "f")
    #expect(try swish.resolveOverload(among: overloads, arguments: [.init(type: .string)]).returns == .string)
    #expect(try swish.resolveOverload(among: overloads, arguments: [.init(type: .int)]).parameters.first?.type == .int)
    #expect(throws: Diagnostic.self) { try swish.resolveOverload(among: overloads, arguments: [.init(type: .bool)]) }
    let sorted = swish.symbols(named: "sorted", of: .list(.int))
    #expect(!sorted.isEmpty)
}

@Test func aWaitThatSaysHowToWakeEndsWhenTheScriptIsCancelled() throws {
    let swish = interpreter()
    swish.register("block") { () -> Int in
        let gate = DispatchSemaphore(value: 0)
        return Interpreter.whileWaiting(wake: { gate.signal() }) { gate.wait(timeout: .now() + 10) == .timedOut ? 0 : 1 }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { swish.cancel() }
    let start = Date()
    _ = try? swish.evaluate("block()")
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func aHostTypeIsDescribedAndTheDescriptionChecked() throws {
    let swish = interpreter()
    let node = HostNode("a")
    swish["node"] = Value(node)
    // Until it is described, nothing is known of the object, so nothing is missing.
    #expect(swish.missingMembers(of: node) == [])
    try swish.describe(type: "Node", as: "var label: String { get }; func shout() -> String; func missing() -> Int")
    #expect(swish.missingMembers(of: node) == ["missing"])
    #expect(try swish.evaluate("node.shout()") == "A")
    #expect(throws: (any Error).self) { try swish.evaluate("node.nosuch") }
}

private final class Preferences: DynamicObject, @unchecked Sendable {
    var values: [String: Value] = ["count": 2, "theme": "dark"]
    var typeName: String { "Preferences" }
    var memberNames: [String] { values.keys.sorted() }
    func member(_ name: String) -> Value? { values[name] }
    var description: String { "Preferences" }
    var readType: ValueType { .string }
    var writeType: ValueType { .string }
    func read(_ name: String) throws -> Value { values[name] ?? .null }
    func write(_ name: String, _ value: Value) throws { values[name] = value }
}

@Test func aDynamicObjectHasTheMembersTheHostDescribedTyped() throws {
    let swish = interpreter()
    swish["settings"] = Value(Preferences())
    // Every member has the one type, until some are described.
    #expect(try swish.evaluate("settings.theme") == "dark")
    #expect(throws: (any Error).self) { try swish.evaluate("settings.count + 1") }
    try swish.describe(type: "Preferences", as: "var count: Int { get }")
    #expect(try swish.evaluate("settings.count + 1") == 3)
    #expect(try swish.evaluate("settings.theme") == "dark")
}

@Test func evaluateCanBeAwaitedAndIsCancelledWithItsTask() async throws {
    let swish = interpreter()
    #expect(try await swish.evaluate("1 + 2") == 3)
    let running = Task { try await swish.evaluate("var n = 0; while true { n += 1 }") }
    try await Task.sleep(for: .milliseconds(150))
    running.cancel()
    do {
        _ = try await running.value
        Issue.record("expected the run to be cancelled")
    } catch let error as Diagnostic {
        #expect(error.kind == .cancelled)
    }
}

@Test func aDictionaryKeepsTheOrderItsEntriesWereAddedIn() throws {
    var dictionary = ValueDictionary()
    dictionary["z"] = 1
    dictionary["a"] = 2
    dictionary["z"] = 3
    #expect(dictionary.keys == ["z", "a"])
    #expect(dictionary.values == [3, 2])
    dictionary["z"] = nil
    #expect(dictionary.keys == ["a"])
    // Equal by what they hold, not the order they were made in.
    var other = ValueDictionary()
    other["a"] = 2
    #expect(other == dictionary)
}

@Test func aStructuredValueIsReadAsItsEntries() throws {
    struct Row: Encodable { var name = "a"; var size = 3; var kind = "file" }
    let swish = interpreter()
    swish["row"] = try Value(encoding: Row())
    // A script reads the fields by name; a host reads them in order.
    #expect(try swish.evaluate("row.size + 1") == 4)
    let entries = try #require(try swish.evaluate("row").entries)
    #expect(entries.keys == ["name", "size", "kind"])
    #expect(try swish.evaluate("(a: 1, b: 2)").entries?.keys == ["a", "b"])
    #expect(try swish.evaluate("[\"b\": 1, \"a\": 2]").entries?.keys.count == 2)
    #expect(Value(1).entries == nil)
}

@Test func aHostReadsAValueByItsKindAndCastsItToATypeItExpects() throws {
    let swish = interpreter()
    _ = try swish.evaluate("""
    struct Point { var x: Int; var y: Int }
    enum Level: Int { case low = 1, high }
    func twice(_ n: Int) -> Int { n * 2 }
    """)
    #expect(try swish.evaluate("3").kind == .int)
    #expect(try swish.evaluate("[1, 2]").kind == .list)
    #expect(try swish.evaluate("(a: 1, b: 2)").kind == .tuple)
    #expect(try swish.evaluate("Point(x: 1, y: 2)").kind == .structure)
    #expect(try swish.evaluate("Level.high").kind == .enumeration)
    #expect(try swish.evaluate("twice").kind == .function)
    #expect(Value.null.kind == .nothing)
    // `cast` is `as?`: an Int is an Int, not a Double; a list casts if every element does.
    let three = try swish.evaluate("3")
    #expect(three.cast(to: Int.self) == 3)
    #expect(three.cast(to: Double.self) == nil)
    #expect(three.cast(to: String.self) == nil)
    #expect(try swish.evaluate("[1, 2]").cast(to: [Int].self) == [1, 2])
    #expect(try swish.evaluate(#"let mixed: [Any] = [1, "a"]; mixed"#).cast(to: [Int].self) == nil)
    // `try T(value)` is the throwing form, which converts as a call does.
    #expect(try Double(three) == 3)
    #expect(throws: (any Error).self) { try String(three) }
    // A script type by name, and a structured type by shape.
    let point = try swish.evaluate("Point(x: 1, y: 2)")
    #expect(point.cast(to: .named("Point")) != nil)
    #expect(point.cast(to: .named("Level")) == nil)
    #expect(try swish.evaluate("[1, 2]").cast(to: .list(.int)) != nil)
    #expect(try swish.evaluate("[1, 2]").cast(to: .list(.string)) == nil)
    #expect(try swish.evaluate("(a: 1, b: 2)").cast(to: .tuple([.init(label: "a", type: .int), .init(label: "b", type: .int)])) != nil)
    // An enum's case, and the declaration kind of a type.
    let high = try #require(try swish.evaluate("Level.high").enumCase)
    #expect(high.type == "Level" && high.name == "high")
    #expect(swish.symbols(named: "Point").first?.kind == .structure)
    #expect(swish.symbols(named: "Level").first?.kind == .enumeration)
    #expect(swish.symbols(named: "twice").first?.kind == .function)
}

@Test func aTypeIsANameWithArgumentsAFunctionOrATuple() throws {
    let swish = interpreter()
    #expect(ValueType.list(.int) == .named("Array", [.int]))
    #expect(ValueType.optional(.string) == .named("Optional", [.string]))
    #expect(ValueType.list(.optional(.int)).description == "[Int?]")
    #expect(try swish.valueType(of: "[1, 2]") == .list(.int))
    #expect(try swish.valueType(of: #"["a": 1]"#) == .dictionary(.string, .int))
    #expect(try swish.valueType(of: "(a: 1, b: \"x\")") == .tuple([.init(label: "a", type: .int), .init(label: "b", type: .string)]))
    _ = try swish.evaluate("func twice(_ n: Int) -> Int { n * 2 }")
    #expect(try swish.valueType(of: "twice") == .function(parameters: [.int], returns: .int))
}

@Test func aSwiftHostNamesTypesWithMetatypes() throws {
    #expect(ValueType(Int.self) == .int)
    #expect(ValueType([String].self) == .list(.string))
    #expect(ValueType([String: Int].self) == .dictionary(.string, .int))
    let swish = interpreter()
    swish.register(HostFunction(
        name: "scale", summary: "Multiplies.", parameters: [.init(name: "n", type: Int.self), .init(label: "by", name: "k", type: Int.self)],
        returns: Int.self
    ) { arguments in
        Value((arguments[0].cast(to: Int.self) ?? 0) * (arguments[1].cast(to: Int.self) ?? 0))
    })
    #expect(try swish.evaluate("scale(3, by: 4)") == 12)
    #expect(throws: Diagnostic.self) { try swish.evaluate(#"scale("a", by: 4)"#) }
    let scale = try #require(swish.symbols(named: "scale").first)
    #expect(scale.parameters.map(\.type) == [.int, .int] && scale.returns == .int)
    #expect(!swish.symbols(named: "sorted", of: [Int].self).isEmpty)
    #expect(try swish.resolveOverload(among: [scale], arguments: [.init(type: Int.self), .init(label: "by", type: Int.self)]).name == "scale")
    // A function symbol is also a function type, and a call's arguments are the elements of a tuple type.
    #expect(scale.type == .function(parameters: [.int, .int], returns: .int))
}
