import SwiftSyntax

extension Lowering {
    // MARK: Expressions

    mutating func expression(_ expr: ExprSyntax) throws -> Expr {
        let lowered = try expressionNode(expr)
        // Where it was written, for an error in it to point at.
        if recordsSpots { currentSpots.append(Spot(expression: lowered, range: range(of: expr))) }
        return lowered
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length - one branch for each case; a long walk over every case; splitting it is item 17 of Docs/agenda.md
    private mutating func expressionNode(_ expr: ExprSyntax) throws -> Expr {
        // `o?.i.v`: what follows the `?` goes on only if `o` has a value.
        if let (core, depth) = optionalChainCore(expr) {
            if depth >= 2, chainPlaceholders[core.id] == nil { return try chain(expr, core) }
        }
        if let node = expr.as(OptionalChainingExprSyntax.self),
            let placeholder = chainPlaceholders[node.id]
        {
            return .variable(placeholder)
        }
        if let node = expr.as(IntegerLiteralExprSyntax.self) {
            let text = node.literal.text.replacingOccurrences(of: "_", with: "")
            guard let number = Int(text) ?? parseRadix(text) else {
                throw unsupported("this integer", node)
            }
            return .literal(.int(number))
        }
        if let node = expr.as(FloatLiteralExprSyntax.self) {
            guard let number = Double(node.literal.text.replacingOccurrences(of: "_", with: ""))
            else {
                throw unsupported("this number", node)
            }
            return .literal(.double(number))
        }
        if let node = expr.as(BooleanLiteralExprSyntax.self) {
            return .literal(.bool(node.literal.tokenKind == .keyword(.true)))
        }
        if expr.is(NilLiteralExprSyntax.self) { return .literal(.nothing) }
        if let node = expr.as(StringLiteralExprSyntax.self) { return try string(node) }
        if let node = expr.as(DeclReferenceExprSyntax.self) {
            // `+`, `<`: an operator as a function, as in `reduce(0, +)`.
            if case .binaryOperator = node.baseName.tokenKind,
                let op = binaryOperator(node.baseName.text)
            {
                let body = Expr.binary(op, .variable("$0"), .variable("$1"))
                return .closure(
                    ClosureLiteral(
                        parameters: [Parameter(name: "$0"), Parameter(name: "$1")],
                        returnType: nil,
                        body: Program(statements: [.expression(body)], lines: [line(of: node)]),
                        names: NamesUsed(names: ["$0", "$1"])
                    )
                )
            }
            return reference(node)
        }
        if let node = expr.as(MemberAccessExprSyntax.self) { return try member(node) }
        if let node = expr.as(FunctionCallExprSyntax.self) { return try call(node) }
        if let node = expr.as(SubscriptCallExprSyntax.self) { return try subscriptCall(node) }
        if let node = expr.as(ArrayExprSyntax.self) {
            return .list(try node.elements.map { try expression($0.expression) })
        }
        if let node = expr.as(DictionaryExprSyntax.self) { return try dictionary(node) }
        if let node = expr.as(TupleExprSyntax.self) { return try tuple(node) }
        if let node = expr.as(ClosureExprSyntax.self) { return .closure(try closure(node)) }
        if let node = expr.as(PrefixOperatorExprSyntax.self) { return try prefix(node) }
        if let node = expr.as(ForceUnwrapExprSyntax.self) {
            return .forceUnwrap(try expression(node.expression))
        }
        if let node = expr.as(PostfixOperatorExprSyntax.self), node.operator.text != "..." {
            return .call(
                .variable("postfix " + node.operator.text),
                [Argument(value: try expression(node.expression))]
            )
        }
        if let node = expr.as(InfixOperatorExprSyntax.self) { return try infix(node) }
        if let node = expr.as(TernaryExprSyntax.self) { return try ternary(node) }
        if let node = expr.as(AsExprSyntax.self) {
            let kind: CastKind =
                switch node.questionOrExclamationMark?.tokenKind {
                case .postfixQuestionMark?: .conditional
                case .exclamationMark?: .forced
                default: .upcast
                }
            return .cast(try expression(node.expression), try type(node.type), kind)
        }
        if let node = expr.as(IsExprSyntax.self) {
            return .cast(try expression(node.expression), try type(node.type), .check)
        }
        if let node = expr.as(TryExprSyntax.self) {
            let kind: TryKind =
                switch node.questionOrExclamationMark?.tokenKind {
                case .postfixQuestionMark?: .optional
                case .exclamationMark?: .forced
                default: .plain
                }
            tryDepth += 1
            defer { tryDepth -= 1 }
            return .attempt(try expression(node.expression), kind)
        }
        if let node = expr.as(AwaitExprSyntax.self) {
            if node.expression.is(MissingExprSyntax.self) {
                throw SyntaxError("await needs something to wait for (line \(line(of: node)))")
            }
            return .await(try expression(node.expression), throwing: tryDepth > 0)
        }
        if expr.is(SuperExprSyntax.self) { return .variable("super") }
        if let node = expr.as(KeyPathExprSyntax.self) { return try keyPath(node) }
        // `Box<Int>(…)`, `f<Int>(…)`: the types only say what a call would infer.
        if let node = expr.as(GenericSpecializationExprSyntax.self) {
            return try expression(node.expression)
        }
        if let node = expr.as(InOutExprSyntax.self) {
            return .inoutArgument(try expression(node.expression))
        }
        if let node = expr.as(IfExprSyntax.self) {
            let statement = try ifStatement(node)
            guard statement.otherwise != nil else {
                throw SyntaxError("an if expression needs an else (line \(line(of: node)))")
            }
            guard let lowered = statement.asExpression else {
                throw SyntaxError(
                    "each branch of an if expression must be one expression (line \(line(of: node)))"
                )
            }
            return .ifExpression(lowered)
        }
        if let node = expr.as(MacroExpansionExprSyntax.self), node.macroName.text == "filePath" {
            return .filePath
        }
        if let node = expr.as(MacroExpansionExprSyntax.self), node.macroName.text == "function" {
            return .literal(.string(functionNames.last ?? ""))
        }
        if let node = expr.as(MacroExpansionExprSyntax.self), node.macroName.text == "line" {
            return .literal(.int(line(of: node)))
        }
        // `x?` alone: Swift's optional chaining goes on with a member or a subscript, which are
        // lowered with their base.
        if let node = expr.as(OptionalChainingExprSyntax.self) {
            failedAt = node.questionMark.positionAfterSkippingLeadingTrivia.utf8Offset
            throw SyntaxError("unexpected '?'")
        }
        throw unsupported("'\(expr.kind)'", expr)
    }

    /// A name: a local, a member of the struct whose method this is (read
    /// through `self`), or a global.
    func reference(_ node: DeclReferenceExprSyntax) -> Expr {
        let name = node.baseName.plainName
        if locals.contains(where: { $0.contains(name) }) { return .variable(name) }
        if name == "Self", let current = currentType { return .variable(current) }
        if let nested = nestedNames[name] { return .variable(nested) }
        // A type alias, used where the type is (`BChar()`): the type it stands for.
        if let alias = aliases[name] {
            if case .named(let target) = alias { return .variable(target) }
            if let (target, _) = alias.swiftType { return .variable(target) }
        }
        // A computed variable is read by its getter.
        if facts.computedGlobals.contains(name) {
            return .call(.variable(InternalName.getter(name)), [])
        }
        if let context = staticContext, context.names.contains(name) {
            return .member(.variable(context.owner), name)
        }
        if members.last?.contains(name) == true { return .member(.variable("self"), name) }
        // The fixed-width integers are Int here, without its overflow rules.
        if Lowering.fixedWidthIntegers.contains(name), bound[name] == nil,
            !declaredTypes.contains(name)
        {
            return .variable("Int")
        }
        if let target = Lowering.swiftAliases[name], bound[name] == nil,
            !declaredTypes.contains(name)
        {
            return .variable(target)
        }
        return .variable(name)
    }

    // MARK: Literals

    private mutating func dictionary(_ node: DictionaryExprSyntax) throws -> Expr {
        switch node.content {
        case .colon: return .record([])
        case .elements(let elements):
            return .record(
                try elements.map {
                    RecordEntry(key: try expression($0.key), value: try expression($0.value))
                }
            )
        }
    }

    private mutating func tuple(_ node: TupleExprSyntax) throws -> Expr {
        if node.elements.count == 1, let only = node.elements.first, only.label == nil {
            return try expression(only.expression)
        }
        return .tuple(try arguments(node.elements))
    }

    // MARK: Closures and key paths

    private mutating func ternary(_ node: TernaryExprSyntax) throws -> Expr {
        let condition = try expression(node.condition)
        let then = IfStatement.branch(try expression(node.thenExpression))
        let otherwise = IfStatement.branch(try expression(node.elseExpression))
        return .ifExpression(
            IfStatement(condition: .expression(condition), then: then, otherwise: otherwise)
        )
    }
}

/// The highest `$n` in a closure's body, not looking into closures nested in it.
final class AnonymousArity: SyntaxVisitor {
    var highest = -1
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if name.hasPrefix("$"), let index = Int(name.dropFirst()) { highest = max(highest, index) }
        return .visitChildren
    }
}
