import Foundation
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// A front end on SwiftSyntax: SwiftParser reads the source, and the tree it
/// gives is lowered to the core's. What it doesn't lower yet is an error that
/// names the construct, so the supported subset is the set of nodes lowered.
@_spi(Layer) public struct SwiftSyntaxFrontEnd: SyntaxFrontEnd {
    init() {}

    @_spi(Layer) public func parse(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?) throws(SyntaxError) -> Program {
        try lower(source, bound: bound, plugin: plugin, prelude: false)
    }

    /// The prelude: the builtins' types and signatures, which have no bodies
    /// of their own (see Prelude.swift).
    func parsePrelude(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        try lower(source, bound: bound, plugin: nil, prelude: true)
    }

    private func lower(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?, prelude: Bool) throws(SyntaxError) -> Program {
        var lowering = try lowering(of: source, bound: bound, plugin: plugin)
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
    func lowering(of source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?) throws(SyntaxError) -> Lowering {
        let (parsed, blanked) = SwiftSyntaxFrontEnd.parse(source)
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
        var lowering = Lowering(source: source, tree: tree, bound: bound, plugin: plugin)
        lowering.operatorProblems = problems
        lowering.blanked = blanked
        return lowering
    }

    @_spi(Layer) public func highlight(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?) -> [Span] {
        let (parsed, blanked) = SwiftSyntaxFrontEnd.parse(source)
        // Operators that don't fold (`a < b < c`) leave their sequence as it is.
        let folded = SwiftSyntaxFrontEnd.operators(declaredIn: parsed, bound: bound).foldAll(parsed) { _ in }
        guard let tree = folded.as(SourceFileSyntax.self) else { return [] }
        var lowering = Lowering(source: source, tree: tree, bound: bound, plugin: plugin)
        lowering.blanked = blanked
        lowering.recovering = true
        _ = try? lowering.program()
        return lowering.highlightSpans()
    }

    /// SwiftParser's tree of the source, with what is inside each `$(…)` blanked out first. What is in one is the layer's
    /// text, which SwiftParser takes for Swift and recovers from in its own way: a closure in it (`$(ls | map { … })`) makes
    /// it end the call early, and the rest of the line is left out of every statement or turns up as errors. The layer reads
    /// the original source, by byte offset, so only the tree's view of that text changes, not its length.
    static func parse(_ source: String) -> (tree: SourceFileSyntax, blanked: [Range<Int>]) {
        let parsed = SwiftParser.Parser.parse(source: source)
        guard source.contains("$("), let (text, ranges) = blankingSubstitutions(of: source, in: parsed) else { return (parsed, []) }
        return (SwiftParser.Parser.parse(source: text), ranges)
    }

    /// The source with the text inside each `$(…)` replaced by spaces (newlines stay), and where, or nil if there is none to blank.
    private static func blankingSubstitutions(of source: String, in tree: SourceFileSyntax) -> (String, [Range<Int>])? {
        let tokens = tree.tokens(viewMode: .sourceAccurate).filter { $0.presence == .present }
        var bytes = Array(source.utf8)
        var ranges: [Range<Int>] = []
        var index = 0
        while index + 1 < tokens.count {
            let token = tokens[index]
            guard token.text == "$", tokens[index + 1].tokenKind == .leftParen,
                  tokens[index + 1].positionAfterSkippingLeadingTrivia == token.endPositionBeforeTrailingTrivia else { index += 1; continue }
            // To the parenthesis that closes it, by the tokens' own nesting (strings are one token each).
            var depth = 0
            var close: Int?
            for next in (index + 1)..<tokens.count {
                switch tokens[next].tokenKind {
                case .leftParen: depth += 1
                case .rightParen:
                    depth -= 1
                    if depth == 0 { close = next }
                default: break
                }
                if close != nil { break }
            }
            guard let close else { index += 1; continue }
            let from = tokens[index + 1].endPositionBeforeTrailingTrivia.utf8Offset
            let to = tokens[close].positionAfterSkippingLeadingTrivia.utf8Offset
            for offset in from..<to where bytes[offset] != 0x0A { bytes[offset] = 0x20 }
            if to > from { ranges.append(from..<to) }
            index = close + 1
        }
        return ranges.isEmpty ? nil : (String(decoding: bytes, as: UTF8.self), ranges)
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
