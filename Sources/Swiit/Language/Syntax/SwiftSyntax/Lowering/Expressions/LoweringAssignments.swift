import SwiftSyntax

// Lowering assignment: plain, compound, into tuples and into places.

extension Lowering {
    /// Whether an operator assigns to its left side, from Swift's rule: `op=`
    /// for an `op`, but not the comparisons that also end in `=` (`==`, `!=`,
    /// `<=`, `>=`, `===`, `!==`).
    static func isCompoundAssignment(_ text: String) -> Bool {
        text.count > 1 && text.hasSuffix("=")
            && !["==", "!=", "<=", ">=", "===", "!=="].contains(text)
    }

    /// `x = 1`, `p.x += 1`, `xs[0] = v`: the place and what is done to it.
    mutating func assignment(_ node: InfixOperatorExprSyntax) throws -> Assignment? {
        var op: BinaryOperator?
        if node.operator.is(AssignmentExprSyntax.self) {
            op = nil
        } else if let binary = node.operator.as(BinaryOperatorExprSyntax.self),
            Lowering.isCompoundAssignment(binary.operator.text)
        {
            guard let kind = binaryOperator(String(binary.operator.text.dropLast())) else {
                throw unsupported("the operator '\(binary.operator.text)'", binary)
            }
            op = kind
        } else {
            return nil
        }
        return try placeAssignment(node.leftOperand, op: op, value: node.rightOperand, node: node)
    }

    /// `total = 5`, `total += 1` where `total` is a computed variable: its setter.
    mutating func computedAssignment(_ node: InfixOperatorExprSyntax) throws -> [Statement]? {
        guard let target = node.leftOperand.as(DeclReferenceExprSyntax.self),
            facts.computedGlobals.contains(target.baseName.plainName),
            !locals.contains(where: { $0.contains(target.baseName.plainName) })
        else { return nil }
        let name = target.baseName.plainName
        var op: BinaryOperator?
        if node.operator.is(AssignmentExprSyntax.self) {
            op = nil
        } else if let binary = node.operator.as(BinaryOperatorExprSyntax.self),
            Lowering.isCompoundAssignment(binary.operator.text)
        {
            op = binaryOperator(String(binary.operator.text.dropLast()))
            guard op != nil else { return nil }
        } else {
            return nil
        }
        var value = try expression(node.rightOperand)
        if let op { value = .binary(op, .call(.variable(InternalName.getter(name)), []), value) }
        return [.expression(.call(.variable(InternalName.setter(name)), [Argument(value: value)]))]
    }

    /// `x <+>= y` where the program declares `func <+>= (lhs: inout T, rhs: T)`: a call, with `x`
    /// passed as `&x`.
    mutating func customCompound(_ node: InfixOperatorExprSyntax) throws -> [Statement]? {
        guard let binary = node.operator.as(BinaryOperatorExprSyntax.self),
            Lowering.isCompoundAssignment(binary.operator.text),
            binaryOperator(String(binary.operator.text.dropLast())) == nil,
            names()[binary.operator.text] != nil
        else { return nil }
        let place = try expression(node.leftOperand)
        return [
            .expression(
                .call(
                    .variable(binary.operator.text),
                    [
                        Argument(value: .inoutArgument(place)),
                        Argument(value: try expression(node.rightOperand)),
                    ]
                )
            )
        ]
    }

    /// `(a, b) = (b, a + b)`: the right side held once, and each place given its element.
    mutating func tupleAssignment(_ node: InfixOperatorExprSyntax) throws -> [Statement]? {
        guard node.operator.is(AssignmentExprSyntax.self),
            let tuple = node.leftOperand.as(TupleExprSyntax.self),
            tuple.elements.count > 1
        else { return nil }
        destructurings += 1
        let held = InternalName.tuple(destructurings)
        var statements: [Statement] = [
            .declare(name: held, mutable: false, value: try expression(node.rightOperand))
        ]
        for (index, element) in tuple.elements.enumerated() {
            if element.expression.is(DiscardAssignmentExprSyntax.self) { continue }
            statements.append(
                .assign(
                    try placeAssignment(
                        element.expression,
                        op: nil,
                        value: nil,
                        held: .member(.variable(held), "\(index)"),
                        node: element
                    )
                )
            )
        }
        return statements
    }

    private mutating func placeAssignment(
        _ leftOperand: ExprSyntax,
        op: BinaryOperator?,
        value rightOperand: ExprSyntax?,
        held: Expr? = nil,
        node: some SyntaxProtocol
    ) throws -> Assignment {
        var path: [Assignment.Step] = []
        var place = leftOperand
        while true {
            if let member = place.as(MemberAccessExprSyntax.self), let base = member.base {
                path.insert(.member(member.declName.baseName.plainName), at: 0)
                place = base
            } else if let chained = place.as(OptionalChainingExprSyntax.self) {
                path.insert(.optionalChain, at: 0)
                place = chained.expression
            } else if let unwrapped = place.as(ForceUnwrapExprSyntax.self) {
                path.insert(.unwrap, at: 0)
                place = unwrapped.expression
            } else if let subscripted = place.as(SubscriptCallExprSyntax.self),
                subscripted.arguments.count == 2,
                let key = subscripted.arguments.first, key.label == nil,
                let fallback = subscripted.arguments.last,
                fallback.label?.text == "default"
            {
                path.insert(
                    .indexDefault(
                        try expression(key.expression),
                        try expression(fallback.expression)
                    ),
                    at: 0
                )
                place = subscripted.calledExpression
            } else if let subscripted = place.as(SubscriptCallExprSyntax.self),
                subscripted.arguments.count == 1,
                let argument = subscripted.arguments.first, argument.label == nil
            {
                path.insert(.index(try expression(argument.expression)), at: 0)
                place = subscripted.calledExpression
            } else if let subscripted = place.as(SubscriptCallExprSyntax.self) {
                path.insert(.subscripted(try arguments(subscripted.arguments)), at: 0)
                place = subscripted.calledExpression
            } else {
                break
            }
        }
        guard let root = place.as(DeclReferenceExprSyntax.self) else {
            throw unsupported("this assignment", leftOperand)
        }
        var rootName = root.baseName.plainName
        // A static member, in a static member: `made += 1` is `Counter.made += 1`.
        if !locals.contains(where: { $0.contains(rootName) }), let context = staticContext,
            context.names.contains(rootName)
        {
            path.insert(.member(rootName), at: 0)
            rootName = context.owner
        }
        // A struct's own member, in a method: `n += 1` is `self.n += 1`.
        else if !locals.contains(where: { $0.contains(rootName) }),
            members.last?.contains(rootName) == true
        {
            path.insert(.member(rootName), at: 0)
            rootName = "self"
        }
        return Assignment(
            root: rootName,
            path: path,
            op: op,
            value: try held ?? expression(rightOperand!)
        )
    }
}
