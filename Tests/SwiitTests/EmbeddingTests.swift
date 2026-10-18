import Foundation
import Swiit
import Testing

// The embedding API: what a host does with an `Interpreter` and nothing else.

private final class Log: @unchecked Sendable {
    var text = ""
}

private func interpreter(limits: Limits = Limits(), log: Log = Log()) -> Interpreter {
    Interpreter(
        host: SwiitHost(output: OutputSink(write: { log.text += $0; return true }),
                        error: OutputSink(write: { log.text += "err: " + $0; return true })),
        limits: limits)
}

@Test func printWritesToTheHostsOutput() throws {
    let log = Log()
    let swish = interpreter(log: log)
    _ = try swish.eval(#"print("hello", 1 + 1); print([1, 2])"#)
    #expect(log.text == "hello 2\n[1, 2]\n")
}

@Test func evalGivesTheValueOfTheLastExpression() throws {
    let swish = interpreter()
    #expect(try swish.eval("1 + 2") == .int(3))
    #expect(try swish.eval("let xs = [3, 1, 2]; xs.sorted()") == .list([.int(1), .int(2), .int(3)]))
    // A declaration gives nothing, and stays for the next call.
    #expect(try swish.eval("let answer = 42") == .nothing)
    #expect(try swish.eval("answer * 2") == .int(84))
    // A value statement shows nothing: values come back from eval.
    let log = Log()
    _ = try interpreter(log: log).eval("1; 2; 3")
    #expect(log.text == "")
}

@Test func errorsAreDiagnosticsWithAKind() {
    let swish = interpreter()
    func diagnostic(_ source: String) -> Diagnostic? {
        do { _ = try swish.eval(source); return nil } catch { return error as? Diagnostic }
    }
    #expect(diagnostic("let = 1")?.kind == .syntax)
    #expect(diagnostic("let x: Int = \"a\"")?.kind == .type)
    #expect(diagnostic("1 / 0")?.kind == .runtime)
    #expect(diagnostic("1 / 0")?.message == "division by zero")
    // A multi-line program says which line.
    #expect(diagnostic("let a = 1\nlet b: Int = \"x\"")?.line == 2)
}

@Test func aRegisteredClosureIsAnOrdinaryFunction() throws {
    let swish = interpreter()
    swish.register("clamp") { (x: Int, lo: Int, hi: Int) in min(max(x, lo), hi) }
    swish.register("greet", labels: ["name"]) { (name: String) in "hello, \(name)" }
    swish.register("twice") { (xs: [Int]) in xs + xs }
    #expect(try swish.eval("clamp(15, 0, 10)") == .int(10))
    #expect(try swish.eval(#"greet(name: "Rak")"#) == .string("hello, Rak"))
    #expect(try swish.eval("twice([1, 2]).count") == .int(4))
    // A wrong argument is the usual type error.
    do {
        _ = try swish.eval(#"clamp("a", 0, 10)"#)
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
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
    #expect(try swish.eval("try check(1)") == .int(1))
    do {
        _ = try swish.eval("try check(-1)")
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
        #expect(error.kind == .runtime)
        #expect(error.message.contains("refused"))
    }
}

@Test func valuesSetByTheHostAreReadByTheScript() throws {
    struct Config: Encodable { var volume = 7; var name = "main" }
    let swish = interpreter()
    try swish.set("config", Config())
    swish.set("limit", .int(10))
    #expect(try swish.eval("config.volume * 2") == .int(14))
    #expect(try swish.eval("limit + 1") == .int(11))
    #expect(swish.get("limit") == .int(10))
}

@Test func theSandboxRefusesWhatItWasNotGiven() {
    let swish = interpreter()
    func message(_ source: String) -> String? {
        do { _ = try swish.eval(source); return nil } catch { return (error as? Diagnostic)?.message }
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
    let swish = interpreter(limits: Limits(steps: 10_000))
    do {
        _ = try swish.eval("var n = 0; while true { n += 1 }")
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
        #expect(error.kind == .limit)
        #expect(error.message.contains("step limit"))
    } catch {
        Issue.record("\(error)")
    }
    // The interpreter is still usable afterward.
    #expect((try? swish.eval("1 + 1")) == .int(2))
}

@Test func aScriptCannotCatchALimit() {
    let swish = interpreter(limits: Limits(steps: 1_000))
    do {
        _ = try swish.eval("do { while true {} } catch { 0 }")
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
        #expect(error.kind == .limit)
    } catch {
        Issue.record("\(error)")
    }
}

@Test func deepRecursionStopsAtTheDepthLimit() {
    let swish = interpreter(limits: Limits(depth: 200))
    do {
        _ = try swish.eval("func down(_ n: Int) -> Int { down(n + 1) }; down(0)")
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
        #expect(error.message.contains("maximum call depth (200)"))
    } catch {
        Issue.record("\(error)")
    }
    // The default depth fits the stack eval runs on.
    let deep = interpreter()
    #expect((try? deep.eval("func sum(_ n: Int) -> Int { n == 0 ? 0 : n + sum(n - 1) }; sum(5000)")) == .int(12_502_500))
}

@Test func timeAndOutputAreLimitedToo() {
    let slow = interpreter(limits: Limits(time: .milliseconds(50)))
    do {
        _ = try slow.eval("while true {}")
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
        #expect(error.message == "time limit exceeded")
    } catch {
        Issue.record("\(error)")
    }
    let chatty = interpreter(limits: Limits(output: 100))
    do {
        _ = try chatty.eval(#"for i in 1...100000 { print("xxxxxxxxxx") }"#)
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
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
        do { _ = try running.eval("while true {}") } catch { result = error as? Diagnostic }
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
    _ = try a.eval("let shared = 1")
    #expect((try? b.eval("shared")) == nil)
    #expect((try? b.eval("only(1)")) == nil)
    #expect(try a.eval("only(shared)") == .int(1))
}

/// A bag of settings: every member is an Int, assigned through a `let`.
private final class Settings: DynamicObject, @unchecked Sendable {
    var values: [String: Int] = ["volume": 7]

    var typeName: String { "Settings" }
    var readType: TypeAnnotation { .optional(.int) }
    var writeType: TypeAnnotation { .optional(.int) }
    var memberNames: [String] { values.keys.sorted() }
    var description: String { "Settings" }
    func member(_ name: String) -> Value? { values[name].map(Value.int) }
    func read(_ name: String) throws -> Value { values[name].map(Value.int) ?? .nothing }
    func write(_ name: String, _ value: Value) throws {
        guard case .int(let number) = value else { values[name] = nil; return }
        values[name] = number
    }
}

@Test func aDynamicObjectAnswersForItsOwnMembers() throws {
    let swish = interpreter()
    let settings = Settings()
    swish.bind("settings", to: settings)
    #expect(try swish.eval("settings.volume") == .int(7))
    #expect(try swish.eval(#"settings["volume"]"#) == .int(7))
    #expect(try swish.eval("settings.missing") == .nothing)
    // Assigned through a `let`, as a class would be; nil removes.
    _ = try swish.eval("settings.brightness = 3; settings.volume = settings.volume! + 1")
    #expect(settings.values == ["volume": 8, "brightness": 3])
    _ = try swish.eval(#"settings["volume"] = nil"#)
    #expect(settings.values == ["brightness": 3])
    // The checker knows the members' type.
    do {
        _ = try swish.eval(#"settings.volume = "loud""#)
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
        #expect(error.kind == .type)
    }
    #expect((try? swish.eval("let v: String = settings.volume")) == nil)
}

@Test func interpretersOnDifferentThreadsDontShareKeyPathReads() {
    // `sorted(by: \.n)` reads fields through a reader set for the length of
    // the call; two runs at once must each have their own.
    let program = #"[(n: 3, s: "c"), (n: 1, s: "a"), (n: 2, s: "b")].sorted(by: \.n).map { $0.s }"#
    let expected = Value.list([.string("a"), .string("b"), .string("c")])
    nonisolated(unsafe) var wrong = 0
    let lock = NSLock()
    let group = DispatchGroup()
    for _ in 0..<4 {
        group.enter()
        Thread {
            let swish = interpreter()
            for _ in 0..<150 where (try? swish.eval(program)) != expected {
                lock.withLock { wrong += 1 }
            }
            group.leave()
        }.start()
    }
    group.wait()
    #expect(wrong == 0)
}

@Test func aComputedGlobalIsReadFreshAndCannotBeAssigned() throws {
    let swish = interpreter()
    nonisolated(unsafe) var reads = 0
    swish.bind(computed: "counter", type: .int) { reads += 1; return .int(reads) }
    #expect(try swish.eval("counter") == .int(1))
    #expect(try swish.eval("counter + counter") == .int(5)) // 2 + 3: read each time
    do {
        _ = try swish.eval("counter = 9")
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
        #expect(error.kind == .type)
    }
}

@Test func awaitNeedsAHostThatHasSomethingToWaitFor() throws {
    let swish = interpreter()
    do {
        _ = try swish.eval("await 1")
        Issue.record("expected a diagnostic")
    } catch let error as Diagnostic {
        #expect(error.message.contains("nothing to await"))
    }
    swish.awaiting = Awaiting(operand: .int, result: .int) { value, _ in .int((value.flatMap { v -> Int? in if case .int(let n) = v { n } else { nil } } ?? 0) * 2) }
    #expect(try swish.eval("await 21") == .int(42))
}

@Test func errorsAreReportedUnderTheHostsName() {
    final class Log: @unchecked Sendable { var text = "" }
    let log = Log()
    let sink = OutputSink(write: { log.text += $0; return true })
    Interpreter(host: SwiitHost(error: sink)).report("error: no")
    Interpreter(host: SwiitHost(name: "tool", error: sink)).report("error: no")
    #expect(log.text == "swiit: error: no\ntool: error: no\n")
}

@Test func anExtensionAddsAStaticMethodToAnEnum() throws {
    let swish = interpreter()
    #expect(try swish.eval("enum Namespace {}; extension Namespace { static func answer() -> Int { 42 } }; Namespace.answer()") == .int(42))
    // Declared by separate evaluations, and beside a case.
    _ = try swish.eval("enum Level { case low }")
    _ = try swish.eval("extension Level { static func make() -> Level { .low } }")
    #expect(try swish.eval("Level.make() == .low") == .bool(true))
}

@Test func aNestedTypeIsReachedByALaterEvaluation() throws {
    let swish = interpreter()
    _ = try swish.eval("struct Code { struct Size { static func bigger() -> Int { 2 } }; enum Kind { case a } }")
    #expect(try swish.eval("Code.Size.bigger()") == .int(2))
    #expect(try swish.eval("Code.Kind.a == .a") == .bool(true))
}

private final class HostNode: SwiitObject, @unchecked Sendable {
    let label: String
    init(_ label: String) { self.label = label }
    var typeName: String { "Node" }
    var memberNames: [String] { ["label", "shout"] }
    func member(_ name: String) -> Value? {
        switch name {
        case "label": .string(label)
        case "shout": .function(Function(name: "shout", parameters: [], returnType: .string, body: .native { [label] _, _ in .string(label.uppercased()) }))
        default: nil
        }
    }
    var description: String { "Node(\(label))" }
}

@Test func aHostObjectIsTypedByTheProtocolThatDescribesIt() throws {
    let log = Log()
    let swish = interpreter(log: log)
    swish.set("nodes", .list([.object(HostNode("a")), .object(HostNode("b"))]))
    _ = try swish.eval("protocol Node { var label: String { get }; func shout() -> String }")
    // It is used as the protocol says, and passes where one is asked for.
    #expect(try swish.eval("nodes.map { $0.shout() }") == .list([.string("A"), .string("B")]))
    #expect(try swish.eval("func first(_ node: Node) -> String { node.label }; first(nodes[0])") == .string("a"))
    #expect(try swish.eval("let kept: [Node] = nodes; kept.count") == .int(2))
    // A mistake is found before anything runs.
    #expect(throws: (any Error).self) { try swish.eval(#"print("ran"); nodes.map { $0.nosuch }"#) }
    #expect(throws: (any Error).self) { try swish.eval(#"print("ran"); nodes.map { $0.label + 1 }"#) }
    #expect(throws: (any Error).self) { try swish.eval(#"print("ran"); nodes[0].shout(1)"#) }
    #expect(log.text == "")
}

@Test func aDictionaryIsAParameterAndAResult() throws {
    let swish = interpreter()
    swish.register("shout") { (words: [String: String]) in words.mapValues { $0.uppercased() } }
    #expect(try swish.eval(#"shout(["a": "x"])["a"]"#) == .string("X"))
    // The checker knows its type: a wrong one is found before the script runs.
    #expect(throws: (any Error).self) { try swish.eval(#"shout(["a": 1])"#) }
    #expect(throws: (any Error).self) { try swish.eval("shout([1, 2])") }
}

@Test func aHostCanListTheFunctionsAScriptCanCall() throws {
    let swish = interpreter()
    swish.register("greet", labels: ["name"]) { (name: String) in "hello, \(name)" }
    swish.register("check", throwing: true) { (x: Int) throws -> Int in x }
    _ = try swish.eval("func area(width: Int, height: Int = 1) -> Int { width * height }")
    let names = swish.functions.map(\.name).sorted()
    #expect(names == ["area", "check", "greet"])
    let area = try #require(swish.functions(named: "area").first)
    #expect(area.parameters.map(\.label) == ["width", "height"])
    #expect(area.parameters.map(\.hasDefault) == [false, true])
    #expect(area.returns == .int)
    #expect(try #require(swish.functions(named: "check").first).isThrowing)
    // The interpreter's own are found by name, not listed.
    #expect(!swish.functions(named: "print").isEmpty)
    #expect(swish.functions(named: "nosuch").isEmpty)
}

@Test func aWaitThatSaysHowToWakeEndsWhenTheScriptIsCancelled() throws {
    let swish = interpreter()
    swish.register("block") { () -> Int in
        let gate = DispatchSemaphore(value: 0)
        return Waiting.whileWaiting(wake: { gate.signal() }) { gate.wait(timeout: .now() + 10) == .timedOut ? 0 : 1 }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { swish.cancel() }
    let start = Date()
    _ = try? swish.eval("block()")
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func aHostTypeIsDescribedAndTheDescriptionChecked() throws {
    let swish = interpreter()
    let node = HostNode("a")
    swish.set("node", .object(node))
    // Until it is described, nothing is known of the object, so nothing is missing.
    #expect(swish.missingMembers(of: node) == [])
    try swish.describeHostType("Node", as: "var label: String { get }; func shout() -> String; func missing() -> Int")
    #expect(swish.missingMembers(of: node) == ["missing"])
    #expect(try swish.eval("node.shout()") == .string("A"))
    #expect(throws: (any Error).self) { try swish.eval("node.nosuch") }
}

private final class Preferences: DynamicObject, @unchecked Sendable {
    var values: [String: Value] = ["count": .int(2), "theme": .string("dark")]
    var typeName: String { "Preferences" }
    var memberNames: [String] { values.keys.sorted() }
    func member(_ name: String) -> Value? { values[name] }
    var description: String { "Preferences" }
    var readType: TypeAnnotation { .string }
    var writeType: TypeAnnotation { .string }
    func read(_ name: String) throws -> Value { values[name] ?? .nothing }
    func write(_ name: String, _ value: Value) throws { values[name] = value }
}

@Test func aDynamicObjectHasTheMembersTheHostDescribedTyped() throws {
    let swish = interpreter()
    swish.bind("settings", to: Preferences())
    // Every member has the one type, until some are described.
    #expect(try swish.eval("settings.theme") == .string("dark"))
    #expect(throws: (any Error).self) { try swish.eval("settings.count + 1") }
    try swish.describeHostType("Preferences", as: "var count: Int { get }")
    #expect(try swish.eval("settings.count + 1") == .int(3))
    #expect(try swish.eval("settings.theme") == .string("dark"))
}
