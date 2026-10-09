import Foundation

// MARK: Swift types

indirect enum SType: Equatable {
    struct Element: Equatable { let label: String?; let type: SType }
    case named(String, [SType])
    case member(SType, String)
    case array(SType)
    case dictionary(SType, SType)
    case optional(SType)
    case function([SType], SType, throwing: Bool)
    case tuple([Element])
    /// A parameter `S` where `S: Sequence, S.Element == E`: any sequence of
    /// E, which the glue passes as an array.
    case someSequence(SType)
}

struct Unsupported: Error { let reason: String }

/// Parses Swift's spelling of types and declarations, as far as bridging
/// needs; anything else is `Unsupported`.
struct Reader {
    var chars: [Character]
    var pos = 0

    init(_ text: String) { chars = Array(text) }

    var atEnd: Bool { skipSpacesCopy() >= chars.count }
    func peek(_ offset: Int = 0) -> Character? { pos + offset < chars.count ? chars[pos + offset] : nil }

    func skipSpacesCopy() -> Int {
        var p = pos
        while p < chars.count && chars[p].isWhitespace { p += 1 }
        return p
    }
    mutating func skipSpaces() { pos = skipSpacesCopy() }

    mutating func consume(_ text: String) -> Bool {
        pos = skipSpacesCopy()
        let target = Array(text)
        guard pos + target.count <= chars.count, Array(chars[pos..<pos + target.count]) == target else { return false }
        // A keyword mustn't run into an identifier.
        if let last = target.last, last.isLetter, pos + target.count < chars.count,
           chars[pos + target.count].isLetter || chars[pos + target.count].isNumber || chars[pos + target.count] == "_" { return false }
        pos += target.count
        return true
    }

    /// An operator's name, `+` or `<=`.
    mutating func operatorName() -> String? {
        pos = skipSpacesCopy()
        var end = pos
        while end < chars.count, "/=-+!*%<>&|^~?.".contains(chars[end]) { end += 1 }
        guard end > pos else { return nil }
        defer { pos = end }
        return String(chars[pos..<end])
    }

    mutating func identifier() -> String? {
        pos = skipSpacesCopy()
        // `extension`: a keyword used as a name.
        if peek() == "`", let close = chars[(pos + 1)...].firstIndex(of: "`"), close > pos + 1 {
            defer { pos = close + 1 }
            return String(chars[(pos + 1)..<close])
        }
        var end = pos
        while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
        guard end > pos, !chars[pos].isNumber else { return nil }
        defer { pos = end }
        return String(chars[pos..<end])
    }

    /// `P & Q`, where `~Copyable` (a suppressed conformance) says nothing.
    mutating func protocols() throws -> [String] {
        var protocols: [String] = []
        repeat {
            let suppressed = consume("~")
            guard let name = identifier() else { throw Unsupported(reason: "constraint") }
            if !suppressed { protocols.append(name) }
        } while consume("&")
        return protocols
    }

    mutating func type() throws -> SType {
        var result: SType
        pos = skipSpacesCopy()
        for word in ["some ", "any ", "inout ", "borrowing ", "consuming ", "sending ", "__owned ", "__shared "] where consume(word.trimmingCharacters(in: .whitespaces)) {
            throw Unsupported(reason: word)
        }
        while consume("@escaping") {}
        if consume("@autoclosure") { throw Unsupported(reason: "@autoclosure") }
        if consume("[") {
            let element = try type()
            if consume(":") {
                let value = try type()
                guard consume("]") else { throw Unsupported(reason: "dictionary") }
                result = .dictionary(element, value)
            } else {
                guard consume("]") else { throw Unsupported(reason: "array") }
                result = .array(element)
            }
        } else if consume("(") {
            var elements: [SType.Element] = []
            if !consume(")") {
                repeat {
                    // A tuple's labels are kept; a function's parameters have none.
                    let save = pos
                    var label: String?
                    if let name = identifier(), consume(":") { label = name } else { pos = save }
                    elements.append(.init(label: label, type: try type()))
                } while consume(",")
                guard consume(")") else { throw Unsupported(reason: "tuple") }
            }
            var throwing = false
            if consume("throws") {
                // `throws(E)` with a generic E: throws whatever it throws.
                if consume("(") { _ = identifier(); _ = consume(")") }
                throwing = true
            }
            if consume("async") { throw Unsupported(reason: "async") }
            if consume("->") {
                result = .function(elements.map(\.type), try type(), throwing: throwing)
            } else if elements.count == 1 && elements[0].label == nil {
                result = elements[0].type
            } else {
                result = .tuple(elements)
            }
        } else {
            guard let name = identifier() else { throw Unsupported(reason: "type at \(String(chars[pos...]).prefix(20))") }
            var arguments: [SType] = []
            if peek() == "<" {
                pos += 1
                repeat { arguments.append(try type()) } while consume(",")
                guard consume(">") else { throw Unsupported(reason: "generic arguments") }
            }
            result = .named(name, arguments)
        }
        while true {
            if peek() == "?" { pos += 1; result = .optional(result); continue }
            if peek() == "!" { throw Unsupported(reason: "implicitly unwrapped") }
            if peek() == ".", let next = peek(1), next.isLetter {
                pos += 1
                guard let member = identifier() else { break }
                if member == "Type" || member == "Protocol" { throw Unsupported(reason: "metatype") }
                result = .member(result, member)
                continue
            }
            break
        }
        return result
    }
}
