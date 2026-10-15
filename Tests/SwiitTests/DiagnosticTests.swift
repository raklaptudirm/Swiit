import Foundation
import Testing
@testable @_spi(Layer) @_spi(Host) import Swiit

// Where an error is: the diagnostic points at the source it came from, as a compiler does.

private func diagnostic(_ source: String) -> Diagnostic? {
    let host = SwiitHost(output: OutputSink(write: { _ in true }), error: OutputSink(write: { _ in true }))
    let interpreter = Interpreter(host: host, limits: Limits())
    do { _ = try interpreter.eval(source) } catch let diagnostic as Diagnostic { return diagnostic } catch {}
    return nil
}

@Test func aTypeErrorPointsAtTheValueThatIsWrong() throws {
    let source = "let a = 1\nlet x: Int = \"hi\"\nprint(x)"
    let found = try #require(diagnostic(source))
    #expect(found.range == SourceRange(startLine: 2, startColumn: 14, endLine: 2, endColumn: 18))
    #expect(found.rendered(in: source) == """
        error: the value must be Int, not String
         --> 2:14
          |
        2 | let x: Int = "hi"
          |              ^^^^
        """)
}

@Test func anArgumentIsWhatAnArgumentErrorPointsAt() throws {
    let source = "func f(_ n: Int) -> Int { n }\nlet r = 1 + f(\"a\")"
    let found = try #require(diagnostic(source))
    #expect(found.range?.startLine == 2 && found.range?.startColumn == 15)
}

@Test func aRuntimeErrorPointsAtTheStatementItHappenedIn() throws {
    let source = "func f(_ d: Int) -> Int {\n    let z = 10 / d\n    return z\n}\nprint(f(0))"
    let found = try #require(diagnostic(source))
    #expect(found.kind == .runtime)
    #expect(found.range?.startLine == 2 && found.range?.startColumn == 5)
    #expect(found.rendered(in: source).contains("2 |     let z = 10 / d"))
}

@Test func aSyntaxErrorPointsAtTheToken() throws {
    let source = "func f() {\n    print(1\n}\nf()"
    let found = try #require(diagnostic(source))
    #expect(found.kind == .syntax)
    #expect(found.range?.startLine == 2)
    let text = found.rendered(in: source)
    #expect(text.hasPrefix("syntax error: expected ')'"))
    #expect(!text.contains("(line"))
}

@Test func aFileNamesWhereTheErrorIs() throws {
    let source = "var n = 1\nn = \"s\""
    let found = try #require(diagnostic(source))
    #expect(found.rendered(in: source, path: "main.swift").contains("--> main.swift:2:5"))
}

@Test func aHostCanStyleWhatItShows() throws {
    let source = "let x: Int = \"hi\""
    let found = try #require(diagnostic(source))
    // The host says the escape of each character, and what frames and marks.
    let style = Diagnostic.Style(
        source: { text in text.map { $0 == "x" ? "<x>" : nil } },
        frame: { "[\($0)]" }, mark: { "{\($0)}" }, reset: "</>")
    let shown = found.rendered(in: source, style: style)
    #expect(shown.contains("let <x>x</>: Int"))
    #expect(shown.contains("[-->] 1:14"))
    #expect(shown.contains("{^^^^}"))
}
