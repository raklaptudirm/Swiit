import Foundation

/// What a name refers to, which decides the mode of a statement starting
/// with it: a variable starts an expression, a function starts a command
/// unless it's followed by `(`.
enum NameKind: Equatable, Sendable {
    /// `type`: an enum's or struct's name, as in `FileType.directory`.
    /// `member`: a property or method of the struct whose body this is,
    /// read through `self`. `staticMember`: a static one, read in a static
    /// member's body through the type's name.
    case variable, function, type, member
    case staticMember(of: String)
    /// An `operator` or `precedencegroup` declared earlier: its source, for the operators to fold by.
    case operatorDeclaration(String)
}

struct SyntaxError: Error, Equatable, CustomStringConvertible {
    public let description: String
    /// The input ended in the middle of a construct, so more lines could complete it.
    public let incomplete: Bool
    /// Where in the source it is, when that is known.
    public var range: SourceRange?

    init(_ description: String, incomplete: Bool = false, range: SourceRange? = nil) {
        self.description = description
        self.incomplete = incomplete
        self.range = range
    }

    /// Equal by what they say: where they are doesn't matter.
    public static func == (lhs: SyntaxError, rhs: SyntaxError) -> Bool {
        lhs.description == rhs.description && lhs.incomplete == rhs.incomplete
    }

    static func incomplete(_ description: String) -> SyntaxError {
        SyntaxError(description, incomplete: true)
    }
}

/// What a stretch of source is, for syntax highlighting. The parser
/// records these as it goes, so the colors always agree with how the line
/// will actually be read.
enum SpanKind: Equatable, Sendable {
    case keyword, command, flag, string, number, constant, variable, comment, type, punctuation
}

struct Span: Equatable, Sendable {
    var range: Range<Int>
    var kind: SpanKind

    init(range: Range<Int>, kind: SpanKind) {
        self.range = range
        self.kind = kind
    }
}

