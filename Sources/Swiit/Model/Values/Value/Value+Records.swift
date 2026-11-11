import Foundation

// Records, tuples and structures: a value's ordered, named fields.

extension Value {
    /// A record, or an object's fields: what a table row is made from.
    var asRecord: Value.Record? {
        switch self.storage {
        case .tuple(let tuple): tuple.record
        case .structure(let structure): structure.record
        case .object(let object): object.objectFields
        default: nil
        }
    }
}

extension Value {
    /// The fields a tuple or a struct value keeps, in order, with the struct's type name. Two are
    /// equal when they have the same fields in the same order; a `Tuple` and a `Structure` add what
    /// else equality asks of them.
    struct Record: Sendable, Hashable, Sequence {
        private(set) var keys: [String] = []
        fileprivate var storage: [String: Value] = [:]
        /// The type it is a value of, which picks how it's displayed; nil for a tuple. A struct a
        /// program declares has that declaration's ID; one from a Swift value (`FileEntry`) has a
        /// host ID, by the Swift type's name.
        var typeID: Symbol.ID?

        var typeName: String? {
            get { typeID?.name }
            set { typeID = newValue.map(Symbol.ID.host) }
        }

        init(typeID: Symbol.ID? = nil) {
            self.typeID = typeID
        }

        init(typeName: String?) {
            self.typeID = typeName.map(Symbol.ID.host)
        }

        init(_ fields: KeyValuePairs<String, Value>, typeID: Symbol.ID? = nil) {
            self.typeID = typeID
            for (key, value) in fields { self[key] = value }
        }

        init(_ fields: KeyValuePairs<String, Value>, typeName: String?) {
            self.init(fields, typeID: typeName.map(Symbol.ID.host))
        }

        subscript(key: String) -> Value? {
            get { storage[key] }
            set {
                if let newValue {
                    if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
                } else if storage.removeValue(forKey: key) != nil {
                    keys.removeAll { $0 == key }
                }
            }
        }

        /// A field's value, moved out and left `.nothing` in its place: the caller then holds the only
        /// reference to it.
        mutating func takeValue(_ key: String) -> Value? {
            guard let current = storage[key] else { return nil }
            storage[key] = .nothing
            return current
        }

        var count: Int { keys.count }
        var isEmpty: Bool { keys.isEmpty }

        func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
            keys.lazy.map { (key: $0, value: storage[$0]!) }.makeIterator()
        }

        static func == (lhs: Value.Record, rhs: Value.Record) -> Bool {
            lhs.keys == rhs.keys && lhs.storage == rhs.storage
        }

        func hash(into hasher: inout Hasher) {
            for key in keys { hasher.combine(key); hasher.combine(storage[key]) }
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
    /// of the type of one name and their fields are equal in order.
    struct Structure: Sendable, Hashable, Sequence, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        var record: Value.Record

        init(_ record: Value.Record) { self.record = record }

        /// A struct value of a Swift type, by name.
        init(typeName: String) { record = Value.Record(typeName: typeName) }

        /// A struct value of the type `id` names.
        init(id: Symbol.ID) { record = Value.Record(typeID: id) }

        /// What type it is a value of. A struct a program declares has that declaration's ID; one
        /// from a Swift value (`FileEntry`) has a host ID.
        var id: Symbol.ID { record.typeID! }

        /// The type's name, which picks how it's displayed.
        var typeName: String { record.typeName ?? "" }

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

    /// The fields of a tuple or of a struct value, with the struct's type name.
    var record: Record? {
        switch self.storage {
        case .tuple(let tuple): tuple.record
        case .structure(let structure): structure.record
        default: nil
        }
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
        case .object(let object): object.dataFields
        default: nil
        }
    }
}
