import Foundation
import SwishKit

extension Parser {
    // MARK: Strings and interpolation

    @_spi(Shell) public mutating func parseRawString() throws(SyntaxError) -> String {
        guard let end = chars[(pos + 1)...].firstIndex(of: "'") else {
            mark(.string, from: pos, to: chars.count)
            throw .incomplete("unterminated string")
        }
        let text = String(chars[(pos + 1)..<end])
        mark(.string, from: pos, to: end + 1)
        pos = end + 1
        return text
    }

    /// A double-quoted string: Swift escapes and `\(…)`, and in commands
    /// (`dollar`) also `$name` and `$(…)`. In expressions it's pure Swift,
    /// so `"costs $5"` and `"$HOME"` are literal there.
    @_spi(Shell) public mutating func parseInterpolatedString(dollar: Bool) throws(SyntaxError) -> [StringPart] {
        let start = pos
        pos += 1
        var parts: [StringPart] = []
        var literal = ""
        while true {
            guard let c = peek() else {
                mark(.string, from: start, to: chars.count)
                throw .incomplete("unterminated string")
            }
            switch c {
            case "\"":
                pos += 1
                mark(.string, from: start)
                if !literal.isEmpty || parts.isEmpty { parts.append(.literal(literal)) }
                return parts
            case "\\":
                guard let next = peek(1) else {
                    mark(.string, from: start, to: chars.count)
                    throw .incomplete("unterminated string")
                }
                if next == "(" {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(try parseInterpolation()))
                    continue
                }
                pos += 2
                switch next {
                case "n": literal.append("\n")
                case "t": literal.append("\t")
                case "r": literal.append("\r")
                case "0": literal.append("\0")
                case "\\", "\"", "'", "$": literal.append(next)
                case "u": literal.append(try parseUnicodeEscape())
                default: throw SyntaxError("invalid escape '\\\(next)' in string")
                }
            case "$" where dollar:
                if let expr = try parseDollar() {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(expr))
                } else {
                    literal.append(c)
                    pos += 1
                }
            default:
                literal.append(c)
                pos += 1
            }
        }
    }

    /// `\u{1F600}`, positioned after the `u`.
    @_spi(Shell) public mutating func parseUnicodeEscape() throws(SyntaxError) -> Character {
        guard consume("{") else { throw SyntaxError("expected '{' after '\\u'") }
        var hex = ""
        while let c = peek(), c.isHexDigit {
            hex.append(c)
            pos += 1
        }
        guard consume("}"), let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw SyntaxError("invalid unicode escape '\\u{\(hex)'")
        }
        return Character(scalar)
    }

    /// `\(expression)`, positioned at the backslash.
    @_spi(Shell) public mutating func parseInterpolation() throws(SyntaxError) -> Expr {
        mark(.punctuation, from: pos, to: pos + 2)
        pos += 2
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        skipSpaces()
        let expr = try parseExpression()
        skipSpaces()
        guard consume(")") else { throw expected("')'") }
        mark(.punctuation, from: pos - 1)
        return expr
    }

    /// `$0` in a closure, or a `$` form of the plug-in's (`$(…)`, `$name`),
    /// positioned at the dollar sign; nil if the dollar is just a character.
    @_spi(Shell) public mutating func parseDollar() throws(SyntaxError) -> Expr? {
        switch peek(1) {
        case let c? where Parser.isDigit(c):
            // Only special in a closure without named parameters; elsewhere,
            // as in "costs $5", it's just text.
            guard let arity = anonymousArity.last ?? nil else { return nil }
            let start = pos
            pos += 1
            guard let index = Int(readDigits()) else { throw SyntaxError("closure parameter number is too large") }
            mark(.variable, from: start)
            anonymousArity[anonymousArity.count - 1] = max(arity, index + 1)
            return .variable("$\(index)")
        case "(", "?":
            guard let plugin = self.plugin else {
                throw SyntaxError("$(…) runs commands, which are shell syntax, and isn't available in Swift-only code")
            }
            return try plugin.expression(&self)
        case let c? where Parser.isIdentifierStart(c):
            guard let plugin = self.plugin else {
                throw SyntaxError("$name reads the environment, which is shell syntax, and isn't available in Swift-only code")
            }
            return try plugin.expression(&self)
        default:
            return nil
        }
    }
}
