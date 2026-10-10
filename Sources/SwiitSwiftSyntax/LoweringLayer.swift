@_spi(Shell) import Swiit
import SwiftSyntax
import SwishKit

/// What a layer over the core adds to Swift's grammar (the shell's), read by
/// its plug-in from the source: SwiftParser's tree for those places is what it
/// makes of text that isn't Swift, so it is read by the plug-in instead, and the
/// tree there is not looked at. The plug-in works on a parser positioned in
/// the source, as it does under the hand-written front end.
extension Lowering {
    /// Words that start a Swift statement, which are never a command.
    private static let keywords: Set<String> = Parser.statementKeywords.union(["if", "for", "while", "switch", "let", "var"])

    /// A statement of the plug-in's starting at the byte offset: `import`, or a
    /// chain that begins with a command, and where its source ends.
    mutating func layerStatement(at start: Int) throws -> (statement: Statement, end: Int)? {
        guard let plugin else { return nil }
        var parser = cursor(at: start)
        // `$0`, `$name` and `$(…)` are expressions, found where Swift reads one.
        if parser.peek() == "$" { return nil }
        let word = parser.identifier()
        if let word, word != "try", Lowering.keywords.contains(word), word != "import" { return nil }
        if let statement = try plugin.statement(&parser) {
            consume(from: start, to: parser)
            return (statement, byteOffset(of: parser))
        }
        // `name = …`, `name.a[i] += …` assign to what is a variable, and are Swift's.
        if let word, [.variable, .member, .type].contains(parser.kind(of: word)) || isStaticMember(parser.kind(of: word)) {
            var assigning = parser
            if try assigning.parseAssignment(word) != nil { return nil }
        }
        // Only a chain that starts with a command is the plug-in's: one that
        // starts with Swift is Swift's, whatever it ends in.
        var probe = cursor(at: start)
        guard try plugin.unit(&probe) != nil else {
            // …unless a command comes after a `&&` or `||` (`ok && echo yes`).
            guard let (chain, end) = mixedChain(at: start, isGuard: false) else { return nil }
            return (.chain(chain), end)
        }
        parser = cursor(at: start)
        let chain = try parser.parseChain()
        consume(from: start, to: parser)
        return (.chain(chain), byteOffset(of: parser))
    }

    /// A chain that starts with Swift and has a command after a `&&` or `||`.
    private mutating func mixedChain(at start: Int, isGuard: Bool) -> (Chain, Int)? {
        var parser = cursor(at: start)
        parser.guardCondition = isGuard
        guard let chain = try? parser.parseChain(), !chain.links.isEmpty else { return nil }
        guard chain.links.contains(where: { if case .extended = $0.unit { true } else { false } }) else { return nil }
        consume(from: start, to: parser)
        return (chain, byteOffset(of: parser))
    }

    private func isStaticMember(_ kind: NameKind?) -> Bool {
        if case .staticMember? = kind { return true }
        return false
    }

    /// A condition that is a command (`if grep -q x f { … }`), if it is one.
    mutating func layerCondition(at start: Int, isGuard: Bool = false) throws -> (chain: Chain, end: Int)? {
        guard let plugin else { return nil }
        var probe = cursor(at: start)
        if probe.peek() == "$" { return nil }
        if let word = probe.identifier(), Lowering.keywords.contains(word), word != "try" { return nil }
        guard try plugin.unit(&probe) != nil else {
            guard let (chain, end) = mixedChain(at: start, isGuard: isGuard) else { return nil }
            return (chain, end)
        }
        var parser = cursor(at: start)
        parser.guardCondition = isGuard
        let chain = try parser.parseCondition()
        parser.guardCondition = false
        consume(from: start, to: parser)
        return (chain, byteOffset(of: parser))
    }

    /// Whether the node is one of the layer's expressions (`$name`, `$(…)`,
    /// `async`): the node itself, not something that merely begins with it.
    func isLayerExpression(_ expr: ExprSyntax) -> Bool {
        func isDollarName(_ text: String) -> Bool { text.hasPrefix("$") && Int(text.dropFirst()) == nil }
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text == "async" || isDollarName(reference.baseName.text)
        }
        if let call = expr.as(FunctionCallExprSyntax.self), let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return callee.baseName.text == "$"
        }
        return false
    }

    /// An expression of the plug-in's (`$(…)`, `$name`, `async …`) starting at the byte offset.
    mutating func layerExpression(at start: Int) throws -> Expr? {
        guard let plugin else { return nil }
        var parser = cursor(at: start)
        guard let expr = try plugin.expression(&parser) else { return nil }
        consume(from: start, to: parser)
        return expr
    }

    /// `xs | sorted`: the commands the plug-in reads after a `|` that follows a
    /// value, with the value lowered here; the unit and where it ends.
    mutating func layerPipeline(input: Expr, start: Int, pipe: Int) throws -> (unit: Unit, end: Int)? {
        guard let plugin else { return nil }
        var parser = cursor(at: pipe)
        guard let unit = try plugin.unit(continuing: input, from: characterOf[start], &parser) else { return nil }
        consume(from: start, to: parser)
        return (unit, byteOffset(of: parser))
    }

    /// `xs | sorted | uniqued` as a statement: the value before the first `|`
    /// is Swift's, and the commands after it the layer's.
    mutating func valuePipeline(_ node: InfixOperatorExprSyntax) throws -> Unit? {
        guard plugin != nil else { return nil }
        func isPipe(_ node: InfixOperatorExprSyntax) -> Bool {
            node.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "|"
        }
        guard isPipe(node) else { return nil }
        // Pipes group to the left: the first one is at the bottom of the left spine.
        var first = node
        while let inner = first.leftOperand.as(InfixOperatorExprSyntax.self), isPipe(inner) { first = inner }
        let input = try expression(first.leftOperand)
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let pipe = first.operator.positionAfterSkippingLeadingTrivia.utf8Offset
        return try layerPipeline(input: input, start: start, pipe: pipe)?.unit
    }
}
