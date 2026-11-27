import Foundation

// Operators on two values of one plain kind: Int, Double, String or Bool. This is the one definition
// of what they give, which `Interpreter.apply` uses first and the VM's fast paths use instead of
// working it out again.

extension Value {
    /// `lhs op rhs` where both are of one plain kind, as Swift computes it: the result, or the error
    /// Swift would stop with (an overflow, a division by zero, an operator Int does not have). Nil
    /// where the two are not of one plain kind, or the operator is not one of that kind's, which
    /// `Interpreter.apply` then decides.
    static func plainOperation(_ op: BinaryOperator, _ lhs: Value, _ rhs: Value) throws -> Value? {
        switch (lhs.storage, rhs.storage) {
        case (.int(let a), .int(let b)):
            return try integerArithmetic(op, a, b)
        case (.double(let a), .double(let b)):
            return floatingOperation(op, a, b)
        case (.string(let a), .string(let b)):
            switch op {
            case .equal: return .bool(a == b)
            case .notEqual: return .bool(a != b)
            case .add: return .string(a + b)
            default: return comparison(op, a, b).map(Value.bool)
            }
        case (.bool(let a), .bool(let b)):
            switch op {
            case .equal: return .bool(a == b)
            case .notEqual: return .bool(a != b)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// `a op b` on two Ints: an overflow and a division by zero are errors, as in Swift, and so is an
    /// operator Int does not have.
    @inline(never)
    static func integerArithmetic(_ op: BinaryOperator, _ a: Int, _ b: Int) throws -> Value {
        if let result = try commonIntegerOperation(op, a, b) { return result }
        let result: (partialValue: Int, overflow: Bool)
        switch op {
        case .divide, .remainder:
            guard b != 0 else { throw RuntimeError("division by zero") }
            result =
                op == .divide
                ? a.dividedReportingOverflow(by: b) : a.remainderReportingOverflow(dividingBy: b)
        case .bitAnd: return .int(a & b)
        case .bitOr: return .int(a | b)
        case .bitXor: return .int(a ^ b)
        case .shiftLeft: return .int(a << b)
        case .shiftRight: return .int(a >> b)
        case .maskShiftLeft: return .int(a &<< b)
        case .maskShiftRight: return .int(a &>> b)
        case .wrapAdd: return .int(a &+ b)
        case .wrapSubtract: return .int(a &- b)
        case .wrapMultiply: return .int(a &* b)
        default: throw RuntimeError("'\(op.rawValue)' can't be applied to Int and Int")
        }
        guard !result.overflow else { throw RuntimeError("arithmetic overflow") }
        return .int(result.partialValue)
    }

    /// `integerArithmetic` for the operators loops use most (`+`, `-`, `*` and the comparisons): nil
    /// for the rest. Small, so that the VM's loop inlines it and leaves the rest to `apply`.
    @inline(__always)
    static func commonIntegerOperation(_ op: BinaryOperator, _ a: Int, _ b: Int) throws -> Value? {
        switch op {
        case .add:
            let (sum, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(sum)
        case .subtract:
            let (difference, overflow) = a.subtractingReportingOverflow(b)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(difference)
        case .multiply:
            let (product, overflow) = a.multipliedReportingOverflow(by: b)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(product)
        case .less: return .bool(a < b)
        case .lessEqual: return .bool(a <= b)
        case .greater: return .bool(a > b)
        case .greaterEqual: return .bool(a >= b)
        case .equal: return .bool(a == b)
        case .notEqual: return .bool(a != b)
        default: return nil
        }
    }

    /// `a op b` on two Doubles, which never fails: a division by zero is an infinity, as in Swift. Nil
    /// for an operator Double does not have.
    static func floatingOperation(_ op: BinaryOperator, _ a: Double, _ b: Double) -> Value? {
        switch op {
        case .add: .double(a + b)
        case .subtract: .double(a - b)
        case .multiply: .double(a * b)
        case .divide: .double(a / b)
        case .equal: .bool(a == b)
        case .notEqual: .bool(a != b)
        default: comparison(op, a, b).map(Value.bool)
        }
    }

    /// `a op b` for an ordering operator; nil for any other.
    static func comparison<T: Comparable>(_ op: BinaryOperator, _ a: T, _ b: T) -> Bool? {
        switch op {
        case .less: a < b
        case .lessEqual: a <= b
        case .greater: a > b
        case .greaterEqual: a >= b
        default: nil
        }
    }
}
