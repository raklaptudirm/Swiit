import SwishKit

/// Syntax a layer over the core adds to the grammar: the shell's commands,
/// pipelines, `$(…)` and the like. The parser asks it at the few places where
/// Swift's grammar has no meaning for what is there, and gets back a node of
/// the layer's, which the tree holds opaquely (SyntaxExtension.swift). With no
/// plug-in, the grammar is Swift's alone and those places are errors.
///
/// A plug-in works on the parser it's given: it reads the text and parses the
/// Swift inside its own forms (a closure word, `\(expr)`, the program in
/// `$(…)`) by calling the parser's own functions. See Docs/Design/frontend.md
/// for why this is the shape it is, and what changes when another front end
/// is added.
@_spi(Shell) public protocol SyntaxPlugin: Sendable {
    /// At the start of a unit (a statement, or an operand of `&&` and `||`):
    /// a unit of the plug-in's, or nil to parse Swift.
    func unit(_ parser: inout Parser) throws(SyntaxError) -> Unit?

    /// After a Swift expression that began a unit, with the parser at what
    /// follows it (`|`): the unit the plug-in continues it into, which started
    /// at `start`, or nil if nothing continues it.
    func unit(continuing expression: Expr, from start: Int, _ parser: inout Parser) throws(SyntaxError) -> Unit?

    /// Where an expression starts that Swift's grammar doesn't have (`$(…)`,
    /// `$name`, `async …`): the plug-in's expression, or nil if it has none
    /// there.
    func expression(_ parser: inout Parser) throws(SyntaxError) -> Expr?

    /// Where a statement starts (`env.NAME = value`, `import Name from path`):
    /// the plug-in's statement, or nil if it has none there.
    func statement(_ parser: inout Parser) throws(SyntaxError) -> Statement?
}
