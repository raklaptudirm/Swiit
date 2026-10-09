@_spi(Shell) @testable import Swiit
import SwishKit
import Testing

// The core on its own: the target builds and runs without the shell.

/// What a script wrote and how it ended, run on an `Interpreter` alone: no
/// `Shell`, no layer, only a host that collects output.
private func runOnTheCore(_ source: String) -> (output: String, problem: String?) {
    var output = ""
    let host = SwishHost(output: OutputSink(write: { output += $0; return true }),
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
    #expect(runOnTheCore("git status").problem?.contains("no variable named 'git'") == true)
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
