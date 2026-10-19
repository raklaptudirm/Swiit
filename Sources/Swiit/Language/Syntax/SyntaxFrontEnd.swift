import Foundation

/// What turns source into the core's tree: SwiftParser's, lowered, unless an
/// embedder gives another (Docs/frontend.md).
@_spi(Layer) public protocol SyntaxFrontEnd: Sendable {
    /// The program the source is, knowing the names already declared, and
    /// as Swift.
    func parse(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program
    /// How to color the source, in characters, which may be half typed: what
    /// it reads before a problem is colored as it reads it.
    func highlight(_ source: String, bound: [String: NameKind]) -> [Span]
}
