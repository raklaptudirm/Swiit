import SwiftSyntax
import SwiitKit

extension Lowering {
    // MARK: Expressions

    mutating func expression(_ expr: ExprSyntax) throws -> Expr {
        // `$(…)`, `$name` and `async …` are the layer's, not Swift's.
        if plugin != nil, isLayerExpression(expr),
           let lowered = try layerExpression(at: expr.positionAfterSkippingLeadingTrivia.utf8Offset) {
            return lowered
        }
        if let node = expr.as(IntegerLiteralExprSyntax.self) {
            let text = node.literal.text.replacingOccurrences(of: "_", with: "")
            guard let number = Int(text) ?? parseRadix(text) else { throw unsupported("this integer", node) }
            return .literal(.int(number))
        }
        if let node = expr.as(FloatLiteralExprSyntax.self) {
            guard let number = Double(node.literal.text.replacingOccurrences(of: "_", with: "")) else { throw unsupported("this number", node) }
            return .literal(.double(number))
        }
        if let node = expr.as(BooleanLiteralExprSyntax.self) { return .literal(.bool(node.literal.tokenKind == .keyword(.true))) }
        if expr.is(NilLiteralExprSyntax.self) { return .literal(.nothing) }
        if let node = expr.as(StringLiteralExprSyntax.self) { return try string(node) }
        if let node = expr.as(DeclReferenceExprSyntax.self) {
            try checkKnown(node, calling: false)
            return reference(node)
        }
        if let node = expr.as(MemberAccessExprSyntax.self) { return try member(node) }
        if let node = expr.as(FunctionCallExprSyntax.self) { return try call(node) }
        if let node = expr.as(SubscriptCallExprSyntax.self) { return try subscriptCall(node) }
        if let node = expr.as(ArrayExprSyntax.self) { return .list(try node.elements.map { try expression($0.expression) }) }
        if let node = expr.as(DictionaryExprSyntax.self) { return try dictionary(node) }
        if let node = expr.as(TupleExprSyntax.self) { return try tuple(node) }
        if let node = expr.as(ClosureExprSyntax.self) { return .closure(try closure(node)) }
        if let node = expr.as(PrefixOperatorExprSyntax.self) { return try prefix(node) }
        if let node = expr.as(ForceUnwrapExprSyntax.self) { return .forceUnwrap(try expression(node.expression)) }
        if let node = expr.as(InfixOperatorExprSyntax.self) { return try infix(node) }
        if let node = expr.as(TernaryExprSyntax.self) { return try ternary(node) }
        if let node = expr.as(AsExprSyntax.self) {
            let kind: CastKind = switch node.questionOrExclamationMark?.tokenKind {
            case .postfixQuestionMark?: .conditional
            case .exclamationMark?: .forced
            default: .upcast
            }
            return .cast(try expression(node.expression), try type(node.type), kind)
        }
        if let node = expr.as(IsExprSyntax.self) { return .cast(try expression(node.expression), try type(node.type), .check) }
        if let node = expr.as(TryExprSyntax.self) {
            let kind: TryKind = switch node.questionOrExclamationMark?.tokenKind {
            case .postfixQuestionMark?: .optional
            case .exclamationMark?: .forced
            default: .plain
            }
            tryDepth += 1
            defer { tryDepth -= 1 }
            return .attempt(try expression(node.expression), kind)
        }
        if let node = expr.as(AwaitExprSyntax.self) {
            // A bare `await` waits for the jobs in the background, so the
            // expression SwiftParser finds missing is not a problem.
            if node.expression.is(MissingExprSyntax.self) {
                accepted.insert(node.expression.id)
                return .await(nil, throwing: tryDepth > 0)
            }
            return .await(try expression(node.expression), throwing: tryDepth > 0)
        }
        if let node = expr.as(KeyPathExprSyntax.self) { return try keyPath(node) }
        if let node = expr.as(IfExprSyntax.self) {
            let statement = try ifStatement(node)
            guard statement.otherwise != nil else { throw SyntaxError("an if expression needs an else (line \(line(of: node)))") }
            guard let lowered = statement.asExpression else {
                throw SyntaxError("each branch of an if expression must be one expression (line \(line(of: node)))")
            }
            return .ifExpression(lowered)
        }
        if let node = expr.as(MacroExpansionExprSyntax.self), node.macroName.text == "filePath" { return .filePath }
        // `x?` alone: Swift's optional chaining goes on with a member or a subscript, which are lowered with their base.
        if let node = expr.as(OptionalChainingExprSyntax.self) {
            failedAt = node.questionMark.positionAfterSkippingLeadingTrivia.utf8Offset
            throw SyntaxError("unexpected '?'")
        }
        throw unsupported("'\(expr.kind)'", expr)
    }

    private func parseRadix(_ text: String) -> Int? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("0x") { return Int(lowered.dropFirst(2), radix: 16) }
        if lowered.hasPrefix("0b") { return Int(lowered.dropFirst(2), radix: 2) }
        if lowered.hasPrefix("0o") { return Int(lowered.dropFirst(2), radix: 8) }
        return nil
    }

    // MARK: Names

    /// A name: a local, a member of the struct whose method this is (read
    /// through `self`), or a global.
    func reference(_ node: DeclReferenceExprSyntax) -> Expr {
        let name = node.baseName.text
        if locals.contains(where: { $0.contains(name) }) { return .variable(name) }
        if let context = staticContext, context.names.contains(name) { return .member(.variable(context.owner), name) }
        if members.last?.contains(name) == true { return .member(.variable("self"), name) }
        return .variable(name)
    }

    // MARK: Literals

    private mutating func string(_ node: StringLiteralExprSyntax) throws -> Expr {
        // `'a b'`: a raw string, which SwiftParser reads with its quotes missing.
        if let open = node.unexpectedBetweenOpeningPoundsAndOpeningQuote?.first?.as(TokenSyntax.self), open.tokenKind == .singleQuote {
            guard let close = node.unexpectedBetweenSegmentsAndClosingQuote?.first?.as(TokenSyntax.self), close.tokenKind == .singleQuote else {
                throw SyntaxError.incomplete("unterminated string (line \(line(of: node)))")
            }
            accepted.insert(node.id)
            extentHints.append(close.endPositionBeforeTrailingTrivia.utf8Offset)
            let text = bytes[open.endPositionBeforeTrailingTrivia.utf8Offset..<close.positionAfterSkippingLeadingTrivia.utf8Offset]
            return .literal(.string(String(decoding: text, as: UTF8.self)))
        }
        guard node.openingPounds == nil, node.openingQuote.tokenKind == .stringQuote else {
            throw unsupported("a multi-line or raw string", node)
        }
        var parts: [StringPart] = []
        var text = ""
        func flush() { if !text.isEmpty { parts.append(.literal(text)); text = "" } }
        for segment in node.segments {
            switch segment {
            case .stringSegment(let literal):
                guard let unescaped = unescape(literal.content.text) else { throw unsupported("this escape", literal) }
                text += unescaped
            case .expressionSegment(let interpolation):
                guard interpolation.expressions.count == 1, let inner = interpolation.expressions.first else {
                    throw unsupported("this interpolation", interpolation)
                }
                flush()
                parts.append(.expression(try expression(inner.expression)))
            }
        }
        flush()
        if parts.isEmpty { return .literal(.string("")) }
        if parts.count == 1, case .literal(let only) = parts[0] { return .literal(.string(only)) }
        return .string(parts)
    }

    private func unescape(_ text: String) -> String? {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { result.append(character); continue }
            guard let next = iterator.next() else { return nil }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "'": result.append("'")
            case "u":
                guard iterator.next() == "{" else { return nil }
                var digits = ""
                while let digit = iterator.next(), digit != "}" { digits.append(digit) }
                guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
                result.unicodeScalars.append(scalar)
            default: return nil
            }
        }
        return result
    }

    // MARK: Members, calls, subscripts

    private mutating func member(_ node: MemberAccessExprSyntax) throws -> Expr {
        guard node.declName.argumentNames == nil else { throw unsupported("a member with argument names", node) }
        let name = node.declName.baseName.text
        guard let base = node.base else { return .caseLiteral(name, nil) }
        // `2.mb`: a file size, written as a number and its unit.
        if FileSize.units[name] != nil {
            if let integer = base.as(IntegerLiteralExprSyntax.self), let amount = Double(integer.literal.text.replacingOccurrences(of: "_", with: "")) {
                return try fileSize(amount, name, node)
            }
            if let float = base.as(FloatLiteralExprSyntax.self), let amount = Double(float.literal.text.replacingOccurrences(of: "_", with: "")) {
                return try fileSize(amount, name, node)
            }
        }
        // `1.parsecs`: a number is followed by a unit, and this isn't one.
        if base.is(IntegerLiteralExprSyntax.self) || base.is(FloatLiteralExprSyntax.self) {
            failedAt = node.declName.endPositionBeforeTrailingTrivia.utf8Offset
            throw SyntaxError("unknown unit '\(name)'; file sizes use b, kb, mb, gb, tb, or kib, mib, gib, tib")
        }
        if let chained = base.as(OptionalChainingExprSyntax.self) {
            return .optionalMember(try expression(chained.expression), name)
        }
        return .member(try expression(base), name)
    }

    private func fileSize(_ amount: Double, _ unit: String, _ node: some SyntaxProtocol) throws -> Expr {
        guard let size = FileSize(amount, unit: unit) else { throw SyntaxError("file size \(amount).\(unit) is too large") }
        return .literal(.fileSize(size))
    }

    mutating func arguments(_ list: LabeledExprListSyntax) throws -> [Argument] {
        try list.map { Argument(label: $0.label?.text, value: try expression($0.expression)) }
    }

    private mutating func call(_ node: FunctionCallExprSyntax) throws -> Expr {
        // `.failed(code: 2)`: a case whose enum comes from context.
        let isCase = node.calledExpression.as(MemberAccessExprSyntax.self).map { $0.base == nil } ?? false
        // The callee first, as it is read: a name that isn't bound is found before
        // what is wrong with the arguments.
        var callee: Expr?
        if !isCase {
            if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self), strictNames, !isLayerExpression(ExprSyntax(reference)) {
                try checkKnown(reference, calling: true)
                callee = self.reference(reference)
            } else {
                callee = try expression(node.calledExpression)
            }
        }
        guard node.additionalTrailingClosures.isEmpty else { throw unsupported("more than one trailing closure", node) }
        var arguments = try arguments(node.arguments)
        if let trailing = node.trailingClosure {
            arguments.append(Argument(label: nil, value: .closure(try closure(trailing))))
        }
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self), isCase {
            return .caseLiteral(member.declName.baseName.text, arguments)
        }
        return .call(callee!, arguments)
    }

    /// Where names have to be bound (`strictNames`): a name that isn't is not an
    /// expression, which the layer takes for a command's word. After an `import`,
    /// calling an unknown name is left for when it runs.
    mutating func checkKnown(_ node: DeclReferenceExprSyntax, calling: Bool) throws {
        guard strictNames else { return }
        let name = node.baseName.text
        if name == "self" || name == "_" || names()[name] != nil { return }
        if calling && sawImport { return }
        failedAt = node.endPositionBeforeTrailingTrivia.utf8Offset
        throw SyntaxError(calling ? "no function named '\(name)'" : "no variable named '\(name)'")
    }

    private mutating func subscriptCall(_ node: SubscriptCallExprSyntax) throws -> Expr {
        // The base first, as it is read: a name that isn't bound is found before
        // what is wrong with the subscript.
        let chained = node.calledExpression.as(OptionalChainingExprSyntax.self)
        let base = try expression(chained?.expression ?? node.calledExpression)
        guard node.arguments.count == 1, let argument = node.arguments.first, argument.label == nil else {
            throw unsupported("this subscript", node)
        }
        let index = try expression(argument.expression)
        return chained != nil ? .optionalIndex(base, index) : .index(base, index)
    }

    private mutating func dictionary(_ node: DictionaryExprSyntax) throws -> Expr {
        switch node.content {
        case .colon: return .record([])
        case .elements(let elements):
            return .record(try elements.map { RecordEntry(key: try expression($0.key), value: try expression($0.value)) })
        }
    }

    private mutating func tuple(_ node: TupleExprSyntax) throws -> Expr {
        if node.elements.count == 1, let only = node.elements.first, only.label == nil { return try expression(only.expression) }
        return .tuple(try arguments(node.elements))
    }

    // MARK: Closures and key paths

    mutating func closure(_ node: ClosureExprSyntax) throws -> ClosureLiteral {
        var parameters: [Parameter] = []
        var returnType: TypeAnnotation?
        if let signature = node.signature {
            guard signature.attributes.isEmpty, signature.capture == nil else { throw unsupported("this closure signature", signature) }
            switch signature.parameterClause {
            case .simpleInput(let names)?:
                parameters = names.map { Parameter(name: $0.name.text) }
            case .parameterClause(let clause)?:
                parameters = try clause.parameters.map { parameter in
                    guard parameter.attributes.isEmpty else { throw unsupported("an attribute on a closure's parameter", parameter) }
                    let name = parameter.secondName?.text ?? parameter.firstName.text
                    return Parameter(name: name, type: try parameter.type.map { try type($0) } ?? .any)
                }
            case nil:
                break
            }
            returnType = try signature.returnClause.map { try type($0.type) }
        } else {
            // `{ $0 * 2 }`: as many parameters as the highest `$n` it mentions.
            let arity = anonymousArity(in: node.statements)
            parameters = (0..<arity).map { Parameter(name: "$\($0)") }
        }
        locals.append(Set(parameters.map(\.name)))
        let outer = (tryDepth, leaving)
        tryDepth = 0
        leaving = Leaving(function: leaving.function + 1)
        anonymous.append(node.signature == nil)
        defer { locals.removeLast(); (tryDepth, leaving) = outer; anonymous.removeLast() }
        let body = try block(node.statements, scoped: false)
        return ClosureLiteral(parameters: parameters, returnType: returnType, body: body, names: NamesUsed(names: names(in: node.statements)))
    }

    /// The `$n` a closure's body mentions, outside the closures inside it,
    /// whose `$0` is their own: `{ xs.map { $0 * 2 } }` takes nothing.
    private func anonymousArity(in node: some SyntaxProtocol) -> Int {
        let counter = AnonymousArity()
        counter.walk(node)
        return counter.highest + 1
    }

    private mutating func keyPath(_ node: KeyPathExprSyntax) throws -> Expr {
        var path: [String] = []
        for component in node.components {
            guard case .property(let property) = component.component else { throw unsupported("this key path component", component) }
            path.append(property.declName.baseName.text)
        }
        return .keyPath(root: node.root?.trimmedDescription, path: path)
    }

    // MARK: Operators

    private mutating func prefix(_ node: PrefixOperatorExprSyntax) throws -> Expr {
        let operand = try expression(node.expression)
        switch node.operator.text {
        case "-": return .unary(.negate, operand)
        case "!": return .unary(.not, operand)
        default: throw unsupported("the operator '\(node.operator.text)'", node)
        }
    }

    private func binaryOperator(_ text: String) -> BinaryOperator? {
        BinaryOperator(rawValue: text)
    }

    /// Whether an operator assigns to its left side, from Swift's rule: `op=`
    /// for an `op`, but not the comparisons that also end in `=` (`==`, `!=`,
    /// `<=`, `>=`, `===`, `!==`).
    static func isCompoundAssignment(_ text: String) -> Bool {
        text.count > 1 && text.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!=="].contains(text)
    }

    private mutating func infix(_ node: InfixOperatorExprSyntax) throws -> Expr {
        // Left to right, as it is read: a name that isn't bound is found before an operator that isn't Swish's.
        let left = try expression(node.leftOperand)
        if node.operator.is(AssignmentExprSyntax.self) { throw unsupported("an assignment in an expression", node) }
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self), let kind = binaryOperator(op.operator.text) else {
            throw unsupported("the operator '\(node.operator.trimmedDescription)'", node.operator)
        }
        return .binary(kind, left, try expression(node.rightOperand))
    }

    private mutating func ternary(_ node: TernaryExprSyntax) throws -> Expr {
        let condition = try expression(node.condition)
        let then = IfStatement.branch(try expression(node.thenExpression))
        let otherwise = IfStatement.branch(try expression(node.elseExpression))
        return .ifExpression(IfStatement(condition: .expression(condition), then: then, otherwise: otherwise))
    }

    /// `x = 1`, `p.x += 1`, `xs[0] = v`: the place and what is done to it.
    mutating func assignment(_ node: InfixOperatorExprSyntax) throws -> Assignment? {
        var op: BinaryOperator?
        if node.operator.is(AssignmentExprSyntax.self) {
            op = nil
        } else if let binary = node.operator.as(BinaryOperatorExprSyntax.self), Lowering.isCompoundAssignment(binary.operator.text) {
            guard let kind = binaryOperator(String(binary.operator.text.dropLast())) else {
                throw unsupported("the operator '\(binary.operator.text)'", binary)
            }
            op = kind
        } else {
            return nil
        }
        var path: [Assignment.Step] = []
        var place = node.leftOperand
        while true {
            if let member = place.as(MemberAccessExprSyntax.self), let base = member.base {
                path.insert(.member(member.declName.baseName.text), at: 0)
                place = base
            } else if let subscripted = place.as(SubscriptCallExprSyntax.self), subscripted.arguments.count == 1,
                      let argument = subscripted.arguments.first {
                path.insert(.index(try expression(argument.expression)), at: 0)
                place = subscripted.calledExpression
            } else {
                break
            }
        }
        guard let root = place.as(DeclReferenceExprSyntax.self) else { throw unsupported("this assignment", node.leftOperand) }
        var rootName = root.baseName.text
        // A static member, in a static member: `made += 1` is `Counter.made += 1`.
        if !locals.contains(where: { $0.contains(rootName) }), let context = staticContext, context.names.contains(rootName) {
            path.insert(.member(rootName), at: 0)
            rootName = context.owner
        }
        // A struct's own member, in a method: `n += 1` is `self.n += 1`.
        else if !locals.contains(where: { $0.contains(rootName) }), members.last?.contains(rootName) == true {
            path.insert(.member(rootName), at: 0)
            rootName = "self"
        }
        return Assignment(root: rootName, path: path, op: op, value: try expression(node.rightOperand))
    }
}

/// The highest `$n` in a closure's body, not looking into closures nested in it.
private final class AnonymousArity: SyntaxVisitor {
    var highest = -1
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if name.hasPrefix("$"), let index = Int(name.dropFirst()) { highest = max(highest, index) }
        return .visitChildren
    }
}
