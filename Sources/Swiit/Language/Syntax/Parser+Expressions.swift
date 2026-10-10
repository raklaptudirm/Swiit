import Foundation
import SwishKit

extension Parser {
    // MARK: Expression mode

    /// `logical` is false for an expression that is a whole unit, so that
    /// `&&` and `||` are left to join it with commands in a chain.
    /// `try`, `try?` and `try!` cover everything to their right, as in
    /// Swift: `(try? $(cmd)) ?? "default"` needs its parentheses.
    @_spi(Shell) public mutating func parseExpression(logical: Bool = true) throws(SyntaxError) -> Expr {
        skipSpaces()
        if let kind = try parseTry() {
            tryDepth += 1
            defer { tryDepth -= 1 }
            let operand = try parseExpression(logical: logical)
            return .attempt(operand, kind ?? .plain)
        }
        let condition = try parseBinary(level: logical ? 0 : Parser.comparisonLevel)
        guard ternaryAhead() else { return condition }
        // `c ? a : b`, right-associative: `a ? b : c ? d : e`.
        skipSpaces()
        pos += 1
        skipSpaces(newlines: true)
        let then = try parseExpression()
        skipSpaces(newlines: true)
        guard consume(":") else { throw expected("':' in 'condition ? then : else'") }
        skipSpaces(newlines: true)
        let otherwise = try parseExpression()
        return .ifExpression(IfStatement(
            condition: .expression(condition),
            then: IfStatement.branch(then), otherwise: IfStatement.branch(otherwise)
        ))
    }

    /// Whether a ternary's `?` comes next: with space on both sides, as
    /// Swift wants, so `x?.y`, `try?` and `Int?` aren't one.
    @_spi(Shell) public func ternaryAhead() -> Bool {
        var index = pos
        while index < chars.count, chars[index] == " " || chars[index] == "\t" || (bracketDepth > 0 && chars[index] == "\n") { index += 1 }
        guard index > 0, " \t\n".contains(chars[index - 1]), index + 1 < chars.count, chars[index] == "?" else { return false }
        return " \t\n".contains(chars[index + 1])
    }

    /// `try` (.some(nil)), `try?` or `try!` at the current position; nil if none.
    @_spi(Shell) public mutating func parseTry() throws(SyntaxError) -> TryKind?? {
        guard identifier() == "try" else { return nil }
        let start = pos
        pos += "try".count
        var kind: TryKind?
        if consume("?") {
            kind = .optional
        } else if consume("!") {
            kind = .forced
        }
        mark(.keyword, from: start)
        return .some(kind)
    }

    @_spi(Shell) public mutating func parseBinary(level: Int) throws(SyntaxError) -> Expr {
        guard level < Parser.precedence.count else { return try parseUnary() }
        var lhs = try parseOperand(level: level)
        var chained = false
        while true {
            skipSpaces()
            guard let op = Parser.precedence[level].first(where: { startsWith($0.rawValue) }) else {
                return lhs
            }
            if Parser.nonAssociativeLevels.contains(level) {
                if chained { throw SyntaxError("'\(op.rawValue)' can't be chained; use parentheses or '&&'") }
                chained = true
            }
            pos += op.rawValue.count
            skipSpaces(newlines: true)
            // `??` groups to the right, as in Swift: `a ?? b ?? c` is `a ?? (b ?? c)`.
            if op == .coalesce { return .binary(op, lhs, try parseBinary(level: level)) }
            lhs = .binary(op, lhs, try parseOperand(level: level))
        }
    }

    /// An operand of `level`'s operators. `??`'s may be cast, as Swift's
    /// precedence has it: `x ?? y as? Int` is `x ?? (y as? Int)`.
    @_spi(Shell) public mutating func parseOperand(level: Int) throws(SyntaxError) -> Expr {
        var expr = try parseBinary(level: level + 1)
        guard Parser.precedence[level] == [.coalesce] else { return expr }
        while true {
            let before = (pos, spans.count)
            skipSpaces()
            let start = pos
            let kind: CastKind
            switch identifier() {
            case "as":
                pos += 2
                kind = consume("?") ? .conditional : consume("!") ? .forced : .upcast
            case "is":
                pos += 2
                kind = .check
            default:
                rewind(to: before)
                return expr
            }
            mark(.keyword, from: start)
            skipSpaces()
            expr = .cast(expr, try parseType(), kind)
        }
    }

    @_spi(Shell) public mutating func parseUnary() throws(SyntaxError) -> Expr {
        skipSpaces()
        if consume("!") { return .unary(.not, try parseUnary()) }
        if consume("-") { return .unary(.negate, try parseUnary()) }
        // After an operator, as in `x + try? f()`, it covers the rest.
        if identifier() == "try" {
            return try parseExpression()
        }
        if identifier() == "async" {
            guard let plugin = self.plugin, let expr = try plugin.expression(&self) else {
                throw SyntaxError("'async' starts a command in the background, which is shell syntax; Swift-only code has no async yet")
            }
            return expr
        }
        if identifier() == "await" {
            keyword("await")
            skipSpaces()
            // A bare `await` brings back the most recent job.
            let ends = peek().map { ";\n)}],".contains($0) } ?? true || startsWith("&&") || startsWith("||")
            return .await(ends ? nil : try parseUnary(), throwing: tryDepth > 0)
        }
        var expr = try parsePrimary()
        // Postfix operators bind only without a space: `f(x)`, `xs[0]`.
        while true {
            if peek() == "[" {
                pos += 1
                bracketDepth += 1
                skipSpaces()
                let index = try parseExpression()
                skipSpaces()
                guard consume("]") else { throw expected("']'") }
                bracketDepth -= 1
                expr = .index(expr, index)
            } else if peek() == "(" {
                var arguments = try parseArguments()
                // A trailing closure, as in `with(env: e) { … }`; not where
                // `{` starts a body, as after `if` or `for … in`.
                let beforeClosure = (pos, spans.count)
                skipSpaces()
                if peek() == "{" && conditionDepth == 0 {
                    pos += 1
                    arguments.append(Argument(label: nil, value: .closure(try parseClosure())))
                } else {
                    rewind(to: beforeClosure)
                }
                expr = .call(expr, arguments)
            } else if peek() == "!", peek(1) != "=" {
                pos += 1
                expr = .forceUnwrap(expr)
            } else if peek() == "?", peek(1) == "[" {
                pos += 2
                bracketDepth += 1
                skipSpaces()
                let index = try parseExpression()
                skipSpaces()
                guard consume("]") else { throw expected("']'") }
                bracketDepth -= 1
                expr = .optionalIndex(expr, index)
            } else if peek() == "?", peek(1) == ".", let next = peek(2), Parser.isIdentifierStart(next) {
                pos += 2
                let name = identifier()!
                pos += name.count
                expr = .optionalMember(expr, name)
            } else if peek() == ".", let next = peek(1), Parser.isDigit(next) {
                // `pair.0`: a tuple's element by position.
                pos += 1
                var digits = ""
                while let c = peek(), Parser.isDigit(c) {
                    digits.append(c)
                    pos += 1
                }
                expr = .member(expr, digits)
            } else if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
                pos += 1
                let name = identifier()!
                pos += name.count
                expr = .member(expr, name)
                // `xs.filter { … }`: a call with only a trailing closure.
                let beforeClosure = (pos, spans.count)
                skipSpaces()
                if peek() == "{" && peek(1) != "}" && conditionDepth == 0 {
                    pos += 1
                    expr = .call(expr, [Argument(label: nil, value: .closure(try parseClosure()))])
                } else {
                    rewind(to: beforeClosure)
                }
            } else {
                return expr
            }
        }
    }

    @_spi(Shell) public mutating func parseArguments() throws(SyntaxError) -> [Argument] {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var arguments: [Argument] = []
        skipSpaces()
        if consume(")") { return arguments }
        while true {
            var label: String?
            if let name = identifier(), peek(name.count) == ":" {
                label = name
                pos += name.count + 1
            }
            arguments.append(Argument(label: label, value: try parseExpression()))
            skipSpaces()
            if consume(")") { return arguments }
            guard consume(",") else { throw expected("',' or ')'") }
            skipSpaces()
        }
    }

    @_spi(Shell) public mutating func parsePrimary() throws(SyntaxError) -> Expr {
        skipSpaces()
        guard let c = peek() else { throw .incomplete("expected an expression") }
        if Parser.isDigit(c) { return try parseNumber() }
        if identifier() == "if" {
            // `let x = if c { a } else { b }`, as in Swift.
            let node = try parseIf()
            guard node.otherwise != nil else { throw SyntaxError("an if expression needs an else") }
            guard let expression = node.asExpression else {
                throw SyntaxError("each branch of an if expression must be one expression")
            }
            return .ifExpression(expression)
        }

        switch c {
        case "\"":
            let parts = try parseInterpolatedString(dollar: false)
            if parts.count == 1, case .literal(let text) = parts[0] { return .literal(.string(text)) }
            return .string(parts)
        case "'":
            return .literal(.string(try parseRawString()))
        case "(":
            // `(x)` groups; `(a, b)` and `(name: x)` are tuples; `()` is Void.
            pos += 1
            bracketDepth += 1
            defer { bracketDepth -= 1 }
            skipSpaces()
            if consume(")") { return .tuple([]) }
            var elements: [Argument] = []
            while true {
                skipSpaces()
                var label: String?
                if let word = identifier(), peek(word.count) == ":", peek(word.count + 1) != ":" {
                    label = word
                    pos += word.count + 1
                }
                elements.append(Argument(label: label, value: try parseExpression()))
                skipSpaces()
                if consume(")") { break }
                guard consume(",") else { throw expected("',' or ')'") }
            }
            if elements.count == 1 && elements[0].label == nil { return elements[0].value }
            return .tuple(elements)
        case "[":
            return try parseList()
        case "{":
            pos += 1
            return .closure(try parseClosure())
        case "." where peek(1).map(Parser.isIdentifierStart) ?? false:
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.constant, from: start)
            return .caseLiteral(name, peek() == "(" ? try parseArguments() : nil)
        case "$":
            guard let expr = try parseDollar() else { throw unexpected(c) }
            return expr
        case "#" where startsWith("#filePath"):
            mark(.keyword, from: pos, to: pos + 9)
            pos += 9
            return .filePath
        case "\\" where peek(1) == "." || peek(1).map(Parser.isIdentifierStart) ?? false:
            // `\.size.bytes`, or with its root, `\FileEntry.size`.
            let start = pos
            pos += 1
            var root: String?
            if let name = identifier() {
                root = name
                pos += name.count
            }
            var path: [String] = []
            while peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) || Parser.isDigit(next) {
                pos += 1
                var name = identifier() ?? ""
                if name.isEmpty { while let d = peek(), Parser.isDigit(d) { name.append(d); pos += 1 } } else { pos += name.count }
                path.append(name)
            }
            guard !path.isEmpty else { throw expected("a member after '\\'") }
            mark(.variable, from: start)
            return .keyPath(root: root, path: path)
        default:
            break
        }

        guard let name = identifier() else { throw unexpected(c) }
        let nameStart = pos
        pos += name.count
        switch name {
        case "true", "false", "nil": mark(.constant, from: nameStart)
        default: mark(.variable, from: nameStart)
        }
        switch name {
        case "true": return .literal(.bool(true))
        case "false": return .literal(.bool(false))
        case "nil": return .literal(.nothing)
        default: break
        }
        if Parser.keywords.contains(name) {
            throw SyntaxError("expected an expression, found '\(name)'")
        }
        guard kind(of: name) != nil || (sawImport && peek() == "(") else {
            throw SyntaxError(peek() == "(" ? "no function named '\(name)'" : "no variable named '\(name)'")
        }
        if kind(of: name) == .member {
            use("self")
            return .member(.variable("self"), name)
        }
        if case .staticMember(let type)? = kind(of: name) {
            use(type)
            return .member(.variable(type), name)
        }
        use(name)
        return .variable(name)
    }

    /// `[1, 2]`, or a record like `["name": "x", "size": 1.kb]` or `[:]`.
    @_spi(Shell) public mutating func parseList() throws(SyntaxError) -> Expr {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        skipSpaces()
        if consume(":") {
            skipSpaces()
            guard consume("]") else { throw expected("']'") }
            return .record([])
        }
        var elements: [Expr] = []
        var entries: [RecordEntry] = []
        // Decided by the first element: a colon after it makes a record.
        var isRecord: Bool?
        while peek() != "]" {
            let element = try parseExpression()
            skipSpaces()
            if isRecord == nil {
                isRecord = consume(":")
            } else if isRecord == true {
                guard consume(":") else { throw expected("':' in a record literal") }
            }
            if isRecord == true {
                entries.append(RecordEntry(key: element, value: try parseExpression()))
            } else {
                elements.append(element)
            }
            skipSpaces()
            guard consume(",") else { break }
            skipSpaces()
        }
        guard consume("]") else { throw expected("']'") }
        return isRecord == true ? .record(entries) : .list(elements)
    }

    @_spi(Shell) public mutating func parseNumber() throws(SyntaxError) -> Expr {
        let start = pos
        defer { mark(.number, from: start) }
        var text = readDigits()
        var isDouble = false
        if peek() == ".", let next = peek(1), Parser.isDigit(next) {
            isDouble = true
            pos += 1
            text += "." + readDigits()
        }
        if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
            pos += 1
            let unit = identifier()!
            guard FileSize.units[unit] != nil else {
                throw SyntaxError("unknown unit '\(unit)'; file sizes use b, kb, mb, gb, tb, or kib, mib, gib, tib")
            }
            pos += unit.count
            guard let size = FileSize(Double(text)!, unit: unit) else { throw SyntaxError("file size \(text).\(unit) is too large") }
            return .literal(.fileSize(size))
        }
        if let c = peek(), Parser.isIdentifierPart(c) {
            throw SyntaxError("unexpected '\(c)' after a number (use ^ to run a command whose name starts with a digit)")
        }
        if isDouble { return .literal(.double(Double(text)!)) }
        guard let value = Int(text) else { throw SyntaxError("integer literal \(text) is too large") }
        return .literal(.int(value))
    }
}
