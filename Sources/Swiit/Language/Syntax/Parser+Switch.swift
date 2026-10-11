import Foundation
import SwiitKit

extension Parser {
    /// `switch subject { case …: … default: … }`
    mutating func parseSwitch() throws(SyntaxError) -> SwitchStatement {
        keyword("switch")
        skipSpaces()
        conditionDepth += 1
        let subject = try parseExpression()
        conditionDepth -= 1
        skipSpaces()
        guard consume("{") else { throw expected("'{'") }
        switchDepth += 1
        defer { switchDepth -= 1 }

        var cases: [SwitchCase] = []
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            if identifier() == "default" {
                keyword("default")
                skipSpaces()
                guard consume(":") else { throw expected("':' after 'default'") }
                cases.append(SwitchCase(patterns: [], body: try parseCaseBody(declaring: [:])))
                continue
            }
            guard identifier() == "case" else { throw expected("'case' or 'default'") }
            keyword("case")
            var patterns = [try parsePattern()]
            skipSpaces()
            while consume(",") {
                skipSpaces(newlines: true)
                patterns.append(try parsePattern())
                skipSpaces()
            }
            // Every pattern must bind the same names, for the body to use.
            let names = Set(Parser.names(boundBy: patterns[0]))
            guard patterns.allSatisfy({ Set(Parser.names(boundBy: $0)) == names }) else {
                throw SyntaxError("each pattern in a case must bind the same names")
            }
            var bound: [String: NameKind] = [:]
            for name in names { bound[name] = .variable }
            scopes.append(bound)
            defer { scopes.removeLast() }
            var guardExpr: Expr?
            if identifier() == "where" {
                keyword("where")
                guardExpr = try parseExpression()
                skipSpaces()
            }
            guard consume(":") else { throw expected("':' after the case") }
            cases.append(SwitchCase(patterns: patterns, guardExpr: guardExpr, body: try parseCaseBody(declaring: [:])))
        }
        return SwitchStatement(subject: subject, cases: cases)
    }

    /// The statements after `case …:`, up to the next case or the `}`.
    mutating func parseCaseBody(declaring names: [String: NameKind]) throws(SyntaxError) -> Program {
        scopes.append(names)
        defer { scopes.removeLast() }
        var statements: [Statement] = []
        while true {
            skipSeparators()
            guard let c = peek() else { throw .incomplete("expected '}'") }
            if c == "}" || identifier() == "case" || identifier() == "default" { break }
            statements.append(try parseStatement())
            skipSpaces()
            guard let next = peek() else { continue }
            guard next == ";" || next == "\n" || next == "}" else { throw unexpected(next) }
        }
        guard !statements.isEmpty else {
            throw SyntaxError("a case needs at least one statement; write `break` to do nothing")
        }
        return Program(statements: statements)
    }

    /// A pattern: `_`, `let x`, `.name(…)`, `Type.name(…)`, or an
    /// expression to compare with. Under `let`/`var` (`binding`), names in
    /// it bind rather than refer: `let .failed(code)`.
    mutating func parsePattern(binding: Bool = false, mutable: Bool = false) throws(SyntaxError) -> Pattern {
        skipSpaces()
        // `is Oops`: a value of the type.
        if identifier() == "is" {
            keyword("is")
            skipSpaces()
            return .isType(try parseType())
        }
        let pattern = try parsePlainPattern(binding: binding, mutable: mutable)
        // `let e as Oops`, `_ as Int`: matched as a value of the type.
        let beforeCast = (pos, spans.count)
        skipSpaces()
        guard identifier() == "as" else {
            rewind(to: beforeCast)
            return pattern
        }
        keyword("as")
        skipSpaces()
        return .cast(pattern, try parseType())
    }

    private mutating func parsePlainPattern(binding: Bool, mutable: Bool) throws(SyntaxError) -> Pattern {
        if let word = identifier(), word == "let" || word == "var" {
            keyword(word)
            return try parsePattern(binding: true, mutable: word == "var")
        }
        if identifier() == "_" {
            pos += 1
            return .wildcard
        }
        if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.constant, from: start)
            return .enumCase(type: nil, name: name, arguments: peek() == "(" ? try parsePatternArguments(binding: binding, mutable: mutable) : nil)
        }
        if let word = identifier(), kind(of: word) == .type, peek(word.count) == "." {
            mark(.type, from: pos, to: pos + word.count)
            pos += word.count + 1
            let name = try parseName(after: "'.'")
            return .enumCase(type: word, name: name, arguments: peek() == "(" ? try parsePatternArguments(binding: binding, mutable: mutable) : nil)
        }
        if binding, let word = identifier(), !Parser.keywords.contains(word) {
            mark(.variable, from: pos, to: pos + word.count)
            pos += word.count
            return .binding(name: word, mutable: mutable)
        }
        return .expression(try parseExpression(logical: false))
    }

    mutating func parsePatternArguments(binding: Bool, mutable: Bool) throws(SyntaxError) -> [PatternArgument] {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var arguments: [PatternArgument] = []
        skipSpaces()
        while !consume(")") {
            var label: String?
            if let word = identifier(), word != "let", word != "var", peek(word.count) == ":" {
                label = word
                pos += word.count + 1
                skipSpaces()
            }
            arguments.append(PatternArgument(label: label, pattern: try parsePattern(binding: binding, mutable: mutable)))
            skipSpaces()
            if consume(",") { skipSpaces() } else if peek() != ")" { throw expected("',' or ')'") }
        }
        return arguments
    }
}
