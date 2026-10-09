import Foundation
import SwishKit

/// What a name refers to, which decides the mode of a statement starting
/// with it: a variable starts an expression, a function starts a command
/// unless it's followed by `(`.
@_spi(Shell) public enum NameKind: Equatable, Sendable {
    /// `type`: an enum's or struct's name, as in `FileType.directory`.
    /// `member`: a property or method of the struct whose body this is,
    /// read through `self`. `staticMember`: a static one, read in a static
    /// member's body through the type's name.
    case variable, function, type, member
    case staticMember(of: String)
}

public struct SyntaxError: Error, Equatable, CustomStringConvertible {
    public let description: String
    /// The input ended in the middle of a construct, so more lines could complete it.
    public let incomplete: Bool

    @_spi(Shell) public init(_ description: String, incomplete: Bool = false) {
        self.description = description
        self.incomplete = incomplete
    }

    @_spi(Shell) public static func incomplete(_ description: String) -> SyntaxError {
        SyntaxError(description, incomplete: true)
    }
}

/// What a stretch of source is, for syntax highlighting. The parser
/// records these as it goes, so the colors always agree with how the line
/// will actually be read.
@_spi(Shell) public enum SpanKind: Equatable, Sendable {
    case keyword, command, flag, string, number, constant, variable, comment, type, punctuation
}

@_spi(Shell) public struct Span: Equatable, Sendable {
    @_spi(Shell) public var range: Range<Int>
    @_spi(Shell) public var kind: SpanKind

    @_spi(Shell) public init(range: Range<Int>, kind: SpanKind) {
        self.range = range
        self.kind = kind
    }
}

// MARK: - Parser

/// A recursive-descent parser over characters rather than tokens, because
/// command mode and expression mode split text differently: `-la` is a word
/// in one and a negation in the other.
///
/// Mode is decided per unit, by what parses there (see `commandAhead`).
/// Deciding it needs to know which names exist and what they are, so the
/// parser tracks declarations lexically, seeded with the shell's globals.
@_spi(Shell) public struct Parser {
    @_spi(Shell) public static let keywords: Set = [
        "let", "var", "if", "else", "true", "false", "nil",
        "for", "in", "while", "func", "return", "break", "continue", "try", "do", "catch",
        "async", "await", "enum", "switch", "case", "default", "fallthrough", "import", "struct", "throws",
        "as", "is", "defer", "guard",
    ]
    @_spi(Shell) public static let statementKeywords: Set = ["let", "var", "func", "return", "break", "continue", "do", "catch", "enum", "fallthrough", "import", "struct", "defer", "guard"]
    /// The keywords a line can begin with: a statement's, a unit's
    /// (`if make { … }`), or an expression's (`await job`). Completion
    /// offers them where a command could go.
    @_spi(Shell) public static let lineStarts = statementKeywords.subtracting(["catch"])
        .union(["if", "for", "while", "switch", "try", "async", "await"])
    /// The words a command can follow directly and still be in command
    /// position: `if make {`, `while pgrep x {`, `} else make`, `foreign ls`.
    @_spi(Shell) public static let beforeCommand: Set = ["if", "while", "else", "foreign"]
    @_spi(Shell) public static let precedence: [[BinaryOperator]] = [
        [.or],
        [.and],
        // Two-character operators first, so `<=` isn't read as `<`.
        [.equal, .notEqual, .lessEqual, .greaterEqual, .less, .greater],
        [.coalesce],
        [.closedRange, .halfOpenRange],
        [.add, .subtract],
        [.multiply, .divide, .remainder],
    ]
    @_spi(Shell) public static let comparisonLevel = 2
    /// Levels whose operators can't be chained, like `a < b < c`.
    @_spi(Shell) public static let nonAssociativeLevels: Set = [2, 4]

    @_spi(Shell) public let chars: [Character]
    @_spi(Shell) public var pos = 0
    /// Syntax added to Swift's, which the grammar asks about where it has no
    /// meaning for what is there. Nil is Swift alone (SyntaxPlugin.swift).
    @_spi(Shell) public var plugin: (any SyntaxPlugin)?
    @_spi(Shell) public var scopes: [[String: NameKind]]
    /// Parsing the prelude: builtins' declarations, which may be generic and
    /// have no bodies (their bodies are in Swift).
    @_spi(Shell) public var prelude = false
    /// Type parameters in scope, innermost last: `T`, or `Element`.
    @_spi(Shell) public var typeParameters: [Set<String>] = []
    /// The names each body being parsed mentions, innermost last.
    @_spi(Shell) public var namesUsed: [Set<String>] = []
    /// What the body just parsed mentioned.
    @_spi(Shell) public var lastBodyNames = NamesUsed()

    /// A name the body being parsed refers to.
    @_spi(Shell) public mutating func use(_ name: String) {
        guard !namesUsed.isEmpty else { return }
        namesUsed[namesUsed.count - 1].insert(name)
    }
    /// An `import` came earlier: the functions it brings aren't known until
    /// it runs, so calling an unknown name is left for then.
    @_spi(Shell) public var sawImport = false
    /// Where each line starts, for `line(at:)`.
    @_spi(Shell) public var lineStarts: [Int] = [0]
    /// Inside (), [] and \( ), newlines don't end an expression.
    @_spi(Shell) public var bracketDepth = 0
    @_spi(Shell) public var loopDepth = 0
    @_spi(Shell) public var functionDepth = 0
    /// Inside a switch's cases, where `fallthrough` and `break` make sense.
    @_spi(Shell) public var switchDepth = 0
    /// Inside an `if`/`while` condition, `{` after a command starts the body
    /// rather than a closure argument.
    @_spi(Shell) public var conditionDepth = 0
    /// In a guard's condition, where a command ends at `else`.
    @_spi(Shell) public var guardCondition = false
    /// Inside the operand of `try`, `try?` or `try!`, where `$(…)` throws
    /// when its command fails. Closures and function bodies start afresh:
    /// they decide for themselves whether to throw, as in Swift.
    @_spi(Shell) public var tryDepth = 0
    /// One entry per enclosing function or closure: how many `$n`
    /// parameters a closure without named parameters uses, or nil if its
    /// parameters are named.
    @_spi(Shell) public var anonymousArity: [Int?] = []

    /// Highlight spans, in the order recorded; inner spans (like an
    /// interpolation inside a string) are shorter than what contains them.
    /// Input that doesn't parse yet, as while typing, still gets the spans
    /// found before the problem.
    @_spi(Shell) public private(set) var spans: [Span] = []

    @_spi(Shell) public static func parse(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)? = nil) throws(SyntaxError) -> Program {
        var parser = Parser(source, bound: bound)
        parser.plugin = plugin
        return try parser.parseProgram(until: nil)
    }

    /// The prelude: builtins' types and signatures (see Prelude.swift).
    @_spi(Shell) public static func parsePrelude(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        var parser = Parser(source, bound: bound)
        parser.prelude = true
        return try parser.parseProgram(until: nil)
    }

    @_spi(Shell) public static func highlight(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)? = nil) -> [Span] {
        var parser = Parser(source, bound: bound)
        parser.plugin = plugin
        _ = try? parser.parseProgram(until: nil)
        return parser.spans
    }

    @_spi(Shell) public mutating func mark(_ kind: SpanKind, from start: Int, to end: Int? = nil) {
        let end = min(end ?? pos, chars.count)
        if start < end { spans.append(Span(range: start..<end, kind: kind)) }
    }

    /// Backs up after looking ahead, dropping spans recorded on the way.
    @_spi(Shell) public mutating func rewind(to state: (position: Int, spans: Int)) {
        pos = state.position
        spans.removeSubrange(state.spans...)
    }

    /// Consumes a keyword known to be at the current position.
    @_spi(Shell) public mutating func keyword(_ word: String) {
        mark(.keyword, from: pos, to: pos + word.count)
        pos += word.count
    }

    @_spi(Shell) public init(_ source: String, bound: [String: NameKind]) {
        chars = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        scopes = [bound]
        for (index, c) in chars.enumerated() where c == "\n" { lineStarts.append(index + 1) }
    }

}
