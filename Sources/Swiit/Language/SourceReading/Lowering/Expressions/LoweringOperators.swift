import SwiftSyntax

// Lowering prefix and infix operators.

extension Lowering {
    mutating func prefix(_ node: PrefixOperatorExprSyntax) throws -> Expr {
        let operand = try expression(node.expression)
        switch node.operator.text {
        case "-": return .unary(.negate, operand)
        case "!": return .unary(.not, operand)
        case "~": return .unary(.bitNot, operand)
        // A prefix operator the program declares.
        default: return .call(.variable("prefix " + node.operator.text), [Argument(value: operand)])
        }
    }

    func binaryOperator(_ text: String) -> BinaryOperator? {
        BinaryOperator(rawValue: text)
    }

    mutating func infix(_ node: InfixOperatorExprSyntax) throws -> Expr {
        // Left to right, as it is read: a name that isn't bound is found before an operator that
        // isn't Swift's.
        let left = try expression(node.leftOperand)
        if node.operator.is(AssignmentExprSyntax.self) {
            throw unsupported("an assignment in an expression", node)
        }
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self) else {
            throw unsupported("the operator '\(node.operator.trimmedDescription)'", node.operator)
        }
        // An operator the program declares is a function of that name.
        guard let kind = binaryOperator(op.operator.text) else {
            // Identity: a function, and `!==` is its negation.
            if op.operator.text == "===" || op.operator.text == "!==" {
                let identical = Expr.call(
                    .variable("==="),
                    [Argument(value: left), Argument(value: try expression(node.rightOperand))]
                )
                return op.operator.text == "===" ? identical : .unary(.not, identical)
            }
            // Only one a program declares is a function it can call.
            guard names()[op.operator.text] != nil else {
                throw unsupported("the operator '\(op.operator.text)'", node.operator)
            }
            return .call(
                .variable(op.operator.text),
                [Argument(value: left), Argument(value: try expression(node.rightOperand))]
            )
        }
        return .binary(kind, left, try expression(node.rightOperand))
    }
}
