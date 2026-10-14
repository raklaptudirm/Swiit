import Foundation

/// Where something is in the source a program was read from: lines and columns from 1,
/// the columns in characters, the end just after the last character.
public struct SourceRange: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var startLine: Int
    public var startColumn: Int
    public var endLine: Int
    public var endColumn: Int

    public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
    }

    /// The whole of one line, when nothing narrower is known.
    public init(line: Int) {
        self.init(startLine: line, startColumn: 1, endLine: line, endColumn: 1)
    }

    public var description: String { "\(startLine):\(startColumn)" }
}

/// An expression of a statement and where it was written: what an error in it points at.
@_spi(Layer) public struct Spot: Equatable, Sendable {
    @_spi(Layer) public var expression: Expr
    @_spi(Layer) public var range: SourceRange
}
