import Foundation
import SwiftSyntax
import SwiitKit

/// What a layer over the core adds to Swift's grammar (the shell's), read by
/// its plug-in from the source: SwiftParser's tree for those places is what it
/// makes of text that isn't Swift, so it is read by the plug-in instead, and the
/// tree there is not looked at. The plug-in works on a parser positioned in
/// the source.
extension Lowering {
    /// Words that start a Swift statement, which are never a command.
    private static let keywords: Set<String> = SourceCursor.statementKeywords.union(["if", "for", "while", "switch", "let", "var"])

    /// A statement of the plug-in's starting at the byte offset: `import`, or
    /// commands joined by `|`, `&&` and `||`, and where its source ends.
    /// `item` is SwiftParser's reading of it, when it starts one.
    mutating func layerStatement(at start: Int, item: CodeBlockItemSyntax.Item? = nil) throws -> (statement: Statement, end: Int)? {
        guard let plugin else { return nil }
        var parser = cursor(at: start)
        // `$0` is a closure's parameter, found where Swift reads one.
        if parser.peek() == "$", let next = parser.peek(1), SourceCursor.isDigit(next) { return nil }
        let word = parser.identifier()
        if let word, word != "try", Lowering.keywords.contains(word), word != "import" { return nil }
        // `_ = f()` is Swift's, and so is `async let x = f()`.
        if word == "_", let item, isAssignment(item) { return nil }
        if word == "async", case .decl(let decl)? = item, decl.is(VariableDeclSyntax.self) { return nil }
        if let statement = try read(&parser, from: start, plugin.statement) {
            consume(from: start, to: parser)
            if parser.sawImport { sawImport = true }
            return (statement, byteOffset(of: parser))
        }
        // `name = …`, `name.a[i] += …` assign to what is a variable, and are Swift's.
        // (`X=1 cmd` sets the environment, as `X` is no variable.)
        if let word, [.variable, .member, .type].contains(parser.kind(of: word)) || isStaticMember(parser.kind(of: word)) {
            if let item {
                if isAssignment(item) { return nil }
            } else {
                if parser.looksLikeAssignment(after: word) { return nil }
            }
        }
        // Commands, with Swift between them or not: the plug-in decides.
        guard let chain = try read(&parser, from: start, { try plugin.chain(&$0, condition: false) }) else { return nil }
        consume(from: start, to: parser)
        return (.expression(chain), byteOffset(of: parser))
    }

    /// Runs the plug-in on the parser. While highlighting, what it read before
    /// a problem (as in a line half typed) is still the layer's.
    private mutating func read<T>(_ parser: inout SourceCursor, from start: Int, _ body: (inout SourceCursor) throws -> T) throws -> T {
        do {
            return try body(&parser)
        } catch {
            if recovering { consume(from: start, to: parser) }
            // What the layer says is wrong with what it read is the error, ahead of
            // what SwiftParser makes of text that isn't Swift.
            layerError = layerError ?? error as? SyntaxError
            // Where it stopped, which a reading from inside it (`async $(a; b)`) tells apart
            // from one that didn't get started.
            failedAt = failedAt ?? byteOffset(of: parser)
            throw error
        }
    }

    /// Whether SwiftParser read the item as an assignment, `=` or `+=` and the like.
    private func isAssignment(_ item: CodeBlockItemSyntax.Item) -> Bool {
        guard case .expr(let expr) = item, let infix = expr.as(InfixOperatorExprSyntax.self) else { return false }
        if infix.operator.is(AssignmentExprSyntax.self) { return true }
        guard let op = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text else { return false }
        return Lowering.isCompoundAssignment(op)
    }

    private func isStaticMember(_ kind: NameKind?) -> Bool {
        if case .staticMember? = kind { return true }
        return false
    }

    /// A condition that is a command (`if grep -q x f { … }`), if it is one.
    mutating func layerCondition(at start: Int, isGuard: Bool = false) throws -> (condition: Expr, end: Int)? {
        guard let plugin else { return nil }
        var parser = cursor(at: start)
        // A condition's body ends it: `if n > 2 { … }` is Swift up to the brace.
        parser.conditionDepth = 1
        parser.guardCondition = isGuard
        if parser.peek() == "$", let next = parser.peek(1), SourceCursor.isDigit(next) { return nil }
        if let word = parser.identifier(), Lowering.keywords.contains(word) { return nil }
        guard let condition = try read(&parser, from: start, { try plugin.chain(&$0, condition: true) }) else { return nil }
        consume(from: start, to: parser)
        return (condition, byteOffset(of: parser))
    }

    /// Whether the node is one of the layer's expressions (`$name`, `$(…)`,
    /// `async`): the node itself, not something that merely begins with it.
    func isLayerExpression(_ expr: ExprSyntax) -> Bool {
        func isDollarName(_ text: String) -> Bool { text.hasPrefix("$") && Int(text.dropFirst()) == nil }
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text == "async" || isDollarName(reference.baseName.text)
        }
        // `$(…)`, and `async { … }`, which SwiftParser reads as a call with a trailing closure.
        if let call = expr.as(FunctionCallExprSyntax.self), let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return callee.baseName.text == "$" || callee.baseName.text == "async"
        }
        return false
    }

    /// An expression of the plug-in's (`$(…)`, `$name`, `async …`) starting at the byte offset.
    mutating func layerExpression(at start: Int) throws -> Expr? {
        guard let plugin else { return nil }
        var parser = cursor(at: start)
        guard let expr = try read(&parser, from: start, plugin.expression) else { return nil }
        consume(from: start, to: parser)
        return expr
    }

    /// `xs | sorted`: the commands the plug-in reads after a `|` that follows a
    /// value, with the value lowered here; the unit and where it ends.
    mutating func layerPipeline(input: Expr, start: Int, pipe: Int) throws -> (expression: Expr, end: Int)? {
        guard let plugin else { return nil }
        var parser = cursor(at: pipe)
        let from = characterOf[start]
        guard let pipeline = try read(&parser, from: pipe, { try plugin.continuing(input, from: from, &$0) }) else { return nil }
        // The value before the `|` is Swift's, and lowered (and colored) as Swift.
        consume(from: pipe, to: parser)
        return (pipeline, byteOffset(of: parser))
    }

    /// `xs | sorted | uniqued` as a statement: the value before the first `|`
    /// is Swift's, and the commands after it the layer's.
    mutating func valuePipeline(_ node: InfixOperatorExprSyntax) throws -> Expr? {
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
        return try layerPipeline(input: input, start: start, pipe: pipe)?.expression
    }
}

extension SourceCursor {
    /// Whether the text after `name` assigns to it: `n = 1`, `n += 1`, `p.x = 1`,
    /// `xs[i] = 1`, which are Swift's, where `X=1 cmd` sets a variable for a command.
    func looksLikeAssignment(after name: String) -> Bool {
        var cursor = self
        cursor.pos += name.count
        while true {
            if cursor.peek() == ".", let next = cursor.peek(1), SourceCursor.isIdentifierStart(next) {
                cursor.pos += 1
                cursor.pos += cursor.identifier()?.count ?? 0
            } else if cursor.peek() == "[" {
                var depth = 0
                while let c = cursor.peek() {
                    cursor.pos += 1
                    if c == "[" { depth += 1 } else if c == "]" { depth -= 1; if depth == 0 { break } }
                }
            } else {
                break
            }
        }
        cursor.skipSpaces()
        if ["+=", "-=", "*=", "/=", "%=", "??="].contains(where: cursor.startsWith) { return true }
        return cursor.peek() == "=" && cursor.peek(1) != "="
    }
}
