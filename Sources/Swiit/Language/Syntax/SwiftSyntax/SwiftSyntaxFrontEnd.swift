import SwiftOperators
import SwiftParser
import SwiftSyntax

/// A front end on SwiftSyntax: SwiftParser reads the source, and the tree it
/// gives is lowered to the core's. What it doesn't lower yet is an error that
/// names the construct, so the supported subset is the set of nodes lowered.
@_spi(Layer) public struct SwiftSyntaxFrontEnd: SyntaxFrontEnd {
    @_spi(Layer) public init() {}

    @_spi(Layer) public func parse(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?) throws(SyntaxError) -> Program {
        try lower(source, bound: bound, plugin: plugin, prelude: false)
    }

    /// The prelude: the builtins' types and signatures, which have no bodies
    /// of their own (see Prelude.swift).
    @_spi(Layer) public func parsePrelude(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        try lower(source, bound: bound, plugin: nil, prelude: true)
    }

    private func lower(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?, prelude: Bool) throws(SyntaxError) -> Program {
        let parsed = SwiftParser.Parser.parse(source: source)
        var problems: [(message: String, offset: Int)] = []
        var other: Error?
        let folded = OperatorTable.standardOperators.foldAll(parsed) { error in
            switch error as? OperatorError {
            case .missingOperator(_, let node)?, .missingGroup(_, let node)?:
                problems.append(("\(error)", node.positionAfterSkippingLeadingTrivia.utf8Offset))
            case .incomparableOperators(_, _, let node, _)?:
                problems.append(("\(error)", node.positionAfterSkippingLeadingTrivia.utf8Offset))
            default:
                other = other ?? error
            }
        }
        if let other { throw SyntaxError("\(other)") }
        guard let tree = folded.as(SourceFileSyntax.self) else { throw SyntaxError("not a source file") }
        var lowering = Lowering(source: source, tree: tree, bound: bound, plugin: plugin)
        lowering.operatorProblems = problems
        lowering.prelude = prelude
        do {
            return try lowering.program()
        } catch let error as SyntaxError {
            throw error
        } catch {
            throw SyntaxError("\(error)")
        }
    }

    @_spi(Layer) public func highlight(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?) -> [Span] {
        let parsed = SwiftParser.Parser.parse(source: source)
        // Operators that don't fold (`a < b < c`) leave their sequence as it is.
        let folded = OperatorTable.standardOperators.foldAll(parsed) { _ in }
        guard let tree = folded.as(SourceFileSyntax.self) else { return [] }
        var lowering = Lowering(source: source, tree: tree, bound: bound, plugin: plugin)
        lowering.recovering = true
        _ = try? lowering.program()
        return lowering.highlightSpans()
    }
}
