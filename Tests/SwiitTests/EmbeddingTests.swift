import Foundation
import Swiit
import Testing

// The embedding API: what a host does with an `Interpreter` and nothing else.

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
    #expect(diagnostic("let a = 1\nlet b: Int = \"x\"")?.range?.start.line == 2)
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

private final class Node: ScriptConvertible, CustomStringConvertible, @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
    var description: String { "Node(\(label))" }
    func shout() -> String { label.uppercased() }

    static let scriptTypeID = Symbol.ID(hostType: "Node")
    static let type = HostTypeBuilder<Node>("Node")
        .property("label", \.label)
        .method("shout", Node.shout)
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
    let names = Set(swiit.globals().map(\.name))
    #expect(names.isSuperset(of: ["area", "check", "greet"]))
    #expect(names.contains("print"))
    let area = try #require(swiit.globals(named: "area").first)
    let function = try #require(area.function)
    #expect(function.parameters.map(\.label) == ["width", "height"])
    #expect(function.parameters.map(\.arity) == [.required, .defaulted(.value(1))])
    #expect(function.returns == .int)
    #expect(try #require(swiit.globals(named: "check").first?.function).isThrowing)
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
        swiit.globals(named: "f").allSatisfy { if case .function = $0.kind { true } else { false } }
    )
    // And what belongs to the type: its memberwise initializer.
    let initializers = members.filter {
        if case .initializer = $0.kind { true } else { false }
    }
    #expect(initializers.count == 1)
    #expect(try swiit.scriptType(ofExpression: "Point(x: 1)") == swiit.type("Point"))
    #expect(try swiit.scriptType(ofExpression: "[1, 2].map { $0 + 1 }") == .list(.int))
    let overloads = swiit.globals(named: "f")
    #expect(
        try overloads.overload(arguments: [.init(type: .string)], in: swiit).function?
            .returns == .string
    )
    #expect(
        try overloads.overload(arguments: [.init(type: .int)], in: swiit).function?
            .parameters.first?
            .type
            == .int
    )
    #expect(throws: Diagnostic.self) {
        try overloads.overload(arguments: [.init(type: .bool)], in: swiit)
    }
    let sorted = ScriptType.list(.int).members(named: "sorted", in: swiit)
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
    // From a thread of its own: a busy runner can hold the global queue's block up for seconds,
    // and the test is of the cancel, not of the queue.
    let canceller = Thread {
        Thread.sleep(forTimeInterval: 0.2)
        swiit.cancel()
    }
    canceller.start()
    let start = Date()
    _ = try? swiit.evaluate("block()")
    #expect(Date().timeIntervalSince(start) < 5)
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

extension Value {
    /// The entry named `name` of a structured value.
    fileprivate func entry(_ name: String) -> Value? {
        Mirror(reflecting: self).children.first { $0.label == name }?.value as? Value
    }

    /// What a host reads of a value's shape and children, as it would of any Swift value.
    fileprivate var mirror: Mirror { Mirror(reflecting: self) }
}

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

@Test func aTypeIsANameWithArgumentsAFunctionOrATuple() throws {
    let swiit = interpreter()
    #expect(ScriptType.list(.int) == .named(.array, [.int]))
    #expect(ScriptType.optional(.string) == .named(.optional, [.string]))
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
        HostSymbol.function(
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
    #expect(
        scale.function?.parameters.map(\.type) == [.int, .int] && scale.function?.returns == .int
    )
    #expect(!ScriptType([Int].self).members(named: "sorted", in: swiit).isEmpty)
    #expect(
        try [scale]
            .overload(
                arguments: [.init(type: Int.self), .init(label: "by", type: Int.self)],
                in: swiit
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

struct Bytes: Comparable, Hashable, Sendable, ScriptConvertible {
    var count: Int
    static func < (a: Bytes, b: Bytes) -> Bool { a.count < b.count }
}

@Suite struct NativeTypeTests {
    static func bytesType() -> HostTypeBuilder<Bytes> {
        let bytes = Symbol.ID(hostType: "Bytes")
        @Sendable func box(_ b: Bytes) -> Value { Value(b) }
        return HostTypeBuilder<Bytes>("Bytes")
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

extension URL: ScriptConvertible {}

enum Shade: String, CaseIterable, Comparable, Hashable, Sendable, ScriptConvertible {
    case light, dark

    static func < (a: Shade, b: Shade) -> Bool { a == .light && b == .dark }
}

struct Swatch: Hashable, Sendable, ScriptConvertible {
    var shade: Shade
    func flipped() -> Shade { shade == .light ? .dark : .light }
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
        HostTypeBuilder<Swatch>()
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
        HostTypeBuilder<URL>()
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
        try swiit.call("scaled", on: point, arguments: [("by", Value(2))]).entry("x") == 6
    )
    #expect(try swiit.call("origin", on: swiit["Point"]!).entry("x") == 0)
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
    #expect(swiit.globals(named: "f").isEmpty)
}

@Test func wordsAndValuesConvertToTheTypeAParameterNames() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum Kind { case file, directory }")
    #expect(
        Symbol.ID(named: "Kind", in: swiit)!.enumCase(named: "file", in: swiit)?.description
            == "file"
    )
    #expect(Symbol.ID(named: "Kind", in: swiit)!.enumCase(named: "nope", in: swiit) == nil)
    #expect(swiit.converted(Value(3), to: .int) == 3)
    #expect(swiit.converted(Value("3"), to: .int) == nil)
    // A Character is held as a one-letter String. Any other Swift type text is not, as in Swift,
    // where only a literal is one.
    #expect(swiit.converted(Value("a"), to: swiit.type("Character")) == "a")
    #expect(swiit.converted(Value("ab"), to: swiit.type("Character")) == nil)
    #expect(swiit.converted(Value("x"), to: swiit.type("Substring")) == nil)
    #expect(swiit.scriptType(of: Value(3)) == .int)
    #expect(swiit.scriptType(of: [1, 2]) == .list(.int))
}

private struct Stop: Error {}
private struct Status: Error { var code: Int32 }

@Test func aHostFunctionFailsWithADiagnosticOrEndsTheRun() throws {
    let log = Log()
    let swiit = interpreter(log: log)
    swiit.register(
        HostSymbol.function(name: "fail", returns: .int, isThrowing: true) { _ in
            throw Diagnostic.runtime(
                "nope",
                thrown: try Value(encoding: Failure(code: 7)),
                cause: Status(code: 3)
            )
        }
    )
    swiit.register(
        HostSymbol.function(name: "stop", isThrowing: true) { _ in
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
                    (arguments["self"]?.entry("start").flatMap { $0.casting(to: Int.self) }
                        ?? 0) + 1
                )
            },
            "Sequence.firsts": { arguments in
                // A sequence's items, one at a time, as far as are wanted.
                let wanted = arguments["count"]?.casting(to: Int.self) ?? 0
                guard let value = arguments["self"], let items = try? AnySequence<Value>(value)
                else {
                    return Value([] as [Value])
                }
                return Value(Array(items.prefix(wanted)))
            },
            "hello": { arguments in Value("hello, " + (arguments["name"]?.description ?? "")) },
        ]
    )
    #expect(try swiit.evaluate("Counter(start: 4).next()") == 5)
    #expect(try swiit.evaluate("[7, 8, 9].firsts(2)") == [7, 8])
    #expect(try swiit.evaluate("3.doubled") == 6)
    #expect(try swiit.evaluate(#"hello("you")"#) == "hello, you")
    // What the host declared is the host's.
    #expect(swiit.globals(named: "hello").first?.isBuiltin == true)
    #expect(!ScriptType.list(.int).members(named: "firsts", in: swiit).isEmpty)
}

@Test func aComparableNativeTypeNeedsNoOperatorsOfItsOwn() throws {
    let swiit = interpreter()
    swiit.register(
        HostTypeBuilder<Bytes>("Bytes")
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

private final class Handle: ScriptConvertible, CustomStringConvertible, @unchecked Sendable {
    let task: ScriptTask
    init(_ task: ScriptTask) { self.task = task }
    var description: String { "Handle" }
}

@Test func aHostStartsAndJoinsTasksAndLetsScriptsAwaitThem() throws {
    let swiit = interpreter()
    nonisolated(unsafe) let running = swiit
    let handle = Symbol.ID(hostType: "Handle")
    swiit.register(
        HostSymbol.function(name: "spawn", returns: .named(handle)) { _ in
            Value(Handle(try running.startTask(state: nil) { Value(42) }))
        }
    )
    swiit.register(computed: "clock", type: .int) { Value(7) }
    // A handle is awaited by its `async` member, as Swift says it.
    swiit.register(
        HostTypeBuilder<Handle>("Handle")
            .member(
                .method("wait", returns: .int, isAsync: true) { receiver, _ in
                    guard let handle = try? Handle(receiver) else {
                        throw Diagnostic.runtime("nothing to await")
                    }
                    return try running.join(handle.task)
                }
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
        HostSymbol.function(
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
    let bump = swiit.globals(named: "bump").first
    #expect(bump?.attributes.contains(named: "discardableResult") == true)
}

@Test func typeParametersCarryTheirConstraintsAsTypes() throws {
    let swiit = interpreter()
    // A host function's own type parameters, with and without constraints.
    let t = Symbol.GenericParameter(name: "T", constraints: [.comparable, .hashable])
    let u: Symbol.GenericParameter = "U"
    swiit.register(
        HostSymbol.function(
            name: "pick",
            parameters: [
                Symbol.Parameter(name: "a", type: t.type),
                Symbol.Parameter(name: "b", type: u.type),
            ],
            returns: t.type,
            generics: [t, u],
            body: { $0[0] }
        )
    )
    let pick = swiit.globals(named: "pick").first?.function
    #expect(
        pick?.generics == [t, u]
    )
    // A Swift member's, with what it asks of its type: `sorted()` needs a Comparable element.
    let sorted = ScriptType.list(.int).members(named: "sorted", in: swiit).compactMap(\.function)
    #expect(
        sorted.contains {
            $0.generics.contains {
                $0.name == "Element" && $0.constraints.contains(.comparable)
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
        HostTypeBuilder<Lines>("Lines")
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
    let reduce = ScriptType.list(.int).members(named: "reduce", in: swiit)
    #expect(
        try reduce
            .overload(arguments: [.init(type: .int), .init(type: .callable)], in: swiit)
            .name
            == "reduce"
    )
}

// MARK: Type identity

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

/// Swift types a host encodes into struct values, by their own names.
private struct Failure: Encodable { var code: Int }
private struct Point: Encodable { var x: Int }

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

// MARK: What a declared function sees

@Test func aDeclaredFunctionCallsWhatTheProgramDefined() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("func helper() -> Int { 41 }")
    try swiit.declare("func caller() -> Int { helper() + 1 }")
    #expect(try swiit.evaluate("caller()") == Value(42))
}

@Test func aDeclaredFunctionCallsAHostFunction() throws {
    let swiit = interpreter()
    swiit.register("hostAnswer") { () -> Int in 42 }
    try swiit.declare("func answer() -> Int { hostAnswer() }")
    #expect(try swiit.evaluate("answer()") == Value(42))
}

@Test func aDeclaredFunctionsDefaultNamesACaseOfTheProgramsEnum() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum Where { case here, there }")
    try swiit.declare(#"func place(_ w: Where = .here) -> String { "\(w)" }"#)
    #expect(try swiit.evaluate("place()") == Value("here"))
    #expect(try swiit.evaluate("place(.there)") == Value("there"))
}

@Test func aDeclaredFunctionNamesWhatItCallsWhenItIsDeclared() throws {
    let swiit = interpreter()
    #expect(throws: Diagnostic.self) {
        try swiit.declare("func caller() -> Int { missing() }")
    }
}

@Test func aHostFunctionCanSayItGivesAScriptsStruct() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("struct P { var x: Int }")
    let id = try #require(Symbol.ID(named: "P", in: swiit))
    swiit.register(
        HostSymbol.function(name: "hostP", returns: .named(id)) { _ in
            try swiit.make(id, arguments: [("x", Value(5))])
        }
    )
    #expect(try swiit.evaluate("hostP().x + 1") == Value(6))
}

// MARK: Function values and errors

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

@Test func aCaseNamedLikeAKeywordNeedsNoBackticks() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum E { case `default`, other }")
    #expect(try swiit.evaluate("E.default == E.`default`") == Value(true))
    #expect(try swiit.evaluate("let e: E = .default\ne == .default") == Value(true))
}

@Test func aDoubleIsMadeFromAString() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate(#"let s = "1.5""#)
    #expect(try swiit.evaluate("Double(s)") == Value(1.5))
    #expect(try swiit.evaluate(#"Double("x")"#) == .nothing)
    #expect(try swiit.evaluate("Double(Substring(s))") == Value(1.5))
}

// MARK: Types as values, and runs

@Test func aTypeNameHasTheTypeOfTheType() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum Tools { static func go() {}; func other() {} }")
    let type = try swiit.scriptType(ofExpression: "Tools")
    #expect(type == .metatype(swiit.type("Tools")))
    #expect(type.members(in: swiit).map(\.name).contains("go"))
    #expect(!type.members(in: swiit).map(\.name).contains("other"))
}

@Test func aRunTakesTheLimitsItIsGiven() throws {
    let swiit = interpreter()
    let loop = "var n = 0; while true { n += 1 }"
    #expect(throws: Diagnostic.self) {
        try swiit.evaluate(loop, limits: Interpreter.Limits(maxSteps: 1_000))
    }
    // The next run has the interpreter's own.
    #expect(try swiit.evaluate("1 + 1") == Value(2))
}

@Test func aCallOutsideARunStartsWithTheLimitsOfOne() throws {
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 2_000))
    _ = try swiit.evaluate("func f() -> Int { var n = 0; for i in 0..<300 { n += i }; return n }")
    for _ in 0..<20 { _ = try swiit.call("f") }
}

// MARK: Declared types, keyword names, function values outside a run

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

@Test func callingAFunctionValueOutsideARunStartsARun() throws {
    let swiit = interpreter(limits: Interpreter.Limits(maxSteps: 2_000))
    _ = try swiit.evaluate("let f = { var n = 0; for i in 0..<300 { n += i }; return n }")
    let f = try swiit.evaluate("f")
    for _ in 0..<20 { _ = try swiit.call(f, with: []) }
}
