@_spi(Host) @_spi(Layer) @_spi(Swiit) @testable import Swiit
import SwishKit
import Testing

// Errors of your own, as Swift has them: `throw`, types that are `Error`, and
// `catch` clauses with patterns.

private func interpreter() -> Interpreter {
    Interpreter(host: SwishHost(output: OutputSink(write: { _ in true }), error: OutputSink(write: { _ in true })))
}

private func eval(_ source: String) throws -> Value {
    let swish = interpreter()
    return try onLargeStack { try swish.eval(source) }
}

private func typeError(_ source: String) -> String? {
    do {
        _ = try eval(source)
        return nil
    } catch let error as Diagnostic {
        return error.kind == .type ? error.message : "not a type error: \(error.message)"
    } catch {
        return "\(error)"
    }
}

private let errors = """
struct Oops: Error { let code: Int }
enum Bad: Error { case input, network(code: Int) }
func check(_ n: Int) throws -> Int {
    if n < 0 { throw Oops(code: n) }
    if n == 0 { throw Bad.input }
    if n > 100 { throw Bad.network(code: n) }
    return n
}

"""

@Test func aThrownErrorIsCaught() throws {
    #expect(try eval(errors + "var got = 0; do { got = try check(5) } catch { got = -1 }; got") == .int(5))
    #expect(try eval(errors + "var got = 0; do { got = try check(-3) } catch { got = -1 }; got") == .int(-1))
    // What `catch` binds is the error itself, cast to get at its fields.
    #expect(try eval(errors + "var code = 0; do { _ = try check(-3) } catch { code = (error as? Oops)?.code ?? 0 }; code") == .int(-3))
    #expect(try eval(errors + "var s = \"\"; do { _ = try check(-3) } catch { s = error.localizedDescription }; s") == .string("Oops(code: -3)"))
}

@Test func catchClausesMatchByPattern() throws {
    let catching = errors + """
    func kind(_ n: Int) -> String {
        do {
            _ = try check(n)
            return "fine"
        } catch let oops as Oops where oops.code < -10 {
            return "very negative"
        } catch is Oops {
            return "negative"
        } catch Bad.input {
            return "zero"
        } catch Bad.network(let code) {
            return "network \\(code)"
        } catch {
            return "other"
        }
    }

    """
    #expect(try eval(catching + "[kind(1), kind(-20), kind(-1), kind(0), kind(200)]")
        == .list(["fine", "very negative", "negative", "zero", "network 200"].map(Value.string)))
}

@Test func anErrorNoClauseMatchesGoesOn() throws {
    let source = errors + """
    var log: [String] = []
    func inner() throws {
        do { _ = try check(0) } catch is Oops { log.append("inner") }
    }
    do { try inner() } catch Bad.input { log.append("outer") }
    log
    """
    #expect(try eval(source) == .list([.string("outer")]))
    // A catch that doesn't catch everything leaves the function throwing.
    #expect(typeError(errors + "func f() { do { _ = try check(0) } catch is Oops { } }")
        == "this can throw, but f isn't 'throws': mark it 'throws', or use do/catch, try? or try!")
}

@Test func onlyAnErrorIsThrown() {
    #expect(typeError("struct Plain {}; func f() throws { throw Plain() }") == "only an Error can be thrown, and Plain isn't one: declare it ': Error'")
    #expect(typeError("func f() { throw CancellationError(localizedDescription: \"x\") }")
        == "throw can throw, but f isn't 'throws': mark it 'throws', or use do/catch, try? or try!")
    // A field needn't be anything for its type to be an Error.
    #expect(typeError("struct Wrapped: Error { let values: [Int: [String]] }; func f() throws { throw Wrapped(values: [:]) }") == nil)
    #expect(typeError(errors + "do { _ = try check(1) } catch .input { }") == "an error could be of any type: write the enum's name, as in Kind.input")
}

@Test func anErrorIsAnErrorWhereOneIsWanted() throws {
    #expect(try eval("struct Oops: Error {}; let e: Error = Oops(); e is Oops") == .bool(true))
    #expect(try eval("let x: Any = 3; var s = \"\"; switch x { case let n as Int: s = \"int \\(n)\"; case is String: s = \"string\"; default: s = \"other\" }; s")
        == .string("int 3"))
}
