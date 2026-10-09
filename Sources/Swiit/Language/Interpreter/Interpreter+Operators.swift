import Foundation
import SwishKit

extension Interpreter {
    @_spi(Shell) public func intRange(_ op: BinaryOperator, _ lower: Value, _ upper: Value) throws -> Range<Int> {
        guard case .int(let low) = lower, case .int(let high) = upper else {
            throw RuntimeError("a range needs Int bounds, not \(lower.typeName) and \(upper.typeName)")
        }
        guard low <= high else { throw RuntimeError("range \(low)\(op.rawValue)\(high) has its bounds reversed") }
        if op == .halfOpenRange { return low..<high }
        guard high < Int.max else { throw RuntimeError("arithmetic overflow") }
        return low..<(high + 1)
    }

    @_spi(Shell) public func truth(_ expr: Expr, for op: BinaryOperator) throws -> Bool {
        let value = try evaluate(expr)
        guard case .bool(let truth) = value else {
            throw RuntimeError("'\(op.rawValue)' needs Bool operands, not \(value.typeName)")
        }
        return truth
    }

    @_spi(Shell) public func apply(_ op: UnaryOperator, _ value: Value) throws -> Value {
        switch (op, value) {
        case (.not, .bool(let b)):
            return .bool(!b)
        case (.negate, .int(let n)):
            let (result, overflow) = Int(0).subtractingReportingOverflow(n)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(result)
        case (.negate, .double(let d)):
            return .double(-d)
        default:
            if let result = try bridgedOperator(op.rawValue, [value]) { return result }
            throw RuntimeError("'\(op.rawValue)' can't be applied to \(value.typeName)")
        }
    }

    @_spi(Shell) public func apply(_ op: BinaryOperator, _ lhs: Value, _ rhs: Value) throws -> Value {
        // What stands for text (a command's output) compares as its text;
        // other String operations go through `.text`.
        let comparisons: [BinaryOperator] = [.equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual]
        if case .object = lhs, let text = lhs.text, comparisons.contains(op) {
            return try apply(op, .string(text), rhs)
        }
        if case .object = rhs, let text = rhs.text, comparisons.contains(op) {
            return try apply(op, lhs, .string(text))
        }
        if case .object = lhs, lhs.text != nil, op == .add {
            throw RuntimeError("'+' needs the text of a \(lhs.typeName): use .text")
        }
        if op == .equal || op == .notEqual {
            if case .enumValue(let value) = lhs, case .string(let text) = rhs {
                throw RuntimeError("can't compare \(value.type.name) with a String; compare with a case, like .\(text)")
            }
            if case .string(let text) = lhs, case .enumValue(let value) = rhs {
                throw RuntimeError("can't compare a String with \(value.type.name); compare with a case, like .\(text)")
            }
        }
        switch (op, lhs, rhs) {
        case (.equal, _, _):
            return .bool(lhs.isEqual(to: rhs))
        case (.notEqual, _, _):
            return .bool(!lhs.isEqual(to: rhs))
        case (.add, .string(let a), .string(let b)):
            return .string(a + b)
        case (.add, .list(let a), .list(let b)):
            return .list(a + b)
        case (_, .string(let a), .string(let b)):
            if let result = compare(op, a, b) { return .bool(result) }
        case (_, .int(let a), .int(let b)):
            return try integerArithmetic(op, a, b)
        case (_, .int, .double), (_, .double, .int), (_, .double, .double):
            if let result = try floatingArithmetic(op, lhs.asDouble!, rhs.asDouble!) { return result }
        // A Comparable enum: in the order its cases are declared.
        case (_, .enumValue(let a), .enumValue(let b)) where a.type === b.type:
            if let result = compare(op, a.index, b.index) { return .bool(result) }
        default:
            break
        }
        if let result = try bridgedOperator(op.rawValue, [lhs, rhs]) { return result }
        throw RuntimeError("'\(op.rawValue)' can't be applied to \(lhs.typeName) and \(rhs.typeName)")
    }

    @_spi(Shell) public func integerArithmetic(_ op: BinaryOperator, _ a: Int, _ b: Int) throws -> Value {
        let result: (partialValue: Int, overflow: Bool)
        switch op {
        case .add: result = a.addingReportingOverflow(b)
        case .subtract: result = a.subtractingReportingOverflow(b)
        case .multiply: result = a.multipliedReportingOverflow(by: b)
        case .divide, .remainder:
            guard b != 0 else { throw RuntimeError("division by zero") }
            result = op == .divide ? a.dividedReportingOverflow(by: b) : a.remainderReportingOverflow(dividingBy: b)
        default:
            if let comparison = compare(op, a, b) { return .bool(comparison) }
            throw RuntimeError("'\(op.rawValue)' can't be applied to Int and Int")
        }
        guard !result.overflow else { throw RuntimeError("arithmetic overflow") }
        return .int(result.partialValue)
    }

    @_spi(Shell) public func floatingArithmetic(_ op: BinaryOperator, _ a: Double, _ b: Double) throws -> Value? {
        switch op {
        case .add: .double(a + b)
        case .subtract: .double(a - b)
        case .multiply: .double(a * b)
        case .divide: .double(a / b)
        default: compare(op, a, b).map(Value.bool)
        }
    }

    @_spi(Shell) public func compare<T: Comparable>(_ op: BinaryOperator, _ a: T, _ b: T) -> Bool? {
        switch op {
        case .less: a < b
        case .lessEqual: a <= b
        case .greater: a > b
        case .greaterEqual: a >= b
        default: nil
        }
    }
}
