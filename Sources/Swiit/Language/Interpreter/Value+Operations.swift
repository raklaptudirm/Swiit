import Foundation
import SwishKit

extension Expr {
    /// A string literal, interpolated or not.
    @_spi(Shell) public var isStringExpression: Bool {
        switch self {
        case .literal(.string), .string: true
        default: false
        }
    }
}

extension Value {
    @_spi(Shell) public var typeName: String {
        switch self {
        case .nothing: "Nothing"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .list: "List"
        case .record(let record): record.typeName ?? "Tuple"
        case .dictionary: "Dictionary"
        case .enumValue(let value): value.type.name
        case .object(let object): object.typeName
        case .function: "Function"
        @unknown default: "Value"
        }
    }

    @_spi(Shell) public var asDouble: Double? {
        switch self {
        case .int(let n): Double(n)
        case .double(let d): d
        default: nil
        }
    }

    /// `==` with Int and Double comparing numerically, as their literals
    /// would in Swift.
    @_spi(Shell) public func isEqual(to other: Value) -> Bool {
        switch (self, other) {
        case (.int, .double), (.double, .int):
            return asDouble == other.asDouble
        case (.list(let a), .list(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.isEqual(to: $1) }
        default:
            return self == other
        }
    }

    /// This value as `type`, or nil if it doesn't fit. An Int passes as a
    /// Double, as an integer literal would in Swift.
    @_spi(Shell) public func conforming(to type: TypeAnnotation) -> Value? {
        switch (type, self) {
        // What stands for text is the text where a String is wanted, and a
        // command's output is its lines where a list of them is.
        case (.string, .object) where text != nil:
            return .string(text!)
        case (.list(.string), .object) where commandOutput != nil:
            return .list(commandOutput!.lines.map(Value.string))
        // A key path is a function of one value, as in Swift, and no other kind.
        case (.functionType(let parameters, _, _), .function(is KeyPathValue)):
            return parameters.count == 1 ? self : nil
        case (.any, _), (.unknown, _), (.bool, .bool), (.int, .int), (.double, .double), (.string, .string),
             (.function, .function), (.functionType, .function), (.keyPath, .function), (.parameter, _),
             (.record, .record), (.void, .nothing):
            return self
        case (.tuple(let elements), .record(let record)):
            guard record.count == elements.count else { return nil }
            var converted = Record(typeName: record.typeName)
            for (index, (element, field)) in zip(elements, record).enumerated() {
                guard element.label == nil || element.label == field.key || field.key == String(index),
                      let value = field.value.conforming(to: element.type) else { return nil }
                converted[element.label ?? field.key] = value
            }
            return .record(converted)
        case (.dictionary(let keyType, let valueType), .dictionary(let dictionary)):
            var converted = ValueDictionary()
            for (key, value) in dictionary {
                guard let k = key.conforming(to: keyType), let v = value.conforming(to: valueType) else { return nil }
                converted[k] = v
            }
            return .dictionary(converted)
        case (.double, .int(let n)):
            return .double(Double(n))
        case (.optional, .nothing):
            return self
        case (.optional(let wrapped), _):
            return conforming(to: wrapped)
        case (.list(let element), .list(let values)):
            var converted: [Value] = []
            for value in values {
                guard let conforming = value.conforming(to: element) else { return nil }
                converted.append(conforming)
            }
            return .list(converted)
        default:
            return nil
        }
    }
}

extension SwishKit.Value {
    /// A list's items, or an Output's lines: what sequence methods work on.
    @_spi(Shell) public var sequenceItems: [Value]? {
        switch self {
        case .list(let items): items
        default: commandOutput?.lines.map(Value.string)
        }
    }

    /// A total order for sorting: numbers numerically (Int and Double
    /// together), then by kind for values of different kinds.
    @_spi(Shell) public func order(comparedTo other: SwishKit.Value) -> ComparisonResult {
        func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        // What stands for text sorts as its text.
        if case .object = self, let a = text { return Value.string(a).order(comparedTo: other) }
        if case .object = other, let b = other.text { return order(comparedTo: .string(b)) }
        switch (self, other) {
        case (.bool(let a), .bool(let b)): return compare(a ? 1 : 0, b ? 1 : 0)
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double): return compare(asDouble!, other.asDouble!)
        case (.string(let a), .string(let b)): return a.compare(b)
        case (.enumValue(let a), .enumValue(let b)) where a.type === b.type: return compare(a.index, b.index)
        case (.object(let a as SwiftValue), .object(let b as SwiftValue)):
            if let less = a.isLess(than: b) { return less ? .orderedAscending : b.isLess(than: a) == true ? .orderedDescending : .orderedSame }
            return compare(a.typeName, b.typeName)
        case (.list(let a), .list(let b)):
            for (x, y) in zip(a, b) {
                let order = x.order(comparedTo: y)
                if order != .orderedSame { return order }
            }
            return compare(a.count, b.count)
        default: return compare(kindRank, other.kindRank)
        }
    }

    private var kindRank: Int {
        switch self {
        case .nothing: 0
        case .bool: 1
        case .int, .double: 2
        case .string: 5
        case .list: 6
        case .enumValue: 6
        case .record, .dictionary: 7
        case .object, .function: 8
        @unknown default: 9
        }
    }
}
