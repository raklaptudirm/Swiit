import Foundation

// Records, tuples and structures: a value's ordered, named fields.

extension Value {
    /// A record, or an object's fields: what a table row is made from.
    var asRecord: Value.Record? {
        switch self.storage {
        case .tuple(let tuple): tuple.record
        case .structure(let structure): structure.record
        default: nil
        }
    }
}

extension Value {
    /// The fields a tuple or a struct value keeps, in order, with the struct's type name. Two are
    /// equal when they have the same fields in the same order; a `Tuple` and a `Structure` add what
    /// else equality asks of them.
    struct Record: Sendable, Hashable, Sequence {
        /// The fields in order. A record has few, so a field is found by comparing names, which for
        /// short ones is a comparison of two words; past `indexedFrom` there is a table as well.
        private var fields: [Field] = []
        private var table: [String: Int]?
        /// The type it is a value of, which picks how it's displayed; nil for a tuple. A struct a
        /// program declares has that declaration's reference; one from a Swift value (`FileEntry`) has a
        /// host reference, by the Swift type's name.
        var typeRef: TypeRef?

        private struct Field: Sendable, Hashable {
            var key: String
            var value: Value
        }

        /// How many fields a record has before it keeps a table of where each is.
        private static let indexedFrom = 12

        var typeName: String? {
            get { typeRef?.name }
            set { typeRef = newValue.map(TypeRef.native) }
        }

        init(typeRef: TypeRef? = nil) {
            self.typeRef = typeRef
        }

        init(typeName: String?) {
            self.typeRef = typeName.map(TypeRef.native)
        }

        init(_ fields: KeyValuePairs<String, Value>, typeRef: TypeRef? = nil) {
            self.typeRef = typeRef
            for (key, value) in fields { self[key] = value }
        }

        init(_ fields: KeyValuePairs<String, Value>, typeName: String?) {
            self.init(fields, typeRef: typeName.map(TypeRef.native))
        }

        /// Adds a field whose name the record does not have, which the caller knows: no search.
        mutating func appendDistinct(_ key: String, _ value: Value) {
            fields.append(Field(key: key, value: value))
            if table != nil {
                table![key] = fields.count - 1
            } else if fields.count > Record.indexedFrom {
                rebuildTable()
            }
        }

        /// Room for `count` fields, so that adding them does not grow it again and again.
        mutating func reserveCapacity(_ count: Int) {
            fields.reserveCapacity(count)
        }

        /// Where the field named `key` is among the fields, if there is one.
        func position(of key: String) -> Int? {
            if let table { return table[key] }
            for index in fields.indices where fields[index].key == key { return index }
            return nil
        }

        /// The value of the field at `position` if it is the one named `key`: what a site that found a
        /// field there before asks, to skip the search.
        func value(at position: Int, named key: String) -> Value? {
            guard fields.indices.contains(position), fields[position].key == key else { return nil }
            return fields[position].value
        }

        subscript(key: String) -> Value? {
            get { position(of: key).map { fields[$0].value } }
            set {
                if let position = position(of: key) {
                    if let newValue {
                        fields[position].value = newValue
                    } else {
                        fields.remove(at: position)
                        rebuildTable()
                    }
                } else if let newValue {
                    fields.append(Field(key: key, value: newValue))
                    if table != nil {
                        table![key] = fields.count - 1
                    } else if fields.count > Record.indexedFrom {
                        rebuildTable()
                    }
                }
            }
        }

        private mutating func rebuildTable() {
            guard fields.count > Record.indexedFrom else {
                table = nil
                return
            }
            var made: [String: Int] = [:]
            made.reserveCapacity(fields.count)
            for (index, field) in fields.enumerated() { made[field.key] = index }
            table = made
        }

        /// A field's value, moved out and left `.nothing` in its place: the caller then holds the only
        /// reference to it.
        mutating func takeValue(_ key: String) -> Value? {
            guard let position = position(of: key) else { return nil }
            let current = fields[position].value
            fields[position].value = .nothing
            return current
        }

        /// The names of the fields, in order.
        var keys: [String] { fields.map(\.key) }

        /// The name of the field at `position`.
        func key(at position: Int) -> String { fields[position].key }

        var count: Int { fields.count }
        var isEmpty: Bool { fields.isEmpty }

        func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
            fields.lazy.map { (key: $0.key, value: $0.value) }.makeIterator()
        }

        static func == (lhs: Value.Record, rhs: Value.Record) -> Bool {
            lhs.fields == rhs.fields
        }

        func hash(into hasher: inout Hasher) {
            for field in fields { hasher.combine(field.key); hasher.combine(field.value) }
        }
    }
}

extension Value.Record: CustomStringConvertible, CustomDebugStringConvertible {
    /// As its type would print, `Status(code: 0, …)`, or as a tuple,
    /// `(name: "x", 2)`, for a record without one; a tuple's unlabeled
    /// elements are keyed by position.
    var debugDescription: String {
        (typeName ?? "") + "("
            + map { field in
                (Value.Record.isPosition(field.key) ? "" : "\(field.key): ")
                    + field.value.debugDescription
            }
            .joined(separator: ", ") + ")"
    }

    /// What interpolation shows: like `debugDescription`, with text unquoted.
    var description: String {
        (typeName ?? "") + "("
            + map { field in
                (Value.Record.isPosition(field.key) ? "" : "\(field.key): ")
                    + field.value.description
            }
            .joined(separator: ", ") + ")"
    }

    /// `0`, `1`, …: the key of a tuple element without a label.
    static func isPosition(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy(\.isNumber)
    }
}

extension Value {
    /// A tuple: its elements in order, each with a label or, without one, its position (`"0"`,
    /// `"1"`) for a name. Two are equal when their elements are, label by label, in order.
    struct Tuple: Sendable, Hashable, Sequence, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        var record: Value.Record

        init(_ record: Value.Record) { self.record = record }

        init() { record = Value.Record() }

        var keys: [String] { record.keys }
        var count: Int { record.count }
        var isEmpty: Bool { record.isEmpty }

        subscript(key: String) -> Value? {
            get { record[key] }
            set { record[key] = newValue }
        }

        func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
            record.makeIterator()
        }

        var description: String { record.description }
        var debugDescription: String { record.debugDescription }
    }

    /// A struct's value: the name of its type, and its fields in order. Two are equal when they are
    /// of the type of one name and their fields are equal in order. The record is kept in a box that
    /// copies are shared by and that is copied when one of them changes (and not before), so that a
    /// field set on a value nothing else holds is set where it is.
    struct Structure: Sendable, Hashable, Sequence, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        // safe: the box is changed only when this value holds the one reference to it
        private final class Box: @unchecked Sendable {
            @exclusivity(unchecked) var record: Value.Record
            init(_ record: Value.Record) { self.record = record }
        }

        private var box: Box

        var record: Value.Record {
            get { box.record }
            _modify {
                if !isKnownUniquelyReferenced(&box) { box = Box(box.record) }
                yield &box.record
            }
            set {
                if isKnownUniquelyReferenced(&box) {
                    box.record = newValue
                } else {
                    box = Box(newValue)
                }
            }
        }

        init(_ record: Value.Record) { box = Box(record) }

        /// A struct value of a Swift type, by name.
        init(typeName: String) { box = Box(Value.Record(typeName: typeName)) }

        /// A struct value of the type `typeRef` names.
        init(typeRef: TypeRef) { box = Box(Value.Record(typeRef: typeRef)) }

        static func == (lhs: Structure, rhs: Structure) -> Bool {
            lhs.box === rhs.box || lhs.box.record == rhs.box.record
        }

        func hash(into hasher: inout Hasher) { hasher.combine(box.record) }

        /// What type it is a value of. A struct a program declares has that declaration's reference; one
        /// from a Swift value (`FileEntry`) has a host reference.
        var typeRef: TypeRef { box.record.typeRef! }

        /// The type it is a value of, if it has one: read without copying the record.
        var typeRefIfAny: TypeRef? { box.record.typeRef }

        /// The type's name, which picks how it's displayed.
        var typeName: String { box.record.typeName ?? "" }

        var keys: [String] { box.record.keys }
        var count: Int { box.record.count }
        var isEmpty: Bool { box.record.isEmpty }

        subscript(key: String) -> Value? {
            get { box.record[key] }
            set { record[key] = newValue }
        }

        func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
            box.record.makeIterator()
        }

        var description: String { box.record.description }
        var debugDescription: String { box.record.debugDescription }
    }

    /// The fields of a tuple or of a struct value, with the struct's type name.
    var record: Record? {
        switch self.storage {
        case .tuple(let tuple): tuple.record
        case .structure(let structure): structure.record
        default: nil
        }
    }

    /// A value with these fields, in this order, that scripts read as they read a struct's: `typeName`
    /// is what it is called (`JSONObject`), and the fields are read by name (`value.name`). It is equal to
    /// another of the same name that holds the same fields in the same order. For data whose field names
    /// come from outside the program, which a script cannot declare as a struct.
    public init(fields: [(name: String, value: Value)], typeName: String) {
        var record = Record(typeName: typeName)
        for (name, value) in fields { record[name] = value }
        self.init(record: record)
    }

    /// A tuple, or a struct value if the record has a type name.
    init(record: Record) {
        self = record.typeName == nil ? .tuple(Tuple(record)) : .structure(Structure(record))
    }
}

extension Value {
    /// The fields of a structured value as ordered pairs, which `customMirror` reflects: a
    /// dictionary's, in Swift's order (no particular one), the fields of a tuple or a struct by
    /// name (a tuple's unlabeled ones by position, "0", "1"), or the data of a host's object. Nil
    /// for any other value.
    var entries: [(key: Value, value: Value)]? {
        switch self.storage {
        case .dictionary(let dictionary): dictionary.map { (key: $0.key, value: $0.value) }
        case .tuple, .structure:
            record!.map { (key: Value.string($0.key), value: $0.value) }
        default: nil
        }
    }
}
