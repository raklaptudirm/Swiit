@_spi(Shell) @testable import Swiit
import SwishKit
import Testing

// `async` and `await` as Swift has them (Docs/Design/async.md, step 3): only
// the checker's answers are new; the interpreter waits at every wait anyway.

private func interpreter() -> Interpreter {
    Interpreter(host: SwishHost(output: OutputSink(write: { _ in true }), error: OutputSink(write: { _ in true })))
}

/// The type error the source gives, or nil if it checks.
private func typeError(_ source: String) -> String? {
    do {
        _ = try interpreter().eval(source)
        return nil
    } catch let error as Diagnostic {
        return error.kind == .type ? error.message : "not a type error: \(error.message)"
    } catch {
        return "\(error)"
    }
}

@Test func anAsyncFunctionIsAwaited() throws {
    #expect(try interpreter().eval("func f() async -> Int { 1 }; let x = await f(); x + 1") == .int(2))
    #expect(typeError("func f() async -> Int { 1 }; f()") == "'f' is async, but isn't marked with 'await'")
    // `try` and `await` together, as Swift writes them.
    #expect(try interpreter().eval("func f() async throws -> Int { 3 }; try await f()") == .int(3))
}

@Test func awaitIsWrittenInAnAsyncContext() throws {
    let source = "func f() async -> Int { 1 }; "
    #expect(typeError(source + "func g() -> Int { await f() }") == "'await' in a function that isn't async: declare it 'async'")
    #expect(try interpreter().eval(source + "func g() async -> Int { await f() + 1 }; await g()") == .int(2))
    // A closure that awaits is async itself, and is awaited too.
    #expect(try interpreter().eval(source + "let c = { await f() }; await c()") == .int(1))
    #expect(typeError(source + "let c = { await f() }; c()") == "c is async, but isn't marked with 'await'")
    // Nothing async in it: nothing to await.
    #expect(typeError("await 1")?.hasPrefix("there is nothing to await here") == true)
}

@Test func anAsyncFunctionIsntPassedWhereASyncOneIsWanted() {
    let source = "func f() async -> Int { 1 }; func twice(_ g: () -> Int) -> Int { g() + g() }; "
    #expect(typeError(source + "twice({ await f() })") != nil)
    #expect(typeError(source + "twice({ 1 })") == nil)
}

@Test func asyncIsWrittenInTypesAndPrinted() throws {
    let program = try Parser.parse("func f(_ g: () async -> Int) async throws -> Int { await g() }", bound: [:])
    guard case .function(let decl) = program.statements[0] else { Issue.record(); return }
    #expect(decl.isAsync && decl.isThrowing)
    #expect(decl.parameters[0].type == .functionType([], .int, async: .async))
    #expect(SwiftPrinter().source(program).hasPrefix("func f(_ g: () async -> Int) async throws -> Int"))
}
