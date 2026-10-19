import Foundation
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// A front end on SwiftSyntax: SwiftParser reads the source, and the tree it
/// gives is lowered to the core's. What it doesn't lower yet is an error that
/// names the construct, so the supported subset is the set of nodes lowered.
@_spi(Layer) public struct SwiftSyntaxFrontEnd: SyntaxFrontEnd {
    init() {}

    @_spi(Layer) public func parse(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        try lower(source, bound: bound, prelude: false)
    }

    /// The prelude: the builtins' types and signatures, which have no bodies
    /// of their own (see Prelude.swift).
    func parsePrelude(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        try lower(source, bound: bound, prelude: true)
    }

    private func lower(_ source: String, bound: [String: NameKind], prelude: Bool) throws(SyntaxError) -> Program {
        var lowering = try lowering(of: source, bound: bound)
        lowering.prelude = prelude
        do {
            return try lowering.program()
        } catch var error as SyntaxError {
            // Where the lowering stopped, if nothing says better.
            if error.range == nil, let at = lowering.failedAt {
                error.range = lowering.range(fromByte: at, toByte: min(at + 1, lowering.bytes.count))
            }
            throw error
        } catch {
            throw SyntaxError("\(error)")
        }
    }

    /// A lowering of the source, SwiftParser's tree folded: what it lowers by
    /// is its names and its layer. What operators don't fold is kept in it, as
    /// a problem only outside what the layer reads.
    func lowering(of source: String, bound: [String: NameKind]) throws(SyntaxError) -> Lowering {
        let parsed = SwiftSyntaxFrontEnd.parse(source)
        var problems: [(message: String, offset: Int)] = []
        var other: Error?
        let folded = SwiftSyntaxFrontEnd.operators(declaredIn: parsed, bound: bound).foldAll(parsed) { error in
            switch error as? OperatorError {
            case .missingOperator(_, let node)?, .missingGroup(_, let node)?:
                problems.append(("\(error)", node.positionAfterSkippingLeadingTrivia.utf8Offset))
            case .incomparableOperators(_, _, let node, _)?:
                // `1...2...3`, `a < b < c`: the second operator can't follow the first.
                problems.append(("'\(node.trimmedDescription)' can't be chained; use parentheses or '&&'", node.positionAfterSkippingLeadingTrivia.utf8Offset))
            default:
                other = other ?? error
            }
        }
        if let other { throw SyntaxError("\(other)") }
        guard let tree = folded.as(SourceFileSyntax.self) else { throw SyntaxError("not a source file") }
        var lowering = Lowering(source: source, tree: tree, bound: bound)
        lowering.operatorProblems = problems
        return lowering
    }

    @_spi(Layer) public func highlight(_ source: String, bound: [String: NameKind]) -> [Span] {
        let parsed = SwiftSyntaxFrontEnd.parse(source)
        // Operators that don't fold (`a < b < c`) leave their sequence as it is.
        let folded = SwiftSyntaxFrontEnd.operators(declaredIn: parsed, bound: bound).foldAll(parsed) { _ in }
        guard let tree = folded.as(SourceFileSyntax.self) else { return [] }
        var lowering = Lowering(source: source, tree: tree, bound: bound)
        lowering.recovering = true
        _ = try? lowering.program()
        return lowering.highlightSpans()
    }

    static func parse(_ source: String) -> SourceFileSyntax {
        SwiftParser.Parser.parse(source: source)
    }

    /// Swift's operators, with those declared before and those in this program.
    static func operators(declaredIn parsed: SourceFileSyntax, bound: [String: NameKind]) -> OperatorTable {
        var table = OperatorTable.standardOperators
        // The groups first, which the operators name.
        let earlier = bound.compactMap { key, kind -> (String, String)? in
            if case .operatorDeclaration(let source) = kind { (key, source) } else { nil }
        }.sorted { ($0.0.hasPrefix("precedencegroup") ? 0 : 1, $0.0) < ($1.0.hasPrefix("precedencegroup") ? 0 : 1, $1.0) }
        if !earlier.isEmpty {
            table.addSourceFile(SwiftParser.Parser.parse(source: earlier.map(\.1).joined(separator: "\n"))) { _ in }
        }
        table.addSourceFile(parsed) { _ in }
        return table
    }
}
