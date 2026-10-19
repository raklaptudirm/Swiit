import Foundation

extension Interpreter {
    func intRange(_ op: BinaryOperator, _ lower: Value, _ upper: Value) throws -> Range<Int> {
        guard case .int(let low) = lower, case .int(let high) = upper else {
            throw RuntimeError("a range needs Int bounds, not \(lower.typeName) and \(upper.typeName)")
        }
        guard low <= high else { throw RuntimeError("range \(low)\(op.rawValue)\(high) has its bounds reversed") }
        if op == .halfOpenRange { return low..<high }
        guard high < Int.max else { throw RuntimeError("arithmetic overflow") }
        return low..<(high + 1)
    }

    func truth(_ expr: Expr, for op: BinaryOperator) throws -> Bool {
        let value = try evaluate(expr)
        guard case .bool(let truth) = value else {
            throw RuntimeError("'\(op.rawValue)' needs Bool operands, not \(value.typeName)")
        }
        return truth
    }

    func apply(_ op: UnaryOperator, _ value: Value) throws -> Value {
        switch (op, value) {
        case (.not, .bool(let b)):
            return .bool(!b)
        case (.negate, .int(let n)):
            let (result, overflow) = Int(0).subtractingReportingOverflow(n)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(result)
        case (.negate, .double(let d)):
            return .double(-d)
        case (.bitNot, .int(let n)):
            return .int(~n)
        default:
            if isDeclaredValue(value), let result = try userOperator("prefix " + op.rawValue, [value]) { return result }
            if let result = try bridgedOperator(op.rawValue, [value]) { return result }
            throw RuntimeError("'\(op.rawValue)' can't be applied to \(value.typeName)")
        }
    }

    /// Whether a value is of a type the program declared, which may have operators of its own.
    func isDeclaredValue(_ value: Value) -> Bool {
        switch value {
        case .record(let record): record.typeName != nil
        case .enumValue: true
        default: false
        }
    }

    /// The static methods named `name` a value's type has (a struct's, an enum's, or an extension's).
    func staticOperators(_ name: String, of value: Value) -> [Function] {
        var found: [Function] = []
        switch value {
        case .record(let record):
            if let type = structType(of: record) { found += type.staticMethods[name]?.candidates ?? [] }
        case .enumValue(let enumValue):
            found += enumMembers[ObjectIdentifier(enumValue.type)]?.staticMethods[name]?.candidates ?? []
        default:
            break
        }
        if let key = typeKey(of: value) { found += typeExtensions[key]?.staticMethods[name]?.candidates ?? [] }
        return found
    }

    /// The operator a program defines for these operands, as a static method of one of their types or
    /// a function: nil if none takes them.
    func userOperator(_ name: String, _ operands: [Value]) throws -> Value? {
        var candidates: [Function] = []
        for operand in operands { candidates += staticOperators(name, of: operand) }
        if case .function(let set as OverloadSet)? = lookup(name)?.value { candidates += set.candidates }
        var unique: [Function] = []
        for candidate in candidates where !unique.contains(where: { $0 === candidate }) { unique.append(candidate) }
        guard !unique.isEmpty else { return nil }
        let arguments = operands.map { Argument(label: nil, value: .literal($0)) }
        let chosen: (Function, [String: Value])
        do {
            chosen = try resolve(OverloadSet(name: name, candidates: unique)) { try self.bind(arguments, to: $0) }
        } catch is RuntimeError {
            return nil
        }
        return try invoke(chosen.0, with: chosen.1)
    }

    /// `a > b` from a `<` the type defines, and `a != b` from its `==`, as Comparable and Equatable give them.
    private func derivedOperator(_ op: BinaryOperator, _ lhs: Value, _ rhs: Value) throws -> Value? {
        func truth(_ value: Value?) -> Bool? { if case .bool(let result)? = value { result } else { nil } }
        switch op {
        case .notEqual: return truth(try userOperator("==", [lhs, rhs])).map { .bool(!$0) }
        case .greater: return truth(try userOperator("<", [rhs, lhs])).map(Value.bool)
        case .lessEqual: return truth(try userOperator("<", [rhs, lhs])).map { .bool(!$0) }
        case .greaterEqual: return truth(try userOperator("<", [lhs, rhs])).map { .bool(!$0) }
        default: return nil
        }
    }

    func apply(_ op: BinaryOperator, _ lhs: Value, _ rhs: Value) throws -> Value {
        // Two integers, the common case: nothing below applies to them but the arithmetic.
        if case .int(let a) = lhs, case .int(let b) = rhs {
            switch op {
            case .equal: return .bool(a == b)
            case .notEqual: return .bool(a != b)
            default: return try integerArithmetic(op, a, b)
            }
        }
        if isDeclaredValue(lhs) || isDeclaredValue(rhs) {
            if let result = try userOperator(op.rawValue, [lhs, rhs]) { return result }
            if let result = try derivedOperator(op, lhs, rhs) { return result }
        }
        // What stands for text (a command's output) compares as its text;
        // other String operations go through `.text`.
        let isComparison = op.isComparison
        if case .object = lhs, let text = lhs.text, isComparison {
            return try apply(op, .string(text), rhs)
        }
        if case .object = rhs, let text = rhs.text, isComparison {
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
        // Tuples compare element by element, as Swift's do.
        if case .record(let a) = lhs, case .record(let b) = rhs, a.typeName == nil, b.typeName == nil, a.count == b.count,
           [.less, .lessEqual, .greater, .greaterEqual].contains(op) {
            for (x, y) in zip(a, b) {
                if try apply(.equal, x.value, y.value) == .bool(true) { continue }
                return try apply(op == .lessEqual ? .less : op == .greaterEqual ? .greater : op, x.value, y.value)
            }
            return .bool(op == .lessEqual || op == .greaterEqual)
        }
        // Swift values that order themselves (an index, a date).
        if case .object(let a as SwiftValue) = lhs, case .object(let b as SwiftValue) = rhs,
           [.less, .lessEqual, .greater, .greaterEqual].contains(op), let ordered = a.isLess(than: b) {
            let equal = a.objectIdentity == b.objectIdentity
            switch op {
            case .less: return .bool(ordered)
            case .lessEqual: return .bool(ordered || equal)
            case .greater: return .bool(!ordered && !equal)
            default: return .bool(!ordered)
            }
        }
        if let result = try bridgedOperator(op.rawValue, [lhs, rhs]) { return result }
        throw RuntimeError("'\(op.rawValue)' can't be applied to \(lhs.typeName) and \(rhs.typeName)")
    }

    func integerArithmetic(_ op: BinaryOperator, _ a: Int, _ b: Int) throws -> Value {
        let result: (partialValue: Int, overflow: Bool)
        switch op {
        case .add: result = a.addingReportingOverflow(b)
        case .subtract: result = a.subtractingReportingOverflow(b)
        case .multiply: result = a.multipliedReportingOverflow(by: b)
        case .divide, .remainder:
            guard b != 0 else { throw RuntimeError("division by zero") }
            result = op == .divide ? a.dividedReportingOverflow(by: b) : a.remainderReportingOverflow(dividingBy: b)
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
        default:
            if let comparison = compare(op, a, b) { return .bool(comparison) }
            throw RuntimeError("'\(op.rawValue)' can't be applied to Int and Int")
        }
        guard !result.overflow else { throw RuntimeError("arithmetic overflow") }
        return .int(result.partialValue)
    }

    func floatingArithmetic(_ op: BinaryOperator, _ a: Double, _ b: Double) throws -> Value? {
        switch op {
        case .add: .double(a + b)
        case .subtract: .double(a - b)
        case .multiply: .double(a * b)
        case .divide: .double(a / b)
        default: compare(op, a, b).map(Value.bool)
        }
    }

    func compare<T: Comparable>(_ op: BinaryOperator, _ a: T, _ b: T) -> Bool? {
        switch op {
        case .less: a < b
        case .lessEqual: a <= b
        case .greater: a > b
        case .greaterEqual: a >= b
        default: nil
        }
    }
}
