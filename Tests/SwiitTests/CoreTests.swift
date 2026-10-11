@_spi(Layer) @testable import Swiit
import SwiitKit
import Testing

// The core on its own: the target builds and runs without the shell.

/// What a script wrote and how it ended, run on an `Interpreter` alone: no
/// `Shell`, no layer, only a host that collects output.
private func runOnTheCore(_ source: String) -> (output: String, problem: String?) {
    var output = ""
    let host = SwiitHost(output: OutputSink(write: { output += $0; return true }),
                         error: OutputSink(write: { output += "err: " + $0; return true }))
    let interpreter = Interpreter(host: host, limits: Limits())
    switch interpreter.parse(source) {
    case .failure(let error):
        return (output, "syntax error: \(error)")
    case .success(let program):
        do {
            let checked = try TypeChecker(interpreter: interpreter).check(program)
            // As a prompt would: each top-level value statement is shown.
            _ = try interpreter.run(checked) { value, _, _ in
                output += value.debugDescription + "\n"
            }
            return (output, nil)
        } catch let error as TypeError {
            return (output, "error: \(error.message)")
        } catch {
            return (output, "error: \(error)")
        }
    }
}

@Test func theCoreRunsSwiftWithoutAShell() {
    let (output, problem) = runOnTheCore("""
    let xs = [3, 1, 2]
    xs.sorted()
    struct P { var x: Int; static let origin = P(x: 0) }
    P(x: 1)
    P.origin
    func double(_ n: Int) -> Int { n * 2 }
    xs.map { double($0) }
    """)
    #expect(problem == nil)
    #expect(output == "[1, 2, 3]\nP(x: 1)\nP(x: 0)\n[6, 2, 4]\n")
}

@Test func theCoreRefusesWhatItWasNotGiven() {
    // Shell syntax doesn't parse, and there is no environment to read.
    // Two words are two statements, as in Swift: a command is the shell's.
    #expect(runOnTheCore("git status").problem?.contains("expected semicolon") == true)
    #expect(runOnTheCore("let h = $(echo hi)").problem?.contains("runs commands") == true)
    #expect(runOnTheCore(#"let h = env.HOME"#).problem?.contains("env") == true)
}

@Test func theCoreHasTheStandardLibraryButNotTheShellsFunctions() {
    // Members of Swift's types are the core's; functions that reach the file
    // system, the process or a pipeline's data are the shell's.
    let (output, problem) = runOnTheCore(#"[1, 2].map { $0 * 2 }; [1, 1, 2].uniqued()"#)
    #expect(problem == nil)
    #expect(output == "[2, 4]\n[1, 2]\n")
    for name in ["ls", "ps", "pwd", "history", "readLine", "from", "to", "table", "list", "help"] {
        #expect(runOnTheCore("\(name)()").problem?.contains("no function named '\(name)'") == true, "\(name)")
    }
}

@Test func theCorePreludeIsTheLanguagesOwn() {
    // What a `catch` binds is the language's; `members`, `select`, `help` and
    // `JSON` are declared by the shell.
    let (output, problem) = runOnTheCore(#"do { 1 / 0 } catch { print(error.localizedDescription) }"#)
    #expect(problem == nil)
    #expect(output == "division by zero\n")
    #expect(runOnTheCore("members([1])").problem != nil)
    #expect(runOnTheCore("[[\"a\": 1]].select(\"a\")").problem != nil)
    #expect(runOnTheCore("let j: JSON = 1").problem != nil)
}

/// A closure keeps only the variables it names, not the scopes around it:
/// keeping the scope it's stored in was a cycle, leaked on every call.
@Test func closuresKeepOnlyWhatTheyUse() throws {
    let swish = Interpreter()
    let value = try onLargeStack {
        try swish.eval("func f(_ i: Int) -> () -> Int { let g = { i + 1 }; let unused = [1, 2]; return g }; let h = f(1); h()")
    }
    #expect(value == .int(2))
    guard case .function(let closure as Function)? = swish.lookup("h")?.value else {
        Issue.record("h isn't a closure")
        return
    }
    let capture = try #require(closure.captured.last)
    #expect(capture.bindings.keys.sorted() == ["i"])
    // The call's scope, which held `g` and `unused`, is gone once it returned.
    #expect(!capture.fallbacks.isEmpty && capture.fallbacks.allSatisfy { $0.scope == nil })
}

/// A case's `where` is its last pattern's, as in Swift: in `case 1, 2 where c:`
/// a 1 matches whatever c is.
@Test func aCasesGuardIsItsLastPatterns() throws {
    let source = "func kind(_ n: Int) -> String { switch n { case 1, 2 where false: return \"small\"; default: return \"other\" } }; [kind(1), kind(2)]"
    let value = try onLargeStack { try Interpreter().eval(source) }
    #expect(value == .list([.string("small"), .string("other")]))
}
