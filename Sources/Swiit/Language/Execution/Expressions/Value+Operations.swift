import Foundation

extension Expr {
    /// A string literal, interpolated or not.
    var isStringExpression: Bool {
        switch self {
        case .literal(let value): value.isString
        case .string: true
        default: false
        }
    }
}

extension Value {
    /// The name of its type as errors say it: `Int`, `FileEntry`, `List`, `Tuple` for an unnamed
    /// struct.
    var typeName: String {
        switch self.storage {
        case .nothing: "Nothing"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .list: "List"
        case .tuple: "Tuple"
        case .structure(let structure): structure.typeName
        case .dictionary: "Dictionary"
        case .enumValue(let value): value.type.name
        case .object(let object): object.typeName
        case .function: "Function"
        @unknown default: "Value"
        }
    }

    var asDouble: Double? {
        switch self.storage {
        case .int(let n): Double(n)
        case .double(let d): d
        default: nil
        }
    }

    /// `==` with Int and Double comparing numerically, as their literals
    /// would in Swift.
    func isEqual(to other: Value) -> Bool {
        switch (self.storage, other.storage) {
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
    func conforming(to type: TypeExpression) -> Value? {
        // A key path is a function of one value, as in Swift, and no other kind. A closure is not
        // a key path: only one is the path of fields it names.
        if case .function(is KeyPathValue) = storage {
            if case .function(let function) = type {
                return function.parameters.count == 1 ? self : nil
            }
            if type.keyPathTypes != nil { return self }
        }
        switch (type, self.storage) {
        case (.any, _), (.unknown, _), (.bool, .bool), (.int, .int), (.double, .double),
            (.string, .string),
            (.callable, .function), (.function, .function), (.parameter, _),
            (.record, .tuple), (.record, .structure), (.void, .nothing):
            return self
        case (.tuple(let tuple), .tuple), (.tuple(let tuple), .structure):
            let elements = tuple.elements
            guard !elements.isEmpty, let record = record, record.count == elements.count
            else { return nil }
            var converted = Value.Record(typeRef: record.typeRef)
            for (index, (element, field)) in zip(elements, record).enumerated() {
                guard
                    element.label == nil || element.label == field.key
                        || field.key == String(index),
                    let value = field.value.conforming(to: element.type)
                else { return nil }
                converted[element.label ?? field.key] = value
            }
            return Value(record: converted)
        case (.double, .int(let n)):
            return .double(Double(n))
        default:
            break
        }
        if let (keyType, valueType) = type.dictionaryTypes,
            case .dictionary(let dictionary) = storage
        {
            var converted: [Value: Value] = [:]
            for (key, value) in dictionary {
                guard let k = key.conforming(to: keyType),
                    let v = value.conforming(to: valueType)
                else { return nil }
                converted[k] = v
            }
            return .dictionary(converted)
        }
        if let wrapped = type.optionalWrapped {
            if case .nothing = storage { return self }
            return conforming(to: wrapped)
        }
        if let element = type.arrayElement, case .list(let values) = storage {
            var converted: [Value] = []
            for value in values {
                guard let conforming = value.conforming(to: element) else { return nil }
                converted.append(conforming)
            }
            return .list(converted)
        }
        return nil
    }
}

extension Value {
    /// A list's items, or a Swift sequence's (a host type's lines): what sequence methods work on.
    var sequenceItems: [Value]? {
        switch self.storage {
        case .list(let items): items
        default: Interpreter.items(of: self).map { Array($0) }
        }
    }

    /// A total order for sorting: numbers numerically (Int and Double
    /// together), then by kind for values of different kinds.
    func order(comparedTo other: Value) -> ComparisonResult {
        func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        switch (self.storage, other.storage) {
        case (.bool(let a), .bool(let b)): return compare(a ? 1 : 0, b ? 1 : 0)
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double):
            return compare(asDouble!, other.asDouble!)
        case (.string(let a), .string(let b)): return a.compare(b)
        case (.enumValue(let a), .enumValue(let b)) where a.type === b.type:
            return compare(a.index, b.index)
        case (.object(let a as SwiftValue), .object(let b as SwiftValue)):
            if let less = a.isLess(than: b) {
                return less
                    ? .orderedAscending
                    : b.isLess(than: a) == true ? .orderedDescending : .orderedSame
            }
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
        switch self.storage {
        case .nothing: 0
        case .bool: 1
        case .int, .double: 2
        case .string: 5
        case .list: 6
        case .enumValue: 6
        case .tuple, .structure, .dictionary: 7
        case .object, .function: 8
        @unknown default: 9
        }
    }
}
