import Foundation

// Equality and hashing of values.

extension Value: Hashable {
    /// Functions compare by identity.
    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case (.nothing, .nothing): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.list(let a), .list(let b)): a == b
        case (.tuple(let a), .tuple(let b)): a.record == b.record
        case (.structure(let a), .structure(let b)):
            a.record.typeName == b.record.typeName && a.record == b.record
        case (.dictionary(let a), .dictionary(let b)): a == b
        case (.enumValue(let a), .enumValue(let b)): a == b
        case (.object(let a), .object(let b)): Value.areEqual(a, b)
        case (.function(let a), .function(let b)): a === b
        default: false
        }
    }

    private static func areEqual(_ a: any LanguageObject, _ b: any LanguageObject) -> Bool {
        if a === b { return true }
        if let equal = a.equals(b) { return equal }
        return a.objectIdentity == b.objectIdentity
    }

    public func hash(into hasher: inout Hasher) {
        switch self.storage {
        case .nothing: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .int(let value): hasher.combine(value)
        case .double(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .list(let values): hasher.combine(values)
        case .tuple(let tuple): hasher.combine(tuple.record)
        case .structure(let structure):
            hasher.combine(structure.record.typeName)
            hasher.combine(structure.record)
        case .dictionary(let dictionary): hasher.combine(dictionary)
        case .enumValue(let value): hasher.combine(value)
        case .object(let object): hasher.combine(object.objectIdentity)
        case .function(let function): hasher.combine(ObjectIdentifier(function))
        }
    }
}
