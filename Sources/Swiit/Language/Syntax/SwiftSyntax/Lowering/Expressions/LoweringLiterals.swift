import SwiftSyntax

// Lowering literals: numbers in their radixes, and strings with their escapes.

extension Lowering {
    func parseRadix(_ text: String) -> Int? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("0x") { return Int(lowered.dropFirst(2), radix: 16) }
        if lowered.hasPrefix("0b") { return Int(lowered.dropFirst(2), radix: 2) }
        if lowered.hasPrefix("0o") { return Int(lowered.dropFirst(2), radix: 8) }
        return nil
    }

    mutating func string(_ node: StringLiteralExprSyntax) throws -> Expr {
        // `"…"`, `"""…"""` and either with `#` delimiters, where an escape is `\#n`.
        let pounds = node.openingPounds?.text.count ?? 0
        let multiline = node.openingQuote.tokenKind == .multilineStringQuote
        guard node.openingQuote.tokenKind == .stringQuote || multiline else {
            throw unsupported("this string", node)
        }
        // A multi-line string drops the closing quotes' indentation from every line.
        var indent = ""
        if multiline {
            let trivia = node.closingQuote.leadingTrivia.description
            indent = String(
                trivia.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            )
            guard indent.allSatisfy({ $0 == " " || $0 == "\t" }) else {
                throw unsupported("this string", node)
            }
        }
        var parts: [StringPart] = []
        var text = ""
        var atLineStart = multiline
        func flush() { if !text.isEmpty { parts.append(.literal(text)); text = "" } }
        for segment in node.segments {
            switch segment {
            case .stringSegment(let literal):
                var raw = literal.content.text
                if multiline && !indent.isEmpty {
                    var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                    for index in lines.indices where index > 0 || atLineStart {
                        if lines[index].hasPrefix(indent) {
                            lines[index].removeFirst(indent.count)
                        } else if lines[index].allSatisfy({ $0 == " " || $0 == "\t" }) {
                            lines[index] = ""
                        }
                    }
                    raw = lines.joined(separator: "\n")
                }
                if multiline { atLineStart = raw.hasSuffix("\n") }
                guard let unescaped = unescape(raw, pounds: pounds) else {
                    throw SyntaxError(
                        "invalid escape in string: write \\\\ for a backslash, or use single quotes ('…') to keep every backslash (line \(line(of: literal)))"
                    )
                }
                text += unescaped
            case .expressionSegment(let interpolation):
                guard interpolation.expressions.count == 1,
                    let inner = interpolation.expressions.first
                else {
                    throw unsupported("this interpolation", interpolation)
                }
                flush()
                atLineStart = false
                parts.append(.expression(try expression(inner.expression)))
            }
        }
        // The newline before the closing quotes isn't part of a multi-line string.
        if multiline, text.hasSuffix("\n") { text.removeLast() }
        flush()
        if parts.isEmpty { return .literal(.string("")) }
        if parts.count == 1, case .literal(let only) = parts[0] { return .literal(.string(only)) }
        return .string(parts)
    }

    /// A string's text with its escapes made: `\n`, or with `#` delimiters `\#n`
    /// (a `\` alone is itself there).
    private func unescape(_ text: String, pounds: Int = 0) -> String? {
        let introducer = Array("\\" + String(repeating: "#", count: pounds))
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index...].starts(with: introducer) else {
                result.append(characters[index])
                index += 1
                continue
            }
            index += introducer.count
            guard index < characters.count else { return nil }
            let next = characters[index]
            index += 1
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "'": result.append("'")
            case "\n": break  // A line continuation, in a multi-line string.
            case "u":
                guard index < characters.count, characters[index] == "{" else { return nil }
                index += 1
                var digits = ""
                while index < characters.count, characters[index] != "}" {
                    digits.append(characters[index]); index += 1
                }
                index += 1
                guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value)
                else { return nil }
                result.unicodeScalars.append(scalar)
            default: return nil
            }
        }
        return result
    }
}
