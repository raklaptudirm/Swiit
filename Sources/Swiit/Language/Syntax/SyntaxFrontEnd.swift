import Foundation

/// What turns source into the core's tree. The hand-written parser is one; a
/// front end on SwiftSyntax is another (Docs/Design/frontend.md). Both give the
/// same tree for the same Swift, and the first is the oracle for the second.
@_spi(Shell) public protocol SyntaxFrontEnd: Sendable {
    /// The program the source is, knowing the names already declared, and
    /// reading whatever syntax `plugin` adds (the shell's). A front end that
    /// can't read a plug-in's syntax says so as a `SyntaxError`.
    func parse(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?) throws(SyntaxError) -> Program
}

/// The hand-written parser, the front end the interpreter has unless it is
/// given another.
@_spi(Shell) public struct HandWrittenFrontEnd: SyntaxFrontEnd {
    @_spi(Shell) public init() {}

    @_spi(Shell) public func parse(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?) throws(SyntaxError) -> Program {
        return try Parser.parse(source, bound: bound, plugin: plugin)
    }
}
