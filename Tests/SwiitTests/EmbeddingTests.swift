import Foundation
import Swiit
import Testing

// The embedding API: what a host does with an `Interpreter` and nothing else.

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

@Test func printWritesToTheHostsOutput() throws {
    let log = Log()
    let swiit = interpreter(log: log)
    _ = try swiit.evaluate(#"print("hello", 1 + 1); print([1, 2])"#)
    #expect(log.text == "hello 2\n[1, 2]\n")
}

@Test func evalGivesTheValueOfTheLastExpression() throws {
    let swiit = interpreter()
    #expect(try swiit.evaluate("1 + 2") == 3)
    #expect(try swiit.evaluate("let xs = [3, 1, 2]; xs.sorted()") == [1, 2, 3])
    // A declaration gives nothing, and stays for the next call.
    #expect(try swiit.evaluate("let answer = 42") == .nothing)
    #expect(try swiit.evaluate("answer * 2") == 84)
    // A value statement shows nothing: values come back from eval.
    let log = Log()
    _ = try interpreter(log: log).evaluate("1; 2; 3")
    #expect(log.text == "")
}

@Test func errorsAreDiagnosticsWithAKind() {
    let swiit = interpreter()
    func diagnostic(_ source: String) -> Diagnostic? {
        do { _ = try swiit.evaluate(source); return nil } catch { return error as? Diagnostic }
    }
    #expect(diagnostic("let = 1")?.isSyntax == true)
    #expect(diagnostic("let x: Int = \"a\"")?.kind == .type)
    #expect(diagnostic("1 / 0")?.isRuntime == true)
    #expect(diagnostic("1 / 0")?.message == "division by zero")
    // A multi-line program says which line.
    #expect(diagnostic("let a = 1\nlet b: Int = \"x\"")?.range?.startLine == 2)
}

@Test func aRegisteredClosureIsAnOrdinaryFunction() throws {
    let swiit = interpreter()
    swiit.register("clamp") { (x: Int, lo: Int, hi: Int) in min(max(x, lo), hi) }
    swiit.register("greet", labels: ["name"]) { (name: String) in "hello, \(name)" }
    swiit.register("twice") { (xs: [Int]) in xs + xs }
    #expect(try swiit.evaluate("clamp(15, 0, 10)") == 10)
    #expect(try swiit.evaluate(#"greet(name: "Rak")"#) == "hello, Rak")
    #expect(try swiit.evaluate("twice([1, 2]).count") == 4)
    // A wrong argument is the usual type error.
    do {
        _ = try swiit.evaluate(#"clamp("a", 0, 10)"#)
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .type)
        #expect(error.message.contains("Int"))
    }
}

@Test func aRegisteredClosureThatThrowsIsARuntimeDiagnostic() throws {
    struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }
    let swiit = interpreter()
    swiit.register("check", throwing: true) { (x: Int) throws -> Int in
        if x < 0 { throw Refused() }
        return x
    }
    #expect(try swiit.evaluate("try check(1)") == 1)
    do {
        _ = try swiit.evaluate("try check(-1)")
        Issue.record("expected a diagnostic")
    } catch let error {
        guard case .runtime = error.kind else {
            Issue.record("expected a run-time failure"); return
        }
        #expect(error.message.contains("refused"))
    }
}

@Test func valuesSetByTheHostAreReadByTheScript() throws {
    struct Config: Encodable { var volume = 7; var name = "main" }
    let swiit = interpreter()
    swiit["config"] = try Value(encoding: Config())
    swiit["limit"] = 10
    #expect(try swiit.evaluate("config.volume * 2") == 14)
    #expect(try swiit.evaluate("limit + 1") == 11)
    #expect(swiit["limit"] == 10)
}

@Test func theSandboxRefusesWhatItWasNotGiven() {
    let swiit = interpreter()
    func message(_ source: String) -> String? {
        do { _ = try swiit.evaluate(source); return nil } catch {
            return (error as? Diagnostic)?.message
        }
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
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 10_000))
    do {
        _ = try swiit.evaluate("var n = 0; while true { n += 1 }")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .limit)
        #expect(error.message.contains("step limit"))
    } catch {
        Issue.record("\(error)")
    }
    // The interpreter is still usable afterward.
    #expect((try? swiit.evaluate("1 + 1")) == 2)
}

@Test func aScriptCannotCatchALimit() {
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 1_000))
    do {
        _ = try swiit.evaluate("do { while true {} } catch { 0 }")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.kind == .limit)
    } catch {
        Issue.record("\(error)")
    }
}

@Test func deepRecursionStopsAtTheDepthLimit() {
    let swiit = interpreter(limits: Interpreter.Limits(maxCallDepth: 200))
    do {
        _ = try swiit.evaluate("func down(_ n: Int) -> Int { down(n + 1) }; down(0)")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.message.contains("maximum call depth (200)"))
    } catch {
        Issue.record("\(error)")
    }
    // The default depth fits the stack eval runs on.
    let deep = interpreter()
    #expect(
        (try? deep.evaluate("func sum(_ n: Int) -> Int { n == 0 ? 0 : n + sum(n - 1) }; sum(5000)"))
            == 12_502_500
    )
}

@Test func timeAndOutputAreLimitedToo() {
    let slow = interpreter(limits: Interpreter.Limits(timeLimit: .milliseconds(50)))
    do {
        _ = try slow.evaluate("while true {}")
        Issue.record("expected a diagnostic")
    } catch let error {
        #expect(error.message == "time limit exceeded")
    } catch {
        Issue.record("\(error)")
    }
    let chatty = interpreter(limits: Interpreter.Limits(maxOutputBytes: 100))
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
    let swiit = interpreter()
    // The run is on another thread; this one waits for it and cancels it.
    nonisolated(unsafe) let running = swiit
    nonisolated(unsafe) var result: Diagnostic?
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        do { _ = try running.evaluate("while true {}") } catch { result = error as? Diagnostic }
        done.signal()
    }
    thread.start()
    Thread.sleep(forTimeInterval: 0.1)
    swiit.cancel()
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

@Test func interpretersOnDifferentThreadsDontShareKeyPathReads() {
    // `map(\.n)` reads fields through a reader set for the length of
    // the call; two runs at once must each have their own.
    let program = #"[(n: 3, s: "c"), (n: 1, s: "a"), (n: 2, s: "b")].map(\.s)"#
    let expected: Value = ["c", "a", "b"]
    nonisolated(unsafe) var wrong = 0
    let lock = NSLock()
    let group = DispatchGroup()
    for _ in 0..<4 {
        group.enter()
        Thread {
            let swiit = interpreter()
            for _ in 0..<150 where (try? swiit.evaluate(program)) != expected {
                lock.withLock { wrong += 1 }
            }
            group.leave()
        }
        .start()
    }
    group.wait()
    #expect(wrong == 0)
}

@Test func anExtensionAddsAStaticMethodToAnEnum() throws {
    let swiit = interpreter()
    #expect(
        try swiit.evaluate(
            "enum Namespace {}; extension Namespace { static func answer() -> Int { 42 } }; Namespace.answer()"
        ) == 42
    )
    // Declared by separate evaluations, and beside a case.
    _ = try swiit.evaluate("enum Level { case low }")
    _ = try swiit.evaluate("extension Level { static func make() -> Level { .low } }")
    #expect(try swiit.evaluate("Level.make() == .low") == true)
}

@Test func aNestedTypeIsReachedByALaterEvaluation() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate(
        "struct Code { struct Size { static func bigger() -> Int { 2 } }; enum Kind { case a } }"
    )
    #expect(try swiit.evaluate("Code.Size.bigger()") == 2)
    #expect(try swiit.evaluate("Code.Kind.a == .a") == true)
}

private final class HostNode: HostObject, @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
    var typeName: String { "Node" }
    var description: String { "Node(\(label))" }
    func shout() -> String { label.uppercased() }

    static let type = HostType.Builder<HostNode>("Node")
        .property("label", \.label)
        .method("shout", HostNode.shout)
}

@Test func aHostObjectIsTypedByTheTypeThatIsRegisteredForIt() throws {
    let log = Log()
    let swiit = interpreter(log: log)
    swiit["nodes"] = [Value(HostNode("a")), Value(HostNode("b"))]
    swiit.register(HostNode.type)
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

@Test func aDictionaryIsAParameterAndAResult() throws {
    let swiit = interpreter()
    swiit.register("shout") { (words: [String: String]) in words.mapValues { $0.uppercased() } }
    #expect(try swiit.evaluate(#"shout(["a": "x"])["a"]"#) == "X")
    // The checker knows its type: a wrong one is found before the script runs.
    #expect(throws: (any Error).self) { try swiit.evaluate(#"shout(["a": 1])"#) }
    #expect(throws: (any Error).self) { try swiit.evaluate("shout([1, 2])") }
}

@Test func aHostCanListTheSymbolsAScriptCanName() throws {
    let swiit = interpreter()
    swiit.register("greet", labels: ["name"]) { (name: String) in "hello, \(name)" }
    swiit.register("check", throwing: true) { (x: Int) throws -> Int in x }
    _ = try swiit.evaluate("func area(width: Int, height: Int = 1) -> Int { width * height }")
    let names = Set(swiit.symbols().map(\.name))
    #expect(names.isSuperset(of: ["area", "check", "greet"]))
    #expect(names.contains("print"))
    let area = try #require(swiit.symbols(named: "area").first)
    let function = try #require(area.function)
    #expect(function.parameters.map(\.label) == ["width", "height"])
    #expect(function.parameters.map(\.arity) == [.required, .defaulted(.value(1))])
    #expect(function.returns == .int)
    #expect(try #require(swiit.symbols(named: "check").first?.function).isThrowing)
    // The interpreter's own are found by name, not listed.
    #expect(!swiit.symbols(named: "print").isEmpty)
    #expect(swiit.symbols(named: "nosuch").isEmpty)
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
    let members = swiit.symbols(in: .named("Point"))
    #expect(
        Set(
            members.filter {
                if case .initializer = $0.kind { false } else { true }
            }
            .map(\.name)
        ) == ["x", "scaled"]
    )
    // A type's functions and variables are methods and properties; a global's are not.
    #expect(
        members.contains {
            if case .method(let method) = $0.kind {
                $0.name == "scaled" && !method.isStatic
            } else {
                false
            }
        }
    )
    #expect(
        members.contains {
            if case .property(let property) = $0.kind {
                $0.name == "x" && property.variable.isSettable
            } else {
                false
            }
        }
    )
    #expect(
        swiit.symbols(named: "f").allSatisfy { if case .function = $0.kind { true } else { false } }
    )
    // And what belongs to the type: its memberwise initializer.
    let initializers = members.filter {
        if case .initializer = $0.kind { true } else { false }
    }
    #expect(initializers.count == 1)
    #expect(try swiit.scriptType(ofExpression: "Point(x: 1)") == .named("Point"))
    #expect(try swiit.scriptType(ofExpression: "[1, 2].map { $0 + 1 }") == .list(.int))
    let overloads = swiit.symbols(named: "f")
    #expect(
        try swiit.overload(among: overloads, arguments: [.init(type: .string)]).function?
            .returns == .string
    )
    #expect(
        try swiit.overload(among: overloads, arguments: [.init(type: .int)]).function?
            .parameters.first?
            .type
            == .int
    )
    #expect(throws: Diagnostic.self) {
        try swiit.overload(among: overloads, arguments: [.init(type: .bool)])
    }
    let sorted = swiit.symbols(named: "sorted", in: .list(.int))
    #expect(!sorted.isEmpty)
}

@Test func aWaitThatSaysHowToWakeEndsWhenTheScriptIsCancelled() throws {
    let swiit = interpreter()
    swiit.register("block") { () -> Int in
        let gate = DispatchSemaphore(value: 0)
        return Interpreter.whileWaiting(wake: { gate.signal() }) {
            gate.wait(timeout: .now() + 10) == .timedOut ? 0 : 1
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { swiit.cancel() }
    let start = Date()
    _ = try? swiit.evaluate("block()")
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func aHostObjectsMembersAreTheRegisteredOnes() throws {
    let swiit = interpreter()
    let node = HostNode("a")
    swiit["node"] = Value(node)
    swiit.register(HostNode.type)
    #expect(node.memberNames == ["label", "shout"])
    #expect(try swiit.evaluate("node.shout()") == "A")
    #expect(throws: (any Error).self) { try swiit.evaluate("node.nosuch") }
}

@Test func evaluateCanBeAwaitedAndIsCancelledWithItsTask() async throws {
    let swiit = interpreter()
    #expect(try await swiit.evaluate("1 + 2") == 3)
    let running = Task { try await swiit.evaluate("var n = 0; while true { n += 1 }") }
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
    var dictionary = Value.Dictionary()
    dictionary["z"] = 1
    dictionary["a"] = 2
    dictionary["z"] = 3
    #expect(dictionary.keys == ["z", "a"])
    #expect(dictionary.values == [3, 2])
    dictionary["z"] = nil
    #expect(dictionary.keys == ["a"])
    // Equal by what they hold, not the order they were made in.
    var other = Value.Dictionary()
    other["a"] = 2
    #expect(other == dictionary)
}

@Test func aStructuredValueIsReadAsItsEntries() throws {
    struct Row: Encodable { var name = "a"; var size = 3; var kind = "file" }
    let swiit = interpreter()
    swiit["row"] = try Value(encoding: Row())
    // A script reads the fields by name; a host reads them in order.
    #expect(try swiit.evaluate("row.size + 1") == 4)
    let entries = try #require(try swiit.evaluate("row").entries)
    #expect(entries.keys == ["name", "size", "kind"])
    #expect(try swiit.evaluate("(a: 1, b: 2)").entries?.keys == ["a", "b"])
    #expect(try swiit.evaluate("[\"b\": 1, \"a\": 2]").entries?.keys.count == 2)
    #expect(Value(1).entries == nil)
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
    #expect(try swiit.evaluate("3").kind == .int)
    #expect(try swiit.evaluate("[1, 2]").kind == .list)
    #expect(try swiit.evaluate("(a: 1, b: 2)").kind == .tuple)
    #expect(try swiit.evaluate("Point(x: 1, y: 2)").kind == .structure)
    #expect(try swiit.evaluate("Level.high").kind == .enumeration)
    #expect(try swiit.evaluate("twice").kind == .function)
    #expect(Value.nothing.kind == .nothing)
    // `cast` is `as?`: an Int is an Int, not a Double; a list casts if every element does.
    let three = try swiit.evaluate("3")
    #expect(three.cast(to: Int.self) == 3)
    #expect(three.cast(to: Double.self) == nil)
    #expect(three.cast(to: String.self) == nil)
    #expect(try swiit.evaluate("[1, 2]").cast(to: [Int].self) == [1, 2])
    #expect(try swiit.evaluate(#"let mixed: [Any] = [1, "a"]; mixed"#).cast(to: [Int].self) == nil)
    // `try T(value)` is the throwing form, which converts as a call does.
    #expect(try Double(three) == 3)
    #expect(throws: (any Error).self) { try String(three) }
    // A script type by name, and a structured type by shape.
    let point = try swiit.evaluate("Point(x: 1, y: 2)")
    #expect(point.cast(to: .named("Point")) != nil)
    #expect(point.cast(to: .named("Level")) == nil)
    #expect(try swiit.evaluate("[1, 2]").cast(to: .list(.int)) != nil)
    #expect(try swiit.evaluate("[1, 2]").cast(to: .list(.string)) == nil)
    #expect(
        try swiit.evaluate("(a: 1, b: 2)")
            .cast(to: .tuple([.init(label: "a", type: .int), .init(label: "b", type: .int)])) != nil
    )
    // An enum's case, and the declaration kind of a type.
    let high = try #require(try swiit.evaluate("Level.high").enumCase)
    #expect(high.type == "Level" && high.name == "high")
    #expect(swiit.symbols(named: "Point").first?.kind == .structure)
    #expect(swiit.symbols(named: "Level").first?.kind == .enumeration)
    #expect(swiit.symbols(named: "twice").first?.function != nil)
    swiit["limit"] = 3
    #expect(
        swiit.symbols(named: "limit").first?.kind == .variable(Symbol.Variable(type: .int))
    )
}

@Test func aTypeIsANameWithArgumentsAFunctionOrATuple() throws {
    let swiit = interpreter()
    #expect(ScriptType.list(.int) == .named("Array", [.int]))
    #expect(ScriptType.optional(.string) == .named("Optional", [.string]))
    #expect(ScriptType.list(.optional(.int)).description == "[Int?]")
    #expect(try swiit.scriptType(ofExpression: "[1, 2]") == .list(.int))
    #expect(try swiit.scriptType(ofExpression: #"["a": 1]"#) == .dictionary(.string, .int))
    #expect(
        try swiit.scriptType(ofExpression: "(a: 1, b: \"x\")")
            == .tuple([.init(label: "a", type: .int), .init(label: "b", type: .string)])
    )
    _ = try swiit.evaluate("func twice(_ n: Int) -> Int { n * 2 }")
    #expect(
        try swiit.scriptType(ofExpression: "twice") == .function(parameters: [.int], returns: .int)
    )
}

@Test func aSwiftHostNamesTypesWithMetatypes() throws {
    #expect(ScriptType(Int.self) == .int)
    #expect(ScriptType([String].self) == .list(.string))
    #expect(ScriptType([String: Int].self) == .dictionary(.string, .int))
    let swiit = interpreter()
    swiit.register(
        HostFunction(
            name: "scale",
            summary: "Multiplies.",
            parameters: [
                .init(name: "n", type: Int.self), .init(label: "by", name: "k", type: Int.self),
            ],
            returns: Int.self
        ) { arguments in
            Value((arguments[0].cast(to: Int.self) ?? 0) * (arguments[1].cast(to: Int.self) ?? 0))
        }
    )
    #expect(try swiit.evaluate("scale(3, by: 4)") == 12)
    #expect(throws: Diagnostic.self) { try swiit.evaluate(#"scale("a", by: 4)"#) }
    let scale = try #require(swiit.symbols(named: "scale").first)
    #expect(
        scale.function?.parameters.map(\.type) == [.int, .int] && scale.function?.returns == .int
    )
    #expect(!swiit.symbols(named: "sorted", in: [Int].self).isEmpty)
    #expect(
        try swiit
            .overload(
                among: [scale],
                arguments: [.init(type: Int.self), .init(label: "by", type: Int.self)]
            )
            .name == "scale"
    )
    // A function symbol is also a function type, and a call's arguments are the elements of a tuple
    // type.
    #expect(scale.scriptType == .function(parameters: [.int, .int], returns: .int))
}

@Test func aRunCancelledBeforeItStartsDoesNotRun() async throws {
    let swiit = interpreter()
    // Cancelled at once, whichever of the request and the start of the run comes first.
    for _ in 0..<20 {
        let running = Task { try await swiit.evaluate("var n = 0; while true { n += 1 }") }
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
    static func bytesType() -> HostType {
        @Sendable func box(_ b: Bytes) -> Value { Value(boxing: b, as: "Bytes") }
        return HostType(
            name: "Bytes",
            members: [
                .init(
                    "init",
                    .initializer(
                        Symbol.Function(
                            parameters: [.init(label: "count", name: "count", type: Int.self)],
                            returns: .named("Bytes")
                        )
                    ) { box(Bytes(count: try Int($0[0]))) }
                ),
                .init(
                    "count",
                    .property(
                        .int,
                        .readOnly { try $0.unboxed(Bytes.self).count.value }
                    )
                ),
                .init(
                    "<",
                    .staticMethod(
                        Symbol.Function(
                            parameters: [
                                .init(name: "lhs", type: .named("Bytes")),
                                .init(name: "rhs", type: .named("Bytes")),
                            ],
                            returns: .bool
                        )
                    ) { (try $0[0].unboxed(Bytes.self) < $0[1].unboxed(Bytes.self)).value }
                ),
            ]
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

extension URL: ScriptConvertible {}

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
        try swiit.call("scaled", on: point, arguments: [("by", Value(2))]).entries?[Value("x")] == 6
    )
    #expect(try swiit.call("origin", on: swiit["Point"]!).entries?[Value("x")] == 0)
    #expect(try swiit.call("uppercased", on: Value("ab")) == "AB")
    #expect(try swiit.call("sorted", on: [3, 1, 2]) == [1, 2, 3])
    #expect(throws: Diagnostic.self) { try swiit.call("f", arguments: [(nil, Value(true))]) }
    #expect(throws: Diagnostic.self) { try swiit.call("nosuch") }
}

@Test func aCheckFindsMistakesAndRunsNothing() throws {
    let log = Log()
    let swiit = interpreter(log: log)
    let declared = try swiit.check(
        """
        print("ran")
        /// Says f.
        func f(a: Int, b: Bool = false) -> String { "x" }
        enum Kind { case a, b }
        """
    )
    #expect(log.text == "")
    #expect(declared.symbols.map(\.name) == ["Kind", "f"])
    // An enum it declares has its cases to ask for, before it exists to run.
    let cases = declared.members["Kind"]?
        .filter {
            if case .enumCase = $0.kind { true } else { false }
        }
    #expect(cases?.map(\.name) == ["a", "b"])
    #expect(declared.symbols.first { $0.name == "f" }?.summary == "Says f.")
    let f = declared.symbols.first { $0.name == "f" }?.function
    #expect(f?.parameters.map(\.label) == ["a", "b"])
    #expect(f?.parameters[1].arity == .defaulted(.value(false)))
    #expect(throws: Diagnostic.self) { try swiit.check(#"print("ran"); let x: Int = "s""#) }
    #expect(log.text == "")
    // Nothing was declared by checking.
    #expect(swiit.symbols(named: "f").isEmpty)
}

@Test func wordsAndValuesConvertToTheTypeAParameterNames() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum Kind { case file, directory }")
    #expect(swiit.parse(word: "5", as: .int) == 5)
    #expect(swiit.parse(word: "x", as: .int) == nil)
    #expect(swiit.parse(word: "x", as: .string) == "x")
    #expect(swiit.parse(word: ".directory", as: .named("Kind"))?.enumCase?.name == "directory")
    #expect(swiit.parse(word: "nope", as: .named("Kind")) == nil)
    #expect(swiit.parse(word: "x", as: .optional(.string)) == "x")
    #expect(swiit.parse(word: "x", as: .named("Element")) == "x")
    #expect(swiit.value(forCase: "file", in: "Kind")?.enumCase?.name == "file")
    #expect(swiit.value(forCase: "nope", in: "Kind") == nil)
    #expect(swiit.converted(Value(3), to: .int) == 3)
    #expect(swiit.converted(Value("3"), to: .int) == nil)
    #expect(swiit.scriptType(of: Value(3)) == .int)
    #expect(swiit.scriptType(of: [1, 2]) == .list(.int))
}

private struct Stop: Error {}
private struct Status: Error { var code: Int32 }

@Test func aHostFunctionFailsWithADiagnosticOrEndsTheRun() throws {
    let log = Log()
    let swiit = interpreter(log: log)
    swiit.register(
        HostFunction(name: "fail", returns: .int, isThrowing: true) { _ in
            throw Diagnostic.runtime(
                "nope",
                thrown: Value(struct: "Failure", fields: ["code": Value(7)]),
                cause: Status(code: 3)
            )
        }
    )
    swiit.register(
        HostFunction(name: "elsewhere", isThrowing: true) { _ in
            try swiit.withErrorOutput(OutputSink { _ in true }) {
                try swiit.evaluate("1 / 0")
            }
        }
    )
    swiit.register(
        HostFunction(name: "stop", isThrowing: true) { _ in
            throw Diagnostic.fatal("stopped", cause: Stop())
        }
    )
    // A script can catch a script error, and what it carries.
    _ = try swiit.evaluate("struct Failure: Error { let code: Int }")
    #expect(
        try swiit.evaluate(
            "var r = -1; do { _ = try fail() } catch let f as Failure { r = f.code } catch { r = -2 }; r"
        ) == 7
    )
    #expect(try swiit.evaluate("(try? fail()) == nil") == true)
    let failure = #expect(throws: Diagnostic.self) { try swiit.evaluate("try fail()") }
    #expect(failure?.message == "nope")
    guard case .runtime(let ran)? = failure?.kind, case .hostError(let own) = ran.origin else {
        Issue.record("expected a run-time failure with an error of the host's own")
        return
    }
    #expect((own as? Status)?.code == 3)
    // What is raised inside `withErrorOutput` says where it goes; a script's `catch` still sees it.
    let sent = #expect(throws: Diagnostic.self) { try swiit.evaluate("try elsewhere()") }
    guard case .sink? = sent?.failure?.destination else {
        Issue.record("expected the error to go to the scope's output")
        return
    }
    guard case .standard? = failure?.failure?.destination else {
        Issue.record("expected an error raised outside the scope to go to the host's own")
        return
    }
    #expect(try swiit.evaluate("var r = 0; do { try elsewhere() } catch { r = 1 }; r") == 1)
    // A fatal failure is not caught, runs the defers, and reaches the host.
    let stopped = #expect(throws: Diagnostic.self) {
        try swiit.evaluate(
            #"func f() throws { defer { print("deferred") }; try stop() }; do { try f() } catch { print("caught") }"#
        )
    }
    guard case .fatal(let ended)? = stopped?.kind, case .hostError(let cause) = ended.origin else {
        Issue.record("expected a fatal failure with an error of the host's own")
        return
    }
    #expect(cause is Stop)
    #expect(log.text == "deferred\n")
}

private final class Mark: @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
}

@Test func theHostKeepsStateForEachTask() throws {
    let swiit = interpreter()
    swiit.host.makeTaskState = { Mark("task") }
    swiit.taskState = Mark("main")
    nonisolated(unsafe) let running = swiit
    swiit.register("who") { () -> String in (running.taskState as? Mark)?.label ?? "none" }
    #expect(try swiit.evaluate("who()") == "main")
    #expect(try swiit.evaluate("await Task { who() }.value") == "task")
    #expect((swiit.taskState as? Mark)?.label == "main")
}

@Test func aHostDeclaresWhatItAddsToTheLanguage() throws {
    let swiit = interpreter()
    try swiit.declare(
        prelude:
            """
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
            """,
        bodies: [
            "Counter.next": { arguments in
                Value(
                    (arguments["self"]?.entries?[Value("start")].flatMap { $0.cast(to: Int.self) }
                        ?? 0) + 1
                )
            },
            "Sequence.firsts": { arguments in
                Value(
                    Array(
                        (arguments["self"]?.items.map(Array.init) ?? [])
                            .prefix(arguments["count"]?.cast(to: Int.self) ?? 0)
                    )
                )
            },
            "hello": { arguments in Value("hello, " + (arguments["name"]?.description ?? "")) },
        ]
    )
    #expect(try swiit.evaluate("Counter(start: 4).next()") == 5)
    #expect(try swiit.evaluate("[7, 8, 9].firsts(2)") == [7, 8])
    #expect(try swiit.evaluate("3.doubled") == 6)
    #expect(try swiit.evaluate(#"hello("you")"#) == "hello, you")
    // What the host declared is the host's.
    #expect(swiit.symbols(named: "hello").first?.isBuiltin == true)
    #expect(!swiit.symbols(named: "firsts", in: .list(.int)).isEmpty)
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

@Test func theHostIsToldAsStatementsFinish() throws {
    let swiit = interpreter()
    nonisolated(unsafe) var told: [String] = []
    swiit.host.didFinishStatement = { value, caught in
        told.append(caught ? "caught" : value.map { $0.description } ?? "-")
    }
    _ = try swiit.evaluate(
        """
        let x = 1
        x + 1
        func f() -> Int { 7 }
        f()
        try? Int("z")
        if x == 1 { x + 10 }
        """
    )
    // Values of the expression statements, in order; `if` is told as it starts, and what is in it
    // as it runs.
    #expect(told.filter { $0 != "-" } == ["2", "7", "caught", "11"])
}

private final class Handle: HostObject, @unchecked Sendable {
    let task: ScriptTask
    init(_ task: ScriptTask) { self.task = task }
    var typeName: String { "Handle" }
    var description: String { "Handle" }
}

@Test func aHostStartsAndJoinsTasksAndLetsScriptsAwaitThem() throws {
    let swiit = interpreter()
    nonisolated(unsafe) let running = swiit
    swiit.register(
        HostFunction(name: "spawn", returns: .named("Handle")) { _ in
            Value(Handle(try running.startTask(state: nil) { Value(42) }))
        }
    )
    swiit.register(computed: "clock", type: .int) { Value(7) }
    // A handle is awaited by its `async` member, as Swift says it.
    swiit.register(
        HostType(
            name: "Handle",
            members: [
                .init(
                    "wait",
                    .method(Symbol.Function(returns: .int, isAsync: true)) { receiver, _ in
                        guard let handle = receiver.cast(to: Handle.self) else {
                            throw Diagnostic.runtime("nothing to await")
                        }
                        return try running.join(handle.task)
                    }
                )
            ]
        )
    )
    #expect(try swiit.evaluate("clock + clock") == 14)
    #expect(try swiit.evaluate("await spawn().wait()") == 42)
    swiit.cancelAndJoinTasks()
}

@Test func aReplHostIsToldTheValueOfEachExpressionStatement() throws {
    let swiit = interpreter()
    nonisolated(unsafe) var seen: [String] = []
    try swiit.evaluate(
        """
        let x = 2
        x * 3
        true
        [1, 2].map { $0 + x }
        await Task { 5 }.value
        for i in 1...2 { i }
        """,
        onValue: { value, _ in seen.append(value.description) }
    )
    #expect(seen == ["6", "[3, 4]", "5"])
    // A failure stops the run, unless the host says to go on.
    seen = []
    #expect(throws: Diagnostic.self) {
        try swiit.evaluate("1\n2 / 0\n3", onValue: { value, _ in seen.append(value.description) })
    }
    #expect(seen == ["1"])
    seen = []
    nonisolated(unsafe) var errors: [String] = []
    // A `try!` that fails is fatal: the host is told, and the run ends.
    #expect(throws: Diagnostic.self) {
        try swiit.evaluate(
            "struct E: Error {}\nfunc boom() throws { throw E() }\n1\n2 / 0\n3\ntry! boom()\n4",
            onValue: { value, _ in seen.append(value.description) },
            onError: {
                errors.append($0.message + ($0.isFatal ? " (fatal)" : "")); return !$0.isFatal
            }
        )
    }
    #expect(seen == ["1", "3"])
    #expect(errors.count == 2 && errors[1].hasSuffix("(fatal)"))
}

@Test func aHostAsksTheFunctionAStatementCalledForItsAttributes() throws {
    let swiit = interpreter()
    swiit.register(
        HostFunction(
            name: "quiet",
            returns: Int.self,
            attributes: [Symbol.Attribute(name: "discardableResult")],
            body: { _ in Value(10) }
        )
    )
    swiit.register("loud") { () -> Int in 20 }
    nonisolated(unsafe) var told: [String: [String]] = [:]
    try swiit.evaluate(
        """
        @discardableResult func bump() -> Int { 30 }
        @available(*, deprecated) func old() -> Int { 40 }
        var xs = [7, 8, 9]
        bump()
        old()
        quiet()
        loud()
        xs.removeLast()
        xs.count
        """,
        onValue: { value, callee in
            told[value.description, default: []] = (callee?.attributes ?? [])
                .map {
                    $0.name
                        + ($0.arguments.isEmpty
                            ? "" : "(" + $0.arguments.joined(separator: ",") + ")")
                }
        }
    )
    // A script's own attributes, with their arguments as written; a host function's; a bridged
    // Swift member's; and none for a call without any, or a statement that is no call.
    #expect(told["30"] == ["discardableResult"])
    #expect(told["40"] == ["available(*, deprecated)"])
    #expect(told["10"] == ["discardableResult"])
    #expect(told["20"] == [])
    #expect(told["9"] == ["discardableResult"])
    #expect(told["2"] == [])
    // And a symbol lookup says the same of what is declared.
    let bump = swiit.symbols(named: "bump").first
    #expect(bump?.attributes.contains(named: "discardableResult") == true)
}

@Test func typeParametersCarryTheirConstraintsAsTypes() throws {
    let swiit = interpreter()
    // A host function's own type parameters, with and without constraints.
    swiit.register(
        HostFunction(
            name: "pick",
            parameters: [
                Symbol.Parameter(name: "a", type: "T"), Symbol.Parameter(name: "b", type: "U"),
            ],
            returns: "T",
            generics: [
                Symbol.GenericParameter(
                    name: "T",
                    constraints: [.conforms(to: "Comparable"), .conforms(to: "Hashable")]
                ),
                "U",
            ],
            body: { $0[0] }
        )
    )
    let pick = swiit.symbols(named: "pick").first?.function
    #expect(
        pick?.generics == [
            Symbol.GenericParameter(
                name: "T",
                constraints: [.conforms(to: "Comparable"), .conforms(to: "Hashable")]
            ),
            "U",
        ]
    )
    // A Swift member's, with what it asks of its type: `sorted()` needs a Comparable element.
    let sorted = swiit.symbols(named: "sorted", in: .list(.int)).compactMap(\.function)
    #expect(
        sorted.contains {
            $0.generics.contains {
                $0.name == "Element" && $0.constraints.contains(.conforms(to: "Comparable"))
            }
        }
    )
}

@Test func evaluateGivesBackTheLastValueWhateverIsWatching() throws {
    let swiit = interpreter()
    nonisolated(unsafe) var seen: [String] = []
    // The last expression is told to `onValue` and given back too.
    let value = try swiit.evaluate(
        "1\n2 + 3",
        onValue: { value, _ in seen.append(value.description) }
    )
    #expect(value == 5)
    #expect(seen == ["1", "5"])
    // Nothing is given back when the last statement is not an expression, or failed and was let go.
    #expect(try swiit.evaluate("1\nlet y = 2", onValue: { _, _ in }) == .nothing)
    #expect(try swiit.evaluate("1\n2 / 0", onError: { _ in true }) == .nothing)
    // `completion` runs after the last statement.
    nonisolated(unsafe) var finished = false
    try swiit.evaluate("1", completion: { finished = true })
    #expect(finished)
}

@Test func theAsyncEvaluateTakesTheSameClosures() async throws {
    let swiit = interpreter()
    nonisolated(unsafe) var told = 0
    let value = try await swiit.evaluate("40 + 2", onValue: { _, _ in told += 1 })
    #expect(value == 42 && told == 1)
}

@Test func removingAGlobalRemovesIt() throws {
    let swiit = interpreter()
    swiit["answer"] = Value(42)
    #expect(try swiit.evaluate("answer") == 42)
    swiit["answer"] = nil
    #expect(throws: Diagnostic.self) { try swiit.evaluate("answer") }
}

@Test func aCallByNameFindsTheBridgedOverloadByItsArguments() throws {
    let swiit = interpreter()
    #expect(try swiit.call("contains", on: [1, 2], arguments: [(nil, Value(2))]) == true)
    #expect(
        try swiit.call("joined", on: ["a", "b"], arguments: [("separator", Value("-"))]) == "a-b"
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
    let reduce = swiit.symbols(named: "reduce", in: .list(.int))
    #expect(
        try swiit
            .overload(among: reduce, arguments: [.init(type: .int), .init(type: .callable)])
            .name
            == "reduce"
    )
}
