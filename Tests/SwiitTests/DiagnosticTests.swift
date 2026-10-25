import Foundation
import Testing

@testable import Swiit

// Where an error is: the diagnostic points at the source it came from, as a compiler does.

private func diagnostic(_ source: String) -> Diagnostic? {
    let host = Interpreter.Host(output: OutputSink({ _ in true }), error: OutputSink({ _ in true }))
    let interpreter = Interpreter(host: host, limits: Interpreter.Limits())
    do { _ = try interpreter.evaluate(source) } catch { return error }
    return nil
}

@Test func aTypeErrorPointsAtTheValueThatIsWrong() throws {
    let source = "let a = 1\nlet x: Int = \"hi\"\nprint(x)"
    let found = try #require(diagnostic(source))
    #expect(
        found.range?.start.line == 2 && found.range?.start.column == 14
            && found.range?.end.line == 2 && found.range?.end.column == 18
    )
    #expect(
        found.rendered(in: source) == """
            error: the value must be Int, not String
             --> 2:14
              |
            2 | let x: Int = "hi"
              |              ^^^^
            """
    )
}

@Test func aColumnCountsBytesAndTheMarkCountsCharacters() throws {
    // SwiftSyntax's columns are UTF-8 bytes (`é` is two), but the mark is laid out in characters.
    let source = "let s = \"héllo\"; let x: Int = \"hi\""
    let found = try #require(diagnostic(source))
    #expect(found.range?.start.column == 32)
    #expect(
        found.rendered(in: source) == """
            error: the value must be Int, not String
             --> 1:31
              |
            1 | let s = "héllo"; let x: Int = "hi"
              |                               ^^^^
            """
    )
}

@Test func anArgumentIsWhatAnArgumentErrorPointsAt() throws {
    let source = "func f(_ n: Int) -> Int { n }\nlet r = 1 + f(\"a\")"
    let found = try #require(diagnostic(source))
    #expect(found.range?.start.line == 2 && found.range?.start.column == 15)
}

@Test func aRuntimeErrorPointsAtTheStatementItHappenedIn() throws {
    let source = "func f(_ d: Int) -> Int {\n    let z = 10 / d\n    return z\n}\nprint(f(0))"
    let found = try #require(diagnostic(source))
    #expect(found.isRuntime)
    #expect(found.range?.start.line == 2 && found.range?.start.column == 5)
    #expect(found.rendered(in: source).contains("2 |     let z = 10 / d"))
}

@Test func aSyntaxErrorPointsAtTheToken() throws {
    let source = "func f() {\n    print(1\n}\nf()"
    let found = try #require(diagnostic(source))
    #expect(found.isSyntax)
    #expect(found.range?.start.line == 2)
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
        frame: { "[\($0)]" },
        mark: { "{\($0)}" },
        reset: "</>"
    )
    let shown = found.rendered(in: source, style: style)
    #expect(shown.contains("let <x>x</>: Int"))
    #expect(shown.contains("[-->] 1:14"))
    #expect(shown.contains("{^^^^}"))
}
