import Foundation

// A value as a Swift mirror, for a host that reads it generically.

/// How a host reads what a value is made of, as it would any Swift value: `Mirror(reflecting:)`.
///
/// - `displayStyle` says its shape: `.collection` for a list, `.dictionary`, `.tuple`, `.struct`
///   for a struct value, `.enum` for a case of an enum, `.class` for a host's object that is data,
///   `.optional` for `nil`, and nothing for a scalar, a function and any other object.
/// - `children` are its elements, in order. A list's are unlabeled, and so are a dictionary's,
///   each a `(key: Value, value: Value)`. A tuple's and a struct's are labeled by field name (a
///   tuple's unlabeled elements by nothing), each value a `Value`. A case of an enum has, as
///   Swift's own do, one child labeled with the case's name if it carries anything: the value
///   itself if it is one unlabeled value, else a tuple of them.
///
/// Its type is `typeID`; `Mirror.subjectType` is `Value`.
extension Value: CustomReflectable {
    public var customMirror: Mirror {
        switch storage {
        case .nothing:
            return Mirror(self, children: [Mirror.Child](), displayStyle: .optional)
        case .bool, .int, .double, .string, .function:
            return Mirror(self, children: [Mirror.Child]())
        case .list(let items):
            return Mirror(self, unlabeledChildren: items, displayStyle: .collection)
        case .dictionary(let dictionary):
            return Mirror(
                self,
                unlabeledChildren: dictionary.map { (key: $0.key, value: $0.value) },
                displayStyle: .dictionary
            )
        case .tuple(let tuple):
            return Mirror(self, children: tuple.record.reflected, displayStyle: .tuple)
        case .structure(let structure):
            return Mirror(self, children: structure.record.reflected, displayStyle: .struct)
        case .enumValue(let value):
            return Mirror(self, children: value.reflected, displayStyle: .enum)
        case .object(let object):
            guard let fields = object.dataFields else {
                return Mirror(self, children: [Mirror.Child]())
            }
            let children = fields.map { field in
                Mirror.Child(label: field.key.casting(to: String.self), value: field.value)
            }
            return Mirror(self, children: children, displayStyle: .class)
        }
    }
}

extension Value.Record {
    /// Its fields as a mirror's children: labeled by name, but not by position.
    var reflected: [Mirror.Child] {
        map { Mirror.Child(label: Value.Record.isPosition($0.key) ? nil : $0.key, value: $0.value) }
    }
}
