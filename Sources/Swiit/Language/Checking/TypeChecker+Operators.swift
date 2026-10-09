import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Operators

    @_spi(Shell) public func binaryExprType(_ op: BinaryOperator, _ lhs: inout Expr, _ rhs: inout Expr, expected: TypeAnnotation?) throws -> TypeAnnotation {
        switch op {
        case .and, .or:
            try expect(&lhs, .bool, "'\(op.rawValue)''s left side")
            try expect(&rhs, .bool, "'\(op.rawValue)''s right side")
            return .bool
        case .coalesce:
            let left = try typeOf(&lhs)
            guard case .optional(let wrapped) = left else {
                // Never nil, so the right side is never used; Swift allows it too.
                _ = try typeOf(&rhs, expecting: left)
                return left
            }
            let right = try typeOf(&rhs, expecting: wrapped == .unknown ? expected : wrapped)
            if wrapped == .unknown { return right }
            // An Output or some text: the Output's text.
            if standsForText(wrapped), right == .string, rhs.isStringExpression { return .string }
            if fits(right, wrapped) { return wrapped }
            if fits(right, left) { return left }
            throw TypeError("'??' needs a \(wrapped) on its right, not \(right)")
        case .equal, .notEqual:
            // A `.case` on one side takes the other side's type.
            let (left, right) = try operandTypes(&lhs, &rhs)
            guard fits(left, right) || fits(right, left) || standsForText(left) && right == .string || left == .string && standsForText(right) else {
                throw TypeError("can't compare \(left) with \(right)")
            }
            // Anything optional compares with a `nil` literal, as in Swift.
            if case .literal(.nothing) = rhs { return .bool }
            if case .literal(.nothing) = lhs { return .bool }
            let compared = left == .unknown ? right : left
            guard conforms(compared, to: "Equatable") else {
                throw TypeError("'\(op.rawValue)' needs Equatable values, and \(compared) isn't: declare it, as in struct \(compared): Equatable")
            }
            return .bool
        default:
            let (left, right) = try operandTypes(&lhs, &rhs)
            return try binaryType(op, left, right)
        }
    }

    /// Both sides' types, letting a literal or `.case` on one side take its
    /// type from the other, as Swift does: `1 + 2.5`, `k == .file`.
    @_spi(Shell) public func operandTypes(_ lhs: inout Expr, _ rhs: inout Expr) throws -> (TypeAnnotation, TypeAnnotation) {
        if case .caseLiteral = lhs, !TypeChecker.isContextual(rhs) {
            let right = try typeOf(&rhs)
            return (try typeOf(&lhs, expecting: right), right)
        }
        var rightFirst: TypeAnnotation?
        if TypeChecker.isIntegerLiteral(lhs) {
            var probe = rhs
            rightFirst = try? typeOf(&probe)
        }
        let left = try typeOf(&lhs, expecting: rightFirst)
        let right = try typeOf(&rhs, expecting: left)
        if right == .double, TypeChecker.isIntegerLiteral(lhs) { return (.double, .double) }
        return (left, right)
    }

    @_spi(Shell) public static func isContextual(_ expr: Expr) -> Bool {
        switch expr {
        case .caseLiteral: true
        case .ifExpression(let node): branches(of: node).contains(where: isContextual)
        default: false
        }
    }

    /// An `if` expression's branches.
    @_spi(Shell) public static func branches(of node: IfStatement) -> [Expr] {
        [node.then, node.otherwise].compactMap { $0.flatMap(IfStatement.branchExpression) }
    }

    @_spi(Shell) public static func isIntegerLiteral(_ expr: Expr) -> Bool {
        switch expr {
        case .literal(.int): true
        case .unary(.negate, let inner): isIntegerLiteral(inner)
        default: false
        }
    }

    @_spi(Shell) public func binaryType(_ op: BinaryOperator, _ left: TypeAnnotation, _ right: TypeAnnotation) throws -> TypeAnnotation {
        if left == .unknown || right == .unknown {
            switch op {
            case .less, .lessEqual, .greater, .greaterEqual: return .bool
            case .closedRange, .halfOpenRange:
                return .generic(op == .closedRange ? "ClosedRange" : "Range", [left == .unknown ? right : left])
            default: return left == .unknown ? right : left
            }
        }
        let fail = TypeError("'\(op.rawValue)' can't be applied to \(left) and \(right)")
        // An operator a bridged type declares, for operands of it.
        if let result = bridgedOperatorType(op.rawValue, [left, right]) { return result }
        switch op {
        case .less, .lessEqual, .greater, .greaterEqual:
            guard left == right, conforms(left, to: "Comparable") else { throw fail }
            return .bool
        case .closedRange, .halfOpenRange:
            guard left == right, conforms(left, to: "Comparable") else { throw fail }
            return .generic(op == .closedRange ? "ClosedRange" : "Range", [left])
        case .add:
            switch (left, right) {
            case (.int, .int), (.double, .double), (.string, .string): return left
            case (.list(let a), .list(let b)) where fits(b, a): return left
            default: throw fail
            }
        case .subtract:
            switch (left, right) {
            case (.int, .int), (.double, .double): return left
            default: throw fail
            }
        case .multiply:
            switch (left, right) {
            case (.int, .int), (.double, .double): return left
            default: throw fail
            }
        case .divide:
            switch (left, right) {
            case (.int, .int), (.double, .double): return left
            default: throw fail
            }
        case .remainder:
            guard left == .int, right == .int else { throw fail }
            return .int
        default:
            throw fail
        }
    }
}
