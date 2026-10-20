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
    var description: String { "Node(\(label))" }
    func shout() -> String { label.uppercased() }

    static let type = NativeType.Builder<HostNode>("Node")
        .property("label", \.label)
        .method("shout", HostNode.shout)
}

@Test func aHostObjectIsTypedByTheTypeThatIsRegisteredForIt() throws {
    let log = Log()
    let swish = interpreter(log: log)
    swish["nodes"] = [Value(HostNode("a")), Value(HostNode("b"))]
    swish.register(HostNode.type)
    // It is used as the protocol says, and passes where one is asked for.
    #expect(try swish.evaluate("nodes.map { $0.shout() }") == ["A", "B"])
    #expect(try swish.evaluate("func first(_ node: Node) -> String { node.label }; first(nodes[0])") == "a")
    #expect(try swish.evaluate("let kept: [Node] = nodes; kept.count") == 2)
    // A mistake is found before anything runs.
    #expect(throws: (any Error).self) { try swish.evaluate(#"print("ran1"); nodes.map { $0.nosuch }"#) }
    #expect(log.text == "")
    #expect(throws: (any Error).self) { try swish.evaluate(#"print("ran2"); nodes.map { $0.label + 1 }"#) }
    #expect(log.text == "")
    #expect(throws: (any Error).self) { try swish.evaluate(#"print("ran3"); nodes[0].shout(1)"#) }
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
    let names = Set(swish.symbols().map(\.name))
    #expect(names.isSuperset(of: ["area", "check", "greet"]))
    #expect(names.contains("print"))
    let area = try #require(swish.symbols(named: "area").first)
    let function = try #require(area.function)
    #expect(function.parameters.map(\.label) == ["width", "height"])
    #expect(function.parameters.map(\.hasDefault) == [false, true])
    #expect(function.returns == .int)
    #expect(try #require(swish.symbols(named: "check").first?.function).isThrowing)
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
    #expect(try swish.resolveOverload(among: overloads, arguments: [.init(type: .string)]).function?.returns == .string)
    #expect(try swish.resolveOverload(among: overloads, arguments: [.init(type: .int)]).function?.parameters.first?.type == .int)
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

@Test func aHostObjectsMembersAreTheRegisteredOnes() throws {
    let swish = interpreter()
    let node = HostNode("a")
    swish["node"] = Value(node)
    swish.register(HostNode.type)
    #expect(node.memberNames == ["label", "shout"])
    #expect(try swish.evaluate("node.shout()") == "A")
    #expect(throws: (any Error).self) { try swish.evaluate("node.nosuch") }
}

private final class Preferences: DynamicObject, @unchecked Sendable {
    var values: [String: Value] = ["count": 2, "theme": "dark"]
    var typeName: String { "Preferences" }
    var count: Int { (try? Int(values["count"] ?? .null)) ?? 0 }
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
    swish.register(NativeType.Builder<Preferences>("Preferences").property("count", \.count))
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
    #expect(swish.symbols(named: "Point").first?.declaration == .type(.structure))
    #expect(swish.symbols(named: "Level").first?.declaration == .type(.enumeration))
    #expect(swish.symbols(named: "twice").first?.function != nil)
    swish["limit"] = 3
    #expect(swish.symbols(named: "limit").first?.declaration == .variable(.int, isSettable: false))
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
    #expect(scale.function?.parameters.map(\.type) == [.int, .int] && scale.function?.returns == .int)
    #expect(!swish.symbols(named: "sorted", of: [Int].self).isEmpty)
    #expect(try swish.resolveOverload(among: [scale], arguments: [.init(type: Int.self), .init(label: "by", type: Int.self)]).name == "scale")
    // A function symbol is also a function type, and a call's arguments are the elements of a tuple type.
    #expect(scale.type == .function(parameters: [.int, .int], returns: .int))
}

@Test func aRunCancelledBeforeItStartsDoesNotRun() async throws {
    let swish = interpreter()
    // Cancelled at once, whichever of the request and the start of the run comes first.
    for _ in 0..<20 {
        let running = Task { try await swish.evaluate("var n = 0; while true { n += 1 }") }
        running.cancel()
        do {
            _ = try await running.value
            Issue.record("expected the run to be cancelled")
        } catch let error as Diagnostic {
            #expect(error.kind == .cancelled)
        }
    }
}

// MARK: Native types

struct Bytes: Comparable, Hashable, Sendable {
    var count: Int
    static func < (a: Bytes, b: Bytes) -> Bool { a.count < b.count }
}

@Suite struct NativeTypeTests {
    static func bytesType() -> NativeType {
        @Sendable func box(_ b: Bytes) -> Value { Value(boxing: b, as: "Bytes") }
        return NativeType(
            name: "Bytes", conformances: ["Equatable", "Hashable", "Comparable"],
            members: [
                .init(.initializer, HostFunction(name: "init", parameters: [.init(label: "count", name: "count", type: Int.self)], returns: ValueType.named("Bytes")) {
                    box(Bytes(count: try Int($0[0])))
                }),
                .init(.property, HostFunction(name: "count", parameters: [.init(name: "self", type: .named("Bytes"))], returns: Int.self) {
                    try $0[0].unboxed(Bytes.self).count.value
                }),
                .init(.method, isStatic: true, HostFunction(name: "<", parameters: [.init(name: "lhs", type: .named("Bytes")), .init(name: "rhs", type: .named("Bytes"))], returns: Bool.self) {
                    (try $0[0].unboxed(Bytes.self) < $0[1].unboxed(Bytes.self)).value
                }),
            ]
        )
    }

    @Test func aRegisteredTypeIsOneScriptsUse() throws {
        let interpreter = Interpreter()
        interpreter.register(Self.bytesType())
        let value = try interpreter.evaluate("let a = Bytes(count: 3); let b = Bytes(count: 5); a.count + b.count")
        #expect(try Int(value) == 8)
        #expect(try Bool(interpreter.evaluate("a < b")) == true)
        #expect(try Bool(interpreter.evaluate("a == Bytes(count: 3)")) == true)
        let held = try interpreter.evaluate("a").unboxed(Bytes.self)
        #expect(held == Bytes(count: 3))
    }

    @Test func aWrongUseIsCaughtBeforeItRuns() throws {
        let interpreter = Interpreter()
        interpreter.register(Self.bytesType())
        #expect(throws: Diagnostic.self) { try interpreter.evaluate("Bytes(count: \"x\")") }
        #expect(throws: Diagnostic.self) { try interpreter.evaluate("Bytes(count: 1).nope") }
    }
}

extension URL: ValueConvertible {}

@Test func aForeignTypeIsRegisteredFromKeyPathsAndMethodReferences() throws {
    let swish = interpreter()
    swish.register(NativeType.Builder<URL>()
        .property("host", \.host)
        .property("path", \.path)
        .method("appending", labels: [nil], URL.appendingPathComponent(_:))
        .initializer(labels: ["string"]) { (text: String) in URL(string: text)! })
    #expect(try swish.evaluate(#"URL(string: "https://example.com/a").appending("b").path"#) == "/a/b")
    #expect(try swish.evaluate(#"URL(string: "https://example.com/a").host"#) == "example.com")
    #expect(throws: Diagnostic.self) { try swish.evaluate(#"URL(string: "x").nosuch"#) }
}

@Test func aCallByNameChoosesTheOverloadAsAScriptsCallWould() throws {
    let swish = interpreter()
    _ = try swish.evaluate("""
    struct Point { var x: Int; func scaled(by k: Int) -> Point { Point(x: x * k) }; static func origin() -> Point { Point(x: 0) } }
    func f(_ n: Int) -> String { "int" }
    func f(_ s: String) -> String { "string" }
    func g(a: Int, b: Int = 10) -> Int { a + b }
    """)
    #expect(try swish.call("f", arguments: [(nil, Value(1))]) == "int")
    #expect(try swish.call("f", arguments: [(nil, Value("x"))]) == "string")
    #expect(try swish.call("g", arguments: [("a", Value(1))]) == 11)
    let point = try swish.evaluate("Point(x: 3)")
    #expect(try swish.call("scaled", on: point, arguments: [("by", Value(2))]).entries?[Value("x")] == 6)
    #expect(try swish.call("origin", on: swish["Point"]!).entries?[Value("x")] == 0)
    #expect(try swish.call("uppercased", on: Value("ab")) == "AB")
    #expect(try swish.call("sorted", on: [3, 1, 2]) == [1, 2, 3])
    #expect(throws: Diagnostic.self) { try swish.call("f", arguments: [(nil, Value(true))]) }
    #expect(throws: Diagnostic.self) { try swish.call("nosuch") }
}

@Test func aCheckFindsMistakesAndRunsNothing() throws {
    let log = Log()
    let swish = interpreter(log: log)
    let declared = try swish.check("""
    print("ran")
    func f(a: Int, b: Bool = false) -> String { "x" }
    enum Kind { case a, b }
    """)
    #expect(log.text == "")
    #expect(declared.map(\.name) == ["Kind", "f"])
    let f = declared.first { $0.name == "f" }?.function
    #expect(f?.parameters.map(\.label) == ["a", "b"])
    #expect(f?.parameters[1].defaultValue == false)
    #expect(throws: Diagnostic.self) { try swish.check(#"print("ran"); let x: Int = "s""#) }
    #expect(log.text == "")
    // Nothing was declared by checking.
    #expect(swish.symbols(named: "f").isEmpty)
}

@Test func wordsAndValuesConvertToTheTypeAParameterNames() throws {
    let swish = interpreter()
    _ = try swish.evaluate("enum Kind { case file, directory }")
    #expect(swish.value(fromWord: "5", as: .int) == 5)
    #expect(swish.value(fromWord: "x", as: .int) == nil)
    #expect(swish.value(fromWord: "x", as: .string) == "x")
    #expect(swish.value(fromWord: ".directory", as: .named("Kind"))?.enumCase?.name == "directory")
    #expect(swish.value(fromWord: "nope", as: .named("Kind")) == nil)
    #expect(swish.value(fromWord: "x", as: .optional(.string)) == "x")
    #expect(swish.value(fromWord: "x", as: .named("Element")) == "x")
    #expect(swish.value(ofCase: "file", in: "Kind")?.enumCase?.name == "file")
    #expect(swish.value(ofCase: "nope", in: "Kind") == nil)
    #expect(swish.convert(Value(3), to: .int) == 3)
    #expect(swish.convert(Value("3"), to: .int) == nil)
    #expect(swish.valueType(of: Value(3)) == .int)
    #expect(swish.valueType(of: [1, 2]) == .list(.int))
}

private struct Stop: Unwinding {}

@Test func aHostFunctionFailsWithAScriptErrorOrUnwinds() throws {
    let log = Log()
    let swish = interpreter(log: log)
    swish.register(HostFunction(name: "fail", returns: .int, isThrowing: true) { _ in
        throw ScriptError("nope", status: 3, value: Value(struct: "Failure", fields: ["code": Value(7)]))
    })
    swish.register(HostFunction(name: "told", isThrowing: true) { _ in throw ScriptError("already said", isReported: true) })
    swish.register(HostFunction(name: "stop", isThrowing: true) { _ in throw Stop() })
    // A script can catch a script error, and what it carries.
    _ = try swish.evaluate("struct Failure: Error { let code: Int }")
    #expect(try swish.evaluate("var r = -1; do { _ = try fail() } catch let f as Failure { r = f.code } catch { r = -2 }; r") == 7)
    #expect(try swish.evaluate("(try? fail()) == nil") == true)
    let failure = #expect(throws: Diagnostic.self) { try swish.evaluate("try fail()") }
    #expect(failure?.status == 3 && failure?.message == "nope")
    let told = #expect(throws: Diagnostic.self) { try swish.evaluate("try told()") }
    #expect(told?.isReported == true)
    // An unwinding error is not caught, runs the defers, and reaches the host.
    let stopped = #expect(throws: Diagnostic.self) {
        try swish.evaluate(#"func f() throws { defer { print("deferred") }; try stop() }; do { try f() } catch { print("caught") }"#)
    }
    #expect(stopped?.cause is Stop)
    #expect(log.text == "deferred\n")
}

private final class Mark: @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
}

@Test func theHostKeepsStateForEachTask() throws {
    let swish = interpreter()
    swish.host.makeTaskState = { Mark("task") }
    swish.taskState = Mark("main")
    nonisolated(unsafe) let running = swish
    swish.register("who") { () -> String in (running.taskState as? Mark)?.label ?? "none" }
    #expect(try swish.evaluate("who()") == "main")
    #expect(try swish.evaluate("await Task { who() }.value") == "task")
    #expect((swish.taskState as? Mark)?.label == "main")
}

@Test func aHostDeclaresWhatItAddsToTheLanguage() throws {
    let swish = interpreter()
    try swish.prelude("""
    /// A counter the host runs.
    struct Counter {
        let start: Int
        func next() -> Int
    }

    extension Sequence {
        /// Keeps the first of each.
        func firsts(_ count: Int) -> [Any]
    }

    extension Int {
        var doubled: Int { self * 2 }
    }

    /// Says hello.
    func hello(_ name: String) -> String
    """, bodies: [
        "Counter.next": { arguments in
            Value((arguments["self"]?.entries?[Value("start")].flatMap { $0.cast(to: Int.self) } ?? 0) + 1)
        },
        "Sequence.firsts": { arguments in
            Value(Array((arguments["self"]?.items.map(Array.init) ?? []).prefix(arguments["count"]?.cast(to: Int.self) ?? 0)))
        },
        "hello": { arguments in Value("hello, " + (arguments["name"]?.description ?? "")) },
    ])
    #expect(try swish.evaluate("Counter(start: 4).next()") == 5)
    #expect(try swish.evaluate("[7, 8, 9].firsts(2)") == [7, 8])
    #expect(try swish.evaluate("3.doubled") == 6)
    #expect(try swish.evaluate(#"hello("you")"#) == "hello, you")
    // What the host declared is the host's.
    #expect(swish.symbols(named: "hello").first?.isBuiltin == true)
    #expect(!swish.symbols(named: "firsts", of: .list(.int)).isEmpty)
}


@Test func aComparableNativeTypeNeedsNoOperatorsOfItsOwn() throws {
    let swish = interpreter()
    swish.register(NativeType.Builder<Bytes>("Bytes", conformances: ["Equatable", "Hashable", "Comparable"])
        .initializer(labels: ["count"]) { (count: Int) in Bytes(count: count) }
        .failableInitializer { (text: String) in Int(text).map { Bytes(count: $0) } })
    #expect(try swish.evaluate(#"Bytes("5") != nil"#) == true)
    #expect(try swish.evaluate(#"Bytes("x") == nil"#) == true)
    #expect(try swish.evaluate("Bytes(count: 1) < Bytes(count: 2)") == true)
    #expect(try swish.evaluate("Bytes(count: 3) >= Bytes(count: 2)") == true)
    #expect(try swish.evaluate("Bytes(count: 3) != Bytes(count: 2)") == true)
    #expect(try swish.evaluate("[Bytes(count: 3), Bytes(count: 1)].sorted().first == Bytes(count: 1)") == true)
    #expect(try swish.evaluate("(Bytes(count: 1)...Bytes(count: 3)).contains(Bytes(count: 2))") == true)
}

@Test func theHostIsToldAsStatementsFinish() throws {
    let swish = interpreter()
    nonisolated(unsafe) var told: [String] = []
    swish.host.statementFinished = { value, caught in told.append(caught ? "caught" : value.map { $0.description } ?? "-") }
    _ = try swish.evaluate("""
    let x = 1
    x + 1
    func f() -> Int { 7 }
    f()
    try? Int("z")
    if x == 1 { x + 10 }
    """)
    // Values of the expression statements, in order; `if` is told as it starts, and what is in it as it runs.
    #expect(told.filter { $0 != "-" } == ["2", "7", "caught", "11"])
}

private final class Handle: HostObject, @unchecked Sendable {
    let task: TaskHandle
    init(_ task: TaskHandle) { self.task = task }
    var typeName: String { "Handle" }
    var description: String { "Handle" }
}

@Test func aHostStartsAndJoinsTasksAndLetsScriptsAwaitThem() throws {
    let swish = interpreter()
    nonisolated(unsafe) let running = swish
    swish.register(HostFunction(name: "spawn", returns: .named("Handle")) { _ in
        Value(Handle(try running.startTask(state: nil) { Value(42) }))
    })
    swish.register(computed: "clock", type: .int) { Value(7) }
    swish.register(Awaiting(operand: .named("Handle"), result: .int, isHandle: { $0.cast(to: Handle.self) != nil }) { value, _ in
        guard let handle = value?.cast(to: Handle.self) else { throw ScriptError("nothing to await") }
        return try running.join(handle.task)
    })
    #expect(try swish.evaluate("clock + clock") == 14)
    #expect(try swish.evaluate("await spawn()") == 42)
    swish.finishTasks()
}
