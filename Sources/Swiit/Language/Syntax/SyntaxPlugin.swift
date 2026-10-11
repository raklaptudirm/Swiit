import SwiitKit

/// Syntax a layer over the core adds to the grammar: the shell's commands,
/// pipelines, `$(…)` and the like. The front end asks it at the few places where
/// Swift's grammar has no meaning for what is there, and gets back a node of
/// the layer's, which the tree holds opaquely (SyntaxExtension.swift). With no
/// plug-in, the grammar is Swift's alone and those places are errors.
///
/// A plug-in reads the text from a `SourceCursor`, which scans it, and asks the
/// cursor for the Swift inside its own forms (a closure word, `\(expr)`, the
/// program in `$(…)`) with `parseExpression`, `parseClosure`, `parseArguments`
/// and `parseProgram`. See Docs/Design/frontend.md, "Retired", for how those
/// are answered.
@_spi(Layer) public protocol SyntaxPlugin: Sendable {
    /// Where an expression statement or a condition starts: the plug-in's own
    /// (the shell's commands, joined by `|`, `&&` and `||`, with Swift
    /// between them as in `x > 1 && echo big`), or nil to read Swift. A
    /// condition's is a Bool.
    func chain(_ cursor: inout SourceCursor, condition: Bool) throws(SyntaxError) -> Expr?

    /// After a Swift expression statement, with the parser at what follows
    /// it (`|`): what the plug-in continues it into (`xs | sorted`), which
    /// started at `start`, or nil if nothing continues it.
    func continuing(_ expression: Expr, from start: Int, _ parser: inout SourceCursor) throws(SyntaxError) -> Expr?

    /// Where an expression starts that Swift's grammar doesn't have (`$(…)`,
    /// `$name`, `async …`): the plug-in's expression, or nil if it has none
    /// there.
    func expression(_ cursor: inout SourceCursor) throws(SyntaxError) -> Expr?

    /// Where a statement starts (`env.NAME = value`, `import Name from path`):
    /// the plug-in's statement, or nil if it has none there.
    func statement(_ cursor: inout SourceCursor) throws(SyntaxError) -> Statement?
}
