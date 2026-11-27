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
    // safe: the storage is changed only through a record that holds the one reference to it
    /// The fields a tuple or a struct value keeps, in order, with the struct's type name. Two are
    /// equal when they have the same fields in the same order; a `Tuple` and a `Structure` add what
    /// else equality asks of them.
    ///
    /// A record is one reference to one allocation: a header (how many fields, the type, and a table of
    /// where each is once there are many) with the fields after it. Copies share it, and a copy that
    /// changes makes its own first.
    struct Record: @unchecked Sendable, Hashable, Sequence {
        private struct Field: Sendable, Hashable {
            var key: String
            var value: Value
        }

        private struct Header {
            var count = 0
            var capacity: Int
            /// The type it is a value of, which picks how it's displayed; nil for a tuple. A struct a
            /// program declares has that declaration's reference; one from a Swift value (`FileEntry`)
            /// has a host reference, by the Swift type's name.
            var typeRef: TypeRef?
            /// Where each field is, kept once there are more than `indexedFrom`: a record has few, so a
            /// field is found by comparing names, which for short ones is a comparison of two words.
            var table: [String: Int]?
        }

        private final class Storage: ManagedBuffer<Header, Field> {
            static func make(capacity: Int, typeRef: TypeRef?) -> Storage {
                let buffer = Storage.create(minimumCapacity: capacity) { _ in
                    Header(capacity: capacity, typeRef: typeRef)
                }
                return unsafeDowncast(buffer, to: Storage.self)
            }

            deinit {
                withUnsafeMutablePointers { header, fields in
                    _ = fields.deinitialize(count: header.pointee.count)
                }
            }
        }

        /// What every record without a type or fields shares: the first change to one makes its own.
        private static let none = Record(typeRef: nil, capacity: 0)

        private var storage: Storage

        /// How many fields a record has before it keeps a table of where each is.
        private static let indexedFrom = 12

        /// The type it is a value of, which picks how it's displayed; nil for a tuple.
        var typeRef: TypeRef? {
            get { storage.header.typeRef }
            set {
                prepare(adding: 0)
                storage.header.typeRef = newValue
            }
        }

        var typeName: String? {
            get { typeRef?.name }
            set { typeRef = newValue.map(TypeRef.native) }
        }

        init(typeRef: TypeRef? = nil) {
            storage =
                typeRef == nil ? Record.none.storage : Storage.make(capacity: 0, typeRef: typeRef)
        }

        /// A record with room for `capacity` fields, which are then added without it growing.
        init(typeRef: TypeRef?, capacity: Int) {
            storage = Storage.make(capacity: capacity, typeRef: typeRef)
        }

        /// A record of the fields `keys` name, in order, whose values are taken from the registers at
        /// `slots` from `registers`: those are left holding nothing. The keys are distinct.
        init(
            typeRef: TypeRef?,
            keys: [String],
            taking registers: UnsafeMutablePointer<Value>,
            at slots: [Int]
        ) {
            storage = Storage.make(capacity: keys.count, typeRef: typeRef)
            storage.withUnsafeMutablePointers { header, fields in
                for index in keys.indices {
                    let register = registers + slots[index]
                    (fields + index).initialize(to: Field(key: keys[index], value: register.move()))
                    register.initialize(to: .nothing)
                }
                header.pointee.count = keys.count
            }
            if keys.count > Record.indexedFrom { rebuildTable() }
        }

        init(typeName: String?) {
            self.init(typeRef: typeName.map(TypeRef.native))
        }

        init(_ fields: KeyValuePairs<String, Value>, typeRef: TypeRef? = nil) {
            self.init(typeRef: typeRef, capacity: fields.count)
            for (key, value) in fields { self[key] = value }
        }

        init(_ fields: KeyValuePairs<String, Value>, typeName: String?) {
            self.init(fields, typeRef: typeName.map(TypeRef.native))
        }

        /// Makes the storage this record's own, with room for `extra` more fields.
        private mutating func prepare(adding extra: Int) {
            let count = storage.header.count
            let capacity = storage.header.capacity
            if isKnownUniquelyReferenced(&storage) {
                guard count + extra > capacity else { return }
                moveStorage(capacity: Swift.max(count + extra, capacity * 2, 4))
            } else {
                copyStorage(capacity: Swift.max(count + extra, 1))
            }
        }

        private mutating func moveStorage(capacity: Int) {
            let made = Storage.make(capacity: capacity, typeRef: storage.header.typeRef)
            made.header.table = storage.header.table
            let count = storage.header.count
            made.withUnsafeMutablePointerToElements { to in
                storage.withUnsafeMutablePointerToElements { from in
                    to.moveInitialize(from: from, count: count)
                }
            }
            made.header.count = count
            // What it held is now in `made`.
            storage.header.count = 0
            storage = made
        }

        private mutating func copyStorage(capacity: Int) {
            let made = Storage.make(capacity: capacity, typeRef: storage.header.typeRef)
            made.header.table = storage.header.table
            let count = storage.header.count
            made.withUnsafeMutablePointerToElements { to in
                storage.withUnsafeMutablePointerToElements { from in
                    to.initialize(from: from, count: count)
                }
            }
            made.header.count = count
            storage = made
        }

        /// This record's fields in storage of its own, with room for `capacity` of them.
        func cloned(capacity: Int) -> Record {
            var made = self
            made.copyStorage(capacity: Swift.max(capacity, storage.header.count))
            return made
        }

        /// Adds a field whose name the record does not have, which the caller knows: no search.
        mutating func appendDistinct(_ key: String, _ value: Value) {
            prepare(adding: 1)
            let count = storage.header.count
            storage.withUnsafeMutablePointerToElements {
                ($0 + count).initialize(to: Field(key: key, value: value))
            }
            storage.header.count = count + 1
            if storage.header.table != nil {
                storage.header.table![key] = count
            } else if count + 1 > Record.indexedFrom {
                rebuildTable()
            }
        }

        /// Room for `count` fields, so that adding them does not grow it again and again.
        mutating func reserveCapacity(_ count: Int) {
            guard count > storage.header.capacity else { return }
            prepare(adding: count - storage.header.count)
        }

        /// Where the field named `key` is among the fields, if there is one.
        func position(of key: String) -> Int? {
            storage.withUnsafeMutablePointers { header, fields in
                if let table = header.pointee.table { return table[key] }
                for index in 0..<header.pointee.count where fields[index].key == key {
                    return index
                }
                return nil
            }
        }

        /// The value of the field at `position` if it is the one named `key`: what a site that found a
        /// field there before asks, to skip the search.
        func value(at position: Int, named key: String) -> Value? {
            storage.withUnsafeMutablePointers { header, fields in
                guard position >= 0, position < header.pointee.count, fields[position].key == key
                else { return nil }
                return fields[position].value
            }
        }

        subscript(key: String) -> Value? {
            get {
                guard let position = position(of: key) else { return nil }
                return storage.withUnsafeMutablePointerToElements { $0[position].value }
            }
            set {
                if let position = position(of: key) {
                    prepare(adding: 0)
                    if let newValue {
                        storage.withUnsafeMutablePointerToElements { $0[position].value = newValue }
                    } else {
                        remove(at: position)
                    }
                } else if let newValue {
                    appendDistinct(key, newValue)
                }
            }
        }

        private mutating func remove(at position: Int) {
            let count = storage.header.count
            storage.withUnsafeMutablePointerToElements { fields in
                (fields + position).deinitialize(count: 1)
                (fields + position)
                    .moveInitialize(from: fields + position + 1, count: count - position - 1)
            }
            storage.header.count = count - 1
            rebuildTable()
        }

        private mutating func rebuildTable() {
            let count = storage.header.count
            guard count > Record.indexedFrom else {
                storage.header.table = nil
                return
            }
            var made: [String: Int] = [:]
            made.reserveCapacity(count)
            storage.withUnsafeMutablePointerToElements { fields in
                for index in 0..<count { made[fields[index].key] = index }
            }
            storage.header.table = made
        }

        /// A field's value, moved out and left `.nothing` in its place: the caller then holds the only
        /// reference to it.
        mutating func takeValue(_ key: String) -> Value? {
            guard let position = position(of: key) else { return nil }
            prepare(adding: 0)
            return storage.withUnsafeMutablePointerToElements { fields in
                let current = fields[position].value
                fields[position].value = .nothing
                return current
            }
        }

        /// The names of the fields, in order.
        var keys: [String] {
            storage.withUnsafeMutablePointers { header, fields in
                (0..<header.pointee.count).map { fields[$0].key }
            }
        }

        /// Whether the fields are named `names`, in that order.
        func hasKeys(_ names: [String]) -> Bool {
            storage.withUnsafeMutablePointers { header, fields in
                guard header.pointee.count == names.count else { return false }
                for index in names.indices where fields[index].key != names[index] { return false }
                return true
            }
        }

        /// The value of the field at `position`, which is one of the fields.
        func value(atPosition position: Int) -> Value {
            storage.withUnsafeMutablePointerToElements { $0[position].value }
        }

        /// The name of the field at `position`.
        func key(at position: Int) -> String {
            storage.withUnsafeMutablePointerToElements { $0[position].key }
        }

        var count: Int { storage.header.count }
        var isEmpty: Bool { storage.header.count < 1 }

        func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
            FieldIterator(storage: storage)
        }

        private struct FieldIterator: IteratorProtocol {
            let storage: Storage
            var index = 0

            init(storage: Storage) { self.storage = storage }

            mutating func next() -> (key: String, value: Value)? {
                guard index < storage.header.count else { return nil }
                defer { index += 1 }
                return storage.withUnsafeMutablePointerToElements {
                    (key: $0[index].key, value: $0[index].value)
                }
            }
        }

        static func == (lhs: Value.Record, rhs: Value.Record) -> Bool {
            if lhs.storage === rhs.storage { return true }
            let count = lhs.storage.header.count
            guard count == rhs.storage.header.count else { return false }
            return lhs.storage.withUnsafeMutablePointerToElements { left in
                rhs.storage.withUnsafeMutablePointerToElements { right in
                    (0..<count).allSatisfy { left[$0] == right[$0] }
                }
            }
        }

        func hash(into hasher: inout Hasher) {
            storage.withUnsafeMutablePointers { header, fields in
                for index in 0..<header.pointee.count {
                    hasher.combine(fields[index].key)
                    hasher.combine(fields[index].value)
                }
            }
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
    /// of the type of one name and their fields are equal in order. Its record is one allocation that
    /// copies share and that a copy that changes makes its own of (and not before), so that a field set
    /// on a value nothing else holds is set where it is.
    struct Structure: Sendable, Hashable, Sequence, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        var record: Value.Record

        init(_ record: Value.Record) { self.record = record }

        /// A struct value of a Swift type, by name.
        init(typeName: String) { record = Value.Record(typeName: typeName) }

        /// A struct value of the type `typeRef` names.
        init(typeRef: TypeRef) { record = Value.Record(typeRef: typeRef) }

        /// What type it is a value of. A struct a program declares has that declaration's reference; one
        /// from a Swift value (`FileEntry`) has a host reference.
        var typeRef: TypeRef { record.typeRef! }

        /// The type it is a value of, if it has one.
        var typeRefIfAny: TypeRef? { record.typeRef }

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
