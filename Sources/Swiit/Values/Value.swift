import Foundation

/// A value flowing through Swiit.
///
/// This is the currency shared by the interpreter and its hosts,
/// which is why it lives in its own dynamic library.
public struct Value: Sendable {
    // The representation is the interpreter's: a host builds a value with its initializers,
    // literals and static members, and reads one with `casting(to:)`, `typeID`, `isInstance(of:)`,
    // `entries` and the views (`tuple`, `structure`, `enumCase`), so a new representation never
    // breaks it.
    var storage: Storage

    init(_ storage: Storage) { self.storage = storage }

    /// What a value is made of: the interpreter's fast representation.
    enum Storage: Sendable {
        case nothing
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case list([Value])
        /// A tuple: elements in order, each labeled or not: `(name: "x", 2)`.
        case tuple(Value.Tuple)
        /// A struct's value: its type's name, and its fields in the order the type declares them.
        case structure(Value.Structure)
        /// `["a": 1]`: keys to values, as Swift's Dictionary, unordered.
        case dictionary([Value: Value])
        /// A case of an enum: `.directory`, or `.failed(code: 2)`.
        case enumValue(Value.EnumCase)
        /// A live value with members of its own: a background job, an enum type,
        /// and later bridged Swift objects.
        case object(any LanguageObject)
        case function(any Callable)
    }

    /// `nil`, which a script writes `nil`. The language's own `nil` is a value, as a list's element or
    /// a field or an argument is, which a Swift `Optional<Value>` cannot say: that one is absent. The
    /// other kinds are made with `Value(3)`, `Value("x")` and the rest of the initializers; the
    /// static functions of the same names are the interpreter's own shorthand.
    public static let nothing = Value(Storage.nothing)
    static func bool(_ value: Bool) -> Value { Value(Storage.bool(value)) }
    static func int(_ value: Int) -> Value { Value(Storage.int(value)) }
    static func double(_ value: Double) -> Value { Value(Storage.double(value)) }
    static func string(_ value: String) -> Value { Value(Storage.string(value)) }
    static func list(_ values: [Value]) -> Value { Value(Storage.list(values)) }
    var isFunction: Bool { if case .function = storage { true } else { false } }
    var isString: Bool { if case .string = storage { true } else { false } }
    var isBool: Bool { if case .bool = storage { true } else { false } }
    var isInt: Bool { if case .int = storage { true } else { false } }
    static func tuple(_ value: Value.Tuple) -> Value { Value(Storage.tuple(value)) }
    static func structure(_ value: Value.Structure) -> Value { Value(Storage.structure(value)) }
    static func dictionary(_ value: [Value: Value]) -> Value { Value(Storage.dictionary(value)) }
    static func enumValue(_ value: Value.EnumCase) -> Value { Value(Storage.enumValue(value)) }
    static func object(_ value: any LanguageObject) -> Value { Value(Storage.object(value)) }
    static func function(_ value: any Callable) -> Value { Value(Storage.function(value)) }
}

/// An object the language makes itself (an instance, a type, a weak reference, a Swift value held
/// as it is, a host's value or live object held as it is). The checker types the language's by
/// what they are, and a host's by the type it registered, or by the protocol the program declares
/// under its name.
protocol LanguageObject: AnyObject, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
    /// The name `members` and error messages use, like `Job`.
    var typeName: String { get }
    /// Names of its members, for `members` and completion.
    var memberNames: [String] { get }
    /// A member answered at run time, after the registered ones; nil if there is none.
    func member(_ name: String) -> Value?
}

extension LanguageObject {
    /// The registered members of its type, unless it says.
    var memberNames: [String] {
        var seen = Set<String>()
        return (Bridge.types[typeName]?.members ?? [])
            .filter { !$0.isStatic && ($0.kind == .method || $0.kind == .property) }
            .map(\.name).filter { seen.insert($0).inserted }
    }

    /// The registered members of its type: a property is read, a method is a function bound to the
    /// object.
    func member(_ name: String) -> Value? {
        guard
            let member = Bridge.types[typeName]?.members
                .first(where: { $0.name == name && !$0.isStatic && !$0.isMutating }),
            let plain = member.plain
        else { return nil }
        let receiver = Value.object(self)
        switch member.kind {
        case .property: return try? plain(["self": receiver])
        case .method:
            return Value(
                HostSymbol.function(
                    name: name,
                    summary: member.summary,
                    signature: Symbol.Function(
                        parameters: member.parameters.map {
                            Symbol.Parameter(
                                label: $0.label,
                                name: $0.name,
                                type: ScriptType($0.type)
                            )
                        },
                        returns: ScriptType(member.returns),
                        isThrowing: member.isThrowing
                    ),
                    call: { arguments in
                        var arguments = arguments
                        arguments["self"] = receiver
                        return try plain(arguments)
                    }
                )
            )
        default: return nil
        }
    }

    /// Its data as named fields, which a host lays out as a record (a table, JSON): every member that isn't
    /// a method. What the language makes itself (a type, an instance, a Swift value held as it is)
    /// has none: it is one value, like a `FileSize`.
    var dataFields: [(key: Value, value: Value)]? {
        // A held value is data if it names its members: a parsed object's keys, a job's fields.
        guard let box = self as? SwiftValue,
            (box.value as? any ScriptConvertible)?.memberNames != nil
        else { return nil }
        var fields: [(key: Value, value: Value)] = []
        for name in memberNames {
            guard let value = member(name) else { continue }
            if case .function = value.storage { continue }
            fields.append((Value.string(name), value))
        }
        return fields
    }

    /// `dataFields` as the language's record of the object's type.
    var objectFields: Value.Record? {
        guard let fields = dataFields else { return nil }
        var record = Value.Record(typeName: typeName)
        for (key, value) in fields {
            if case .string(let name) = key.storage { record[name] = value }
        }
        return record
    }

    /// What equality and hashing go by: the object itself, and for a Swift value held as it is,
    /// the value (when it is `Hashable`).
    var objectIdentity: AnyHashable {
        (self as? SwiftValue)?.identity ?? AnyHashable(ObjectIdentifier(self))
    }

    /// Its fields, as a Swift struct prints them: `Job(id: 1, …)`; or its
    /// description, for an object that isn't data.
    public var debugDescription: String {
        objectFields?.debugDescription ?? description
    }
}

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

/// A function value: the interpreter implements this for Swiit functions, closures, overload sets
/// and key paths, and for a host's function as a value.
protocol Callable: AnyObject, Sendable, CustomStringConvertible {}

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
    public var debugDescription: String {
        (typeName ?? "") + "("
            + map { field in
                (Value.Record.isPosition(field.key) ? "" : "\(field.key): ")
                    + field.value.debugDescription
            }
            .joined(separator: ", ") + ")"
    }

    /// What interpolation shows: like `debugDescription`, with text unquoted.
    public var description: String {
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

extension Dictionary where Key == Swiit.Value {
    /// The entries sorted by key (`Value.displaysBefore`), so what's printed is the same every time.
    var sortedForDisplay: [(key: Key, value: Value)] {
        sorted { Key.displaysBefore($0.key, $1.key) }.map { (key: $0.key, value: $0.value) }
    }
}

extension Value {
    /// The order a dictionary's keys are shown in: only for showing, so it
    /// needn't mean anything beyond being the same every time.
    static func displaysBefore(_ a: Value, _ b: Value) -> Bool {
        switch (a.storage, b.storage) {
        case (.int(let x), .int(let y)): return x < y
        case (.int, .double), (.double, .int), (.double, .double):
            return a.displayNumber! < b.displayNumber!
        case (.string(let x), .string(let y)): return x < y
        case (.bool(let x), .bool(let y)): return !x && y
        case (.enumValue(let x), .enumValue(let y)) where x.type === y.type && x.index != y.index:
            return x.index < y.index
        default:
            return a.debugDescription < b.debugDescription
        }
    }

    private var displayNumber: Double? {
        switch self.storage {
        case .int(let n): Double(n)
        case .double(let d): d
        default: nil
        }
    }
}

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
        case (.object(let a), .object(let b)): a === b || a.objectIdentity == b.objectIdentity
        case (.function(let a), .function(let b)): a === b
        default: false
        }
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

extension Value: CustomStringConvertible {
    public var description: String {
        switch self.storage {
        case .nothing: ""
        case .bool(let value): String(value)
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .list(let values): "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .tuple(let tuple): tuple.description
        case .structure(let structure): structure.description
        case .dictionary(let dictionary): dictionary.description
        case .enumValue(let value): value.description
        case .object(let object): object.description
        case .function(let function): function.description
        }
    }

}

extension Value {
    /// A string as a literal: quotes, backslashes and control characters
    /// escaped. Like Swift's `debugDescription`, but a `'` stays as it is.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

extension Value: CustomDebugStringConvertible {
    /// As Swift's `debugPrint` shows it, and as the prompt shows a bare
    /// value: strings quoted, cases with their type, outputs and records
    /// with their fields.
    public var debugDescription: String {
        switch self.storage {
        case .nothing: "nil"
        case .string(let value): Value.quoted(value)
        case .list(let values): "[" + values.map(\.debugDescription).joined(separator: ", ") + "]"
        case .tuple(let tuple): tuple.debugDescription
        case .structure(let structure): structure.debugDescription
        case .dictionary(let dictionary): dictionary.debugDescription
        case .enumValue(let value): value.debugDescription
        case .object(let object): object.debugDescription
        default: description
        }
    }
}

extension Value {
    /// A date, held as the Swift value it is.
    static func date(_ date: Date) -> Value {
        SwiftValue.make(date, as: "Date")
    }

    /// The date it holds, if it's one.
    var date: Date? {
        if case .object(let box as SwiftValue) = self.storage { box.value as? Date } else { nil }
    }
}

/// A mutating member's receiver, moved out of its variable for the call: nothing else holds the
/// value while the member changes it, so a collection is changed where it is, not copied whole each
/// time. The member's glue takes it out, and puts it back, changed, however the call ends.
final class ReceiverBox: LanguageObject, @unchecked Sendable {  // safe: its state is touched only holding the interpreter lock
    public var value: Value
    public init(_ value: Value) { self.value = value }

    /// The box, if `value` is one.
    public static func of(_ value: Value) -> ReceiverBox? {
        if case .object(let box as ReceiverBox) = value.storage { box } else { nil }
    }

    /// What it holds, leaving it empty: the caller then holds the only reference.
    public func take() -> Value {
        let taken = value
        value = .nothing
        return taken
    }

    public func put(_ changed: Value) { value = changed }

    public var typeName: String { "receiver" }
    public var memberNames: [String] { [] }
    public func member(_ name: String) -> Value? { nil }
    public var description: String { "\(value)" }
}

// MARK: Making and reading values

extension Value: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: Value...) { self = .list(elements) }
    public init(dictionaryLiteral elements: (Value, Value)...) {
        self = .dictionary(Dictionary(elements, uniquingKeysWith: { $1 }))
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

    /// A described function as a value, for a host object's method to give: `.function(...)` of its
    /// own making.
    public init(_ function: HostSymbol) {
        precondition(
            function.function != nil,
            "\(function.name) is a member of a type, not a function"
        )
        self = .function(NativeFunction(function))
    }

    /// A key path: `Value(keyPath: ["owner", "name"])` is `\.owner.name`, which reads the members
    /// in turn from a value and is a function of it where one is wanted, as in `xs.map(\.name)`.
    public init(keyPath path: [String]) {
        self = .function(KeyPathValue(path: path))
    }

    /// Any `Encodable` as a value: a struct, a list, a string. A struct is of a host type named for
    /// its Swift type, or of `type` if one is given.
    public init(encoding value: some Encodable, as type: Symbol.ID? = nil) throws {
        self = try ValueEncoder().encode(value)
        if let type, var record = record {
            record.typeID = type
            self = Value(record: record)
        }
    }

}

// MARK: What a host does with a value

extension Value {
    /// A Swift value as a value: a number, text, a list, a dictionary, an optional, or any type that
    /// says scripts can have it (`extension URL: ScriptConvertible {}`).
    public init<T: ScriptConvertible>(_ value: T) { self = value.value }

    /// What a value is made of, as the interpreter says it. A host asks `typeID`, `isInstance(of:)`
    /// and the views (`tuple`, `structure`, `enumCase`, `function`) instead, and makes its own
    /// taxonomy of them if it wants one to switch over.
    enum Kind: Sendable {
        case nothing, bool, int, double, string, list, dictionary
        case tuple, structure, enumeration, function, object
    }

    var kind: Kind {
        switch self.storage {
        case .nothing: .nothing
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .list: .list
        case .dictionary: .dictionary
        case .tuple: .tuple
        case .structure: .structure
        case .enumValue: .enumeration
        case .function: .function
        case .object: .object
        }
    }

    /// The type the value is of, as an ID: a script's struct, enum or class by its declaration's,
    /// a Swift type's by its name, and `Int`, `String`, `Array`, `Optional` (for `nil`) and the
    /// rest of Swift's own. Nil for a tuple or a function, which no type declares. The ID may name
    /// nothing the interpreter knows (an encoded Swift value's), and `Interpreter.symbol(for:)`
    /// then gives nil.
    public var typeID: Symbol.ID? {
        switch self.storage {
        case .nothing: .optional
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .list: .array
        case .dictionary: .dictionary
        case .tuple, .function: nil
        case .structure(let structure): structure.id
        case .enumValue(let value): value.type.id
        case .object(let object):
            if let instance = object as? ClassInstance {
                instance.type.id
            } else if let box = object as? SwiftValue {
                .host(box.typeName)
            } else if object is any LanguageObject {
                nil
            } else {
                .host(object.typeName)
            }
        }
    }

    /// Whether the value is an instance of the type `id` names: of exactly that type, of a class
    /// that inherits from it, or `Any`, as Swift's `is` says. A struct value that came from a
    /// Swift value (an encoded one, or one a host built by the type's name) also counts as an
    /// instance of a type a script declares of the same name, which members and display already
    /// treat it as. A protocol it conforms to is not asked here, since that takes an
    /// interpreter: `ScriptType.conforms(to:in:)` is.
    public func isInstance(of id: Symbol.ID) -> Bool {
        if id == .any { return true }
        if case .function = self.storage { return id == .function }
        guard let own = typeID else { return false }
        if own == id { return true }
        if case .structure(let structure) = self.storage, case .host = own.kind,
            case .declared = id.kind, structure.typeName == id.name
        {
            return true
        }
        if case .object(let object) = self.storage, let instance = object as? ClassInstance {
            var type = instance.type.superclass
            while let current = type {
                if current.id == id { return true }
                type = current.superclass
            }
        }
        return false
    }

    /// Whether the value is an instance of the Swift type `T`, as `casting(to:)` says.
    public func isInstance<T: ScriptConvertible>(of type: T.Type) -> Bool {
        casting(to: type) != nil
    }

    /// The value as a `T` if it is one: strict, as `as?` is. An `Int` is not a `Double`, and a list
    /// casts only if every element does. `try T(value)` is the throwing form, and converts as a
    /// script's call does.
    public func casting<T: ScriptConvertible>(to type: T.Type = T.self) -> T? {
        // The plain ones, which a host asks per item, without building a value to compare.
        switch storage {
        case .int(let value) where T.self == Int.self: return value as? T
        case .string(let value) where T.self == String.self: return value as? T
        case .bool(let value) where T.self == Bool.self: return value as? T
        case .double(let value) where T.self == Double.self: return value as? T
        case .list(let value) where T.self == [Value].self: return value as? T
        case _ where T.self == Value.self: return self as? T
        // A Swift value or object a script holds as it is, when it is a `T`.
        case .object(let box as SwiftValue): if let held = box.value as? T { return held }
        default: break
        }
        guard let result = try? T(self), result.value == self else { return nil }
        return result
    }

    /// What the value is, as a type that is no concrete one: a protocol (`any Presentable`) or `Any`.
    /// A Swift value or object a script holds as it is, if it conforms; a number, text or a flag, as
    /// the Swift value it is. Nil otherwise, and never a conversion: `casting(to:)` converts.
    public func casting<T>(toExistential type: T.Type) -> T? {
        switch storage {
        case .object(let box as SwiftValue): return box.value as? T
        case .object(let object): return object as? T
        case .int(let value): return value as? T
        case .double(let value): return value as? T
        case .bool(let value): return value as? T
        case .string(let text): return text as? T
        default: return nil
        }
    }

    /// The value itself if it is of that script type (a struct or enum by name, a list of ints, an
    /// optional string), else nil.
    public func casting(to type: ScriptType) -> Value? {
        matches(type) ? self : nil
    }

    private func matches(_ type: ScriptType) -> Bool {
        switch type {
        case .named("Any", _): return true
        case .named("Bool", _): return kind == .bool
        case .named("Int", _): return kind == .int
        case .named("Double", _): return kind == .double
        case .named("String", _): return kind == .string
        case .named("Function", _), .function: return kind == .function
        case .named("Optional", let arguments):
            return self == .nothing || arguments.first.map(matches) ?? true
        case .named("Array", let arguments):
            guard case .list(let items) = self.storage else { return false }
            return items.allSatisfy { arguments.first.map($0.matches) ?? true }
        case .named("Dictionary", let arguments):
            guard case .dictionary(let dictionary) = self.storage, arguments.count == 2 else {
                return kind == .dictionary
            }
            return dictionary.allSatisfy {
                $0.key.matches(arguments[0]) && $0.value.matches(arguments[1])
            }
        case .named(let name, _):
            switch self.storage {
            case .structure(let structure): return structure.id == name
            case .enumValue(let value): return value.type.id == name
            case .object: return typeID == name
            default: return false
            }
        case .tuple(let elements):
            guard case .tuple(let tuple) = self.storage, tuple.count == elements.count
            else {
                return false
            }
            return zip(tuple, elements)
                .allSatisfy { field, element in
                    (element.label == nil || element.label == field.key)
                        && field.value.matches(element.type)
                }
        }
    }

    /// The case of an enum, if this is one.
    var enumCase: Value.EnumCase? {
        if case .enumValue(let value) = self.storage { value } else { nil }
    }
}

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
