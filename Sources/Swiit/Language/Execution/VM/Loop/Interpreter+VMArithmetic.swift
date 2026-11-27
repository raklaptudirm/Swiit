import Foundation

// Operations on numbers the loop does without the general `apply`.

extension Interpreter {
    /// An operation on two integers that needs no general `apply`: nil for one that does (a division,
    /// a shift), which gives what `apply` gives; an overflow is an error, as there.
    @inline(__always)
    static func arithmetic(_ op: BinaryOperator, _ x: Int, _ y: Int) throws -> Value? {
        switch op {
        case .add:
            let (sum, overflow) = x.addingReportingOverflow(y)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(sum)
        case .subtract:
            let (difference, overflow) = x.subtractingReportingOverflow(y)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(difference)
        case .multiply:
            let (product, overflow) = x.multipliedReportingOverflow(by: y)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(product)
        case .less: return .bool(x < y)
        case .lessEqual: return .bool(x <= y)
        case .greater: return .bool(x > y)
        case .greaterEqual: return .bool(x >= y)
        case .equal: return .bool(x == y)
        case .notEqual: return .bool(x != y)
        default: return nil
        }
    }
}

extension Value {
    /// What a field holding `old` is set to by `value`, or by `old op value`: `value` or the result of the
    /// operation when both are numbers, Bools or strings of one kind (an operation only on numbers). Nil
    /// for any other, which needs the conversion or the operator the general assignment has.
    static func combined(_ old: Value, _ op: BinaryOperator?, _ value: Value) -> Value? {
        switch (old.storage, value.storage) {
        case (.int(let x), .int(let y)):
            guard let op else { return value }
            guard let done = try? Interpreter.arithmetic(op, x, y), case .int = done.storage else {
                return nil
            }
            return done
        case (.double(let x), .double(let y)):
            switch op {
            case nil: return value
            case .add?: return .double(x + y)
            case .subtract?: return .double(x - y)
            case .multiply?: return .double(x * y)
            default: return nil
            }
        case (.bool, .bool), (.string, .string):
            return op == nil ? value : nil
        default:
            return nil
        }
    }
}
