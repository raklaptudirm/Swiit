import Foundation
import SwiitKit

/// What a name refers to, which decides the mode of a statement starting
/// with it: a variable starts an expression, a function starts a command
/// unless it's followed by `(`.
@_spi(Layer) public enum NameKind: Equatable, Sendable {
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

    @_spi(Layer) public init(_ description: String, incomplete: Bool = false) {
        self.description = description
        self.incomplete = incomplete
    }

    @_spi(Layer) public static func incomplete(_ description: String) -> SyntaxError {
        SyntaxError(description, incomplete: true)
    }
}

/// What a stretch of source is, for syntax highlighting. The parser
/// records these as it goes, so the colors always agree with how the line
/// will actually be read.
@_spi(Layer) public enum SpanKind: Equatable, Sendable {
    case keyword, command, flag, string, number, constant, variable, comment, type, punctuation
}

@_spi(Layer) public struct Span: Equatable, Sendable {
    @_spi(Layer) public var range: Range<Int>
    @_spi(Layer) public var kind: SpanKind

    @_spi(Layer) public init(range: Range<Int>, kind: SpanKind) {
        self.range = range
        self.kind = kind
    }
}

// MARK: - SourceCursor

/// Where a syntax layer reads the source: a position in the characters, and
/// what it needs to read by: the scanning of text (`peek`, `identifier`,
/// `skipSpaces`, `consume`), the names in scope and what they are, the depths
/// that say where it is (inside a `try`, a condition, a loop), and the
/// highlight spans it records as it goes.
///
/// It scans characters rather than tokens, because a layer's text isn't
/// Swift's: `-la` is a word in a command and a negation in an expression. Where
/// the layer's syntax holds Swift (a `(…)` or `{ … }` word, `\(…)` in a string,
/// the program in `$(…)`), the cursor reads it with `parseExpression`,
/// `parseClosure`, `parseArguments` and `parseProgram`, which the front end
/// answers (SwiftServices.swift).
///
/// Mode is decided per unit, by what reads there (see the shell's
/// `commandAhead`). Deciding it needs to know which names exist and what they
/// are, so the cursor carries the names declared where it is.
@_spi(Layer) public struct SourceCursor {
    static let keywords: Set = [
        "let", "var", "if", "else", "true", "false", "nil",
        "for", "in", "while", "func", "return", "break", "continue", "try", "do", "catch",
        "async", "await", "enum", "switch", "case", "default", "fallthrough", "import", "struct", "throws",
        "as", "is", "defer", "guard", "throw",
    ]
    @_spi(Layer) public static let statementKeywords: Set = ["let", "var", "func", "return", "break", "continue", "do", "catch", "enum", "fallthrough", "import", "struct", "defer", "guard", "throw"]
    /// The keywords a line can begin with: a statement's, a unit's
    /// (`if make { … }`), or an expression's (`await job`). Completion
    /// offers them where a command could go.
    @_spi(Layer) public static let lineStarts = statementKeywords.subtracting(["catch"])
        .union(["if", "for", "while", "switch", "try", "async", "await"])
    /// The words a command can follow directly and still be in command
    /// position: `if make {`, `while pgrep x {`, `} else make`, `foreign ls`.
    @_spi(Layer) public static let beforeCommand: Set = ["if", "while", "else", "foreign"]

    @_spi(Layer) public let chars: [Character]
    @_spi(Layer) public var pos = 0
    /// Syntax added to Swift's, which the front end asks about where Swift's
    /// grammar has no meaning for what is there (SyntaxPlugin.swift).
    @_spi(Layer) public var plugin: (any SyntaxPlugin)?
    @_spi(Layer) public var scopes: [[String: NameKind]]
    /// The names the layer's own forms mention (`$name`, a command's name),
    /// which a closure or function around them keeps.
    @_spi(Layer) public private(set) var used: Set<String> = []

    /// A name the code being read refers to.
    @_spi(Layer) public mutating func use(_ name: String) {
        used.insert(name)
    }
    /// An `import` came earlier: the functions it brings aren't known until
    /// it runs, so calling an unknown name is left for then.
    @_spi(Layer) public var sawImport = false
    /// Inside (), [] and \( ), newlines don't end an expression.
    @_spi(Layer) public var bracketDepth = 0
    @_spi(Layer) public var loopDepth = 0
    @_spi(Layer) public var functionDepth = 0
    /// Inside a switch's cases, where `fallthrough` and `break` make sense.
    @_spi(Layer) public var switchDepth = 0
    /// Inside an `if`/`while` condition, `{` after a command starts the body
    /// rather than a closure argument.
    @_spi(Layer) public var conditionDepth = 0
    /// In a guard's condition, where a command ends at `else`.
    @_spi(Layer) public var guardCondition = false
    /// Inside the operand of `try`, `try?` or `try!`, where `$(…)` throws
    /// when its command fails. Closures and function bodies start afresh:
    /// they decide for themselves whether to throw, as in Swift.
    @_spi(Layer) public var tryDepth = 0
    /// Inside a closure without named parameters, where `$0` is its first.
    @_spi(Layer) public var inAnonymousClosure = false
    /// What the front end knows of where the cursor is, for reading the Swift
    /// inside the layer's forms (SwiftServices.swift).
    var context = LoweringContext()
    /// Where each line of the characters starts, and how many lines of the
    /// whole source come before: for `line(at:)`.
    var lineStarts: [Int] = [0]
    var lineOffset = 0

    /// Highlight spans, in the order recorded; inner spans (like an
    /// interpolation inside a string) are shorter than what contains them.
    /// Input that doesn't read yet, as while typing, still gets the spans
    /// found before the problem.
    @_spi(Layer) public internal(set) var spans: [Span] = []

    @_spi(Layer) public mutating func mark(_ kind: SpanKind, from start: Int, to end: Int? = nil) {
        let end = min(end ?? pos, chars.count)
        if start < end { spans.append(Span(range: start..<end, kind: kind)) }
    }

    /// Backs up after looking ahead, dropping spans recorded on the way.
    @_spi(Layer) public mutating func rewind(to state: (position: Int, spans: Int)) {
        pos = state.position
        spans.removeSubrange(state.spans...)
    }

    /// Consumes a keyword known to be at the current position.
    @_spi(Layer) public mutating func keyword(_ word: String) {
        mark(.keyword, from: pos, to: pos + word.count)
        pos += word.count
    }

    init(chars: [Character], scopes: [[String: NameKind]]) {
        self.chars = chars
        self.scopes = scopes
    }

    /// An identifier that isn't a keyword; `_` is allowed.
    @_spi(Layer) public mutating func parseName(after context: String) throws(SyntaxError) -> String {
        guard let name = identifier() else { throw expected("a name after \(context)") }
        guard !SourceCursor.keywords.contains(name) else { throw SyntaxError("'\(name)' is a keyword") }
        pos += name.count
        return name
    }

    /// `try` (.some(nil)), `try?` or `try!` at the current position; nil if none.
    @_spi(Layer) public mutating func parseTry() throws(SyntaxError) -> TryKind?? {
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
}
