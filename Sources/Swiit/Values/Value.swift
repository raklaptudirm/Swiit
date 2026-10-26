import Foundation

/// A value flowing through Swiit.
///
/// This is the currency shared by the interpreter and its hosts,
/// which is why it lives in its own dynamic library.
public enum Value: Sendable {
    // The representation is the interpreter's and the host's (SPI). A host builds a value with its
    // initializers and literals and reads one with `kind`, `cast(to:)`, `entries` and `enumCase`,
    // so a new representation never breaks it.
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
    case dictionary(Value.Dictionary)
    /// A case of an enum: `.directory`, or `.failed(code: 2)`.
    case enumValue(Value.EnumCase)
    /// A live value with members of its own: a background job, an enum type,
    /// and later bridged Swift objects.
    case object(any HostObject)
    case function(any Callable)
}

/// A live object a host hands scripts. Its members are the ones its `HostType` registers, which
/// the checker reads, so a script's use of one is checked before it runs; `member(_:)` is for the
/// few a host answers for at run time. Objects compare by identity.
public protocol HostObject: AnyObject, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// The name `members` and error messages use, like `Job`.
    var typeName: String { get }
    /// Names of its members, for `members` and completion.
    var memberNames: [String] { get }
    /// A member answered at run time, after the registered ones; nil if there is none. Optional:
    /// most objects have only the registered members.
    func member(_ name: String) -> Value?
}

/// An object the language makes itself (an instance, a type, a weak reference, a Swift value held
/// as it is), as opposed to one a host hands in. The checker types the language's by what they are,
/// and a host's by the protocol the host declares for them.
protocol LanguageObject: HostObject {}

extension HostObject {
    /// The registered members of its type, unless it says.
    public var memberNames: [String] {
        var seen = Set<String>()
        return (Bridge.types[typeName]?.members ?? [])
            .filter { !$0.isStatic && ($0.kind == .method || $0.kind == .property) }
            .map(\.name).filter { seen.insert($0).inserted }
    }

    /// The registered members of its type: a property is read, a method is a function bound to the
    /// object.
    public func member(_ name: String) -> Value? {
        guard
            let member = Bridge.types[typeName]?.members
                .first(where: { $0.name == name && !$0.isStatic && !$0.isMutating }),
            let plain = member.plain
        else { return nil }
        let receiver = Value(self)
        switch member.kind {
        case .property: return try? plain(["self": receiver])
        case .method:
            return Value(
                HostFunction(
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

    /// Its data as named fields, which tables, `select` and `to json` use: every member that isn't
    /// a method. What the language makes itself (a type, an instance, a Swift value held as it is)
    /// has none: it is one value, like a `FileSize`.
    var dataFields: Value.Dictionary? {
        if self is any LanguageObject { return nil }
        var fields = Value.Dictionary()
        for name in memberNames {
            guard let value = member(name) else { continue }
            if case .function = value { continue }
            fields[Value.string(name)] = value
        }
        return fields
    }

    /// `dataFields` as the language's record of the object's type.
    var objectFields: Value.Record? {
        guard let fields = dataFields else { return nil }
        var record = Value.Record(typeName: typeName)
        for (key, value) in fields { if case .string(let name) = key { record[name] = value } }
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
        switch self {
        case .tuple(let tuple): tuple.record
        case .structure(let structure): structure.record
        case .object(let object): object.objectFields
        default: nil
        }
    }
}

/// A function value. The interpreter implements this for Swiit functions and
/// closures; hosts implement it for Swift functions.
public protocol Callable: AnyObject, Sendable, CustomStringConvertible {}

extension Value {
    /// The fields a tuple or a struct value keeps, in order, with the struct's type name. Two are
    /// equal when they have the same fields in the same order; a `Tuple` and a `Structure` add what
    /// else equality asks of them.
    struct Record: Sendable, Hashable, Sequence {
        private(set) var keys: [String] = []
        fileprivate var storage: [String: Value] = [:]
        /// The Swift type it came from, like `FileEntry`, which picks how it's displayed; nil for a
        /// tuple.
        var typeName: String?

        init(typeName: String? = nil) {
            self.typeName = typeName
        }

        init(_ fields: KeyValuePairs<String, Value>, typeName: String? = nil) {
            self.typeName = typeName
            for (key, value) in fields { self[key] = value }
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
    public struct Tuple: Sendable, Hashable, Sequence, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        var record: Value.Record

        init(_ record: Value.Record) { self.record = record }

        public init() { record = Value.Record() }

        public var keys: [String] { record.keys }
        public var count: Int { record.count }
        public var isEmpty: Bool { record.isEmpty }

        public subscript(key: String) -> Value? {
            get { record[key] }
            set { record[key] = newValue }
        }

        public func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
            record.makeIterator()
        }

        public var description: String { record.description }
        public var debugDescription: String { record.debugDescription }
    }

    /// A struct's value: the name of its type, and its fields in order. Two are equal when they are
    /// of the type of one name and their fields are equal in order.
    public struct Structure: Sendable, Hashable, Sequence, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        var record: Value.Record

        init(_ record: Value.Record) { self.record = record }

        public init(typeName: String) { record = Value.Record(typeName: typeName) }

        /// The Swift type it came from, like `FileEntry`, which picks how it's displayed.
        public var typeName: String { record.typeName ?? "" }

        public var keys: [String] { record.keys }
        public var count: Int { record.count }
        public var isEmpty: Bool { record.isEmpty }

        public subscript(key: String) -> Value? {
            get { record[key] }
            set { record[key] = newValue }
        }

        public func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
            record.makeIterator()
        }

        public var description: String { record.description }
        public var debugDescription: String { record.debugDescription }
    }

    /// The fields of a tuple or of a struct value, with the struct's type name.
    var record: Record? {
        switch self {
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
    /// Swift's `[Value: Value]`: iterating it goes in Swift's order, which is
    /// no particular one and changes from run to run. Shown, it's sorted by key
    /// (`sortedForDisplay`), so what's printed is the same every time.
    public struct Dictionary: Sendable, Hashable, Sequence, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        private var storage: [Value: Value]
        /// The keys in the order they were added, which `keys`, `values` and iteration follow. Two
        /// dictionaries with the same entries are equal whatever order they were made in.
        private var order: [Value]

        public init() {
            storage = [:]
            order = []
        }

        var dictionary: [Value: Value] {
            get { storage }
            set {
                // What stays keeps its place; what is new comes after, in a fixed order.
                let added = newValue.keys.filter { storage[$0] == nil }
                    .sorted { Value.displaysBefore($0, $1) }
                order = order.filter { newValue[$0] != nil } + added
                storage = newValue
            }
        }

        init(_ dictionary: [Value: Value]) {
            storage = dictionary
            order = dictionary.keys.sorted { Value.displaysBefore($0, $1) }
        }

        /// In the order given. A later entry with the same key replaces the value of the earlier one,
        /// which keeps its place.
        public init(_ entries: [(Value, Value)]) {
            storage = [:]
            order = []
            for (key, value) in entries { self[key] = value }
        }

        public subscript(key: Value) -> Value? {
            get { storage[key] }
            set {
                if let newValue {
                    if storage.updateValue(newValue, forKey: key) == nil { order.append(key) }
                } else if storage.removeValue(forKey: key) != nil {
                    order.removeAll { $0 == key }
                }
            }
        }

        public static func == (lhs: Value.Dictionary, rhs: Value.Dictionary) -> Bool {
            lhs.storage == rhs.storage
        }
        public func hash(into hasher: inout Hasher) { hasher.combine(storage) }

        public var count: Int { storage.count }
        public var isEmpty: Bool { storage.isEmpty }
        public var keys: [Value] { order }
        public var values: [Value] { order.map { storage[$0]! } }

        public func makeIterator() -> some IteratorProtocol<(key: Value, value: Value)> {
            order.lazy.map { (key: $0, value: storage[$0]!) }.makeIterator()
        }

        /// The entries sorted by key: numbers by value, strings as Swift sorts
        /// them, an enum's cases in declared order, and anything else by how
        /// it's written.
        public var sortedForDisplay: [(key: Value, value: Value)] {
            storage.sorted { Value.displaysBefore($0.key, $1.key) }
        }

        public var debugDescription: String {
            guard !isEmpty else { return "[:]" }
            return "["
                + sortedForDisplay.map {
                    "\($0.key.debugDescription): \($0.value.debugDescription)"
                }
                .joined(separator: ", ") + "]"
        }

        public var description: String { debugDescription }
    }
}

extension Value {
    /// The order a dictionary's keys are shown in: only for showing, so it
    /// needn't mean anything beyond being the same every time.
    static func displaysBefore(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
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
        switch self {
        case .int(let n): Double(n)
        case .double(let d): d
        default: nil
        }
    }
}

extension Value: Hashable {
    /// Functions compare by identity.
    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
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
        switch self {
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
        switch self {
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
        switch self {
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
        if case .object(let box as SwiftValue) = self { box.value as? Date } else { nil }
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
        if case .object(let box as ReceiverBox) = value { box } else { nil }
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
        self = .dictionary(Value.Dictionary(elements))
    }
}

extension Value {
    /// The entries of a structured value in order: a dictionary's, the fields of a tuple or a
    /// struct value by name (a tuple's unlabeled ones by position, "0", "1"), or the fields of a
    /// host's object that is data. Nil for any other value.
    public var entries: Value.Dictionary? {
        switch self {
        case .dictionary(let dictionary): dictionary
        case .tuple, .structure:
            Value.Dictionary(record!.map { (Value.string($0.key), $0.value) })
        case .object(let object): object.dataFields
        default: nil
        }
    }

    /// The items it gives as they come, which reading can fail on: a `ThrowingStream`'s, or a task group's.
    /// Nil for anything else.
    public var throwingStream: ThrowingStream<Value>? { Interpreter.throwingStream(of: self) }

    /// The items of a list or of a Swift sequence a script holds (a set, a range of Ints, a host
    /// type's text, a flow), one at a time, so a range of a billion never becomes a list; nil for
    /// anything else.
    public var items: AnySequence<Value>? {
        guard Interpreter.items(of: self) != nil else { return nil }
        return AnySequence { Interpreter.items(of: self)! }
    }

    /// A described function as a value, for a host object's method to give: `.function(...)` of its
    /// own making.
    public init(_ function: HostFunction) {
        self = .function(NativeFunction(function))
    }

    /// A struct's value, with its fields in order and every one present (an absent optional is
    /// `nil`): `Value(struct: "Point", fields: ["x": Value(1), "y": Value(2)])`.
    public init(struct typeName: String, fields: KeyValuePairs<String, Value>) {
        self = .structure(Structure(Value.Record(fields, typeName: typeName)))
    }

    /// As above, for fields whose names are known only as the program runs: a parsed object's keys.
    public init(struct typeName: String, fields: [(name: String, value: Value)]) {
        var record = Value.Record(typeName: typeName)
        for (name, value) in fields { record[name] = value }
        self = .structure(Structure(record))
    }

    /// A tuple, with the names of its elements in order (the unlabeled ones by position, `"0"`):
    /// `Value(tuple: ["name": Value("x"), "size": Value(2)])`.
    public init(tuple fields: KeyValuePairs<String, Value>) {
        self = .tuple(Tuple(Value.Record(fields)))
    }

    /// As above, for names known only as the program runs.
    public init(tuple fields: [(name: String, value: Value)]) {
        var record = Value.Record()
        for (name, value) in fields { record[name] = value }
        self = .tuple(Tuple(record))
    }

    /// Any `Encodable` as a value: a struct, a list, a string. A struct is named for its Swift
    /// type, or `name` if one is given.
    public init(encoding value: some Encodable, as name: String? = nil) throws {
        self = try ValueEncoder().encode(value)
        if let name, var record = record {
            record.typeName = name
            self = Value(record: record)
        }
    }

}

// MARK: What a host does with a value

extension Value {
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: Int) { self = .int(value) }
    public init(_ value: Double) { self = .double(value) }
    public init(_ value: String) { self = .string(value) }
    public init(_ value: [Value]) { self = .list(value) }
    public init(_ value: Value.Dictionary) { self = .dictionary(value) }
    public init(_ value: some HostObject) { self = .object(value) }

    /// What a value is, as a script would say it. A tuple and a struct value are told apart by
    /// whether the type has a name.
    public enum Kind: Sendable {
        case nothing, bool, int, double, string, list, dictionary
        case tuple, structure, enumeration, function, object
    }

    public var kind: Kind {
        switch self {
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

    /// The value as a `T` if it is one: strict, as `as?` is. An `Int` is not a `Double`, and a list
    /// casts only if every element does. `try T(value)` is the throwing form, and converts as a
    /// script's call does.
    public func cast<T: ScriptConvertible>(to type: T.Type = T.self) -> T? {
        guard let result = try? T(self), result.value == self else { return nil }
        return result
    }

    /// The host's own object, if this is one of that class.
    public func cast<T: HostObject>(to type: T.Type) -> T? {
        guard case .object(let object) = self else { return nil }
        return object as? T
    }

    /// The value itself if it is of that script type (a struct or enum by name, a list of ints, an
    /// optional string), else nil.
    public func cast(to type: ScriptType) -> Value? {
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
            guard case .list(let items) = self else { return false }
            return items.allSatisfy { arguments.first.map($0.matches) ?? true }
        case .named("Dictionary", let arguments):
            guard case .dictionary(let dictionary) = self, arguments.count == 2 else {
                return kind == .dictionary
            }
            return dictionary.allSatisfy {
                $0.key.matches(arguments[0]) && $0.value.matches(arguments[1])
            }
        case .named(let name, _):
            switch self {
            case .structure(let structure): return structure.typeName == name
            case .enumValue(let value): return value.type.name == name
            case .object(let object): return object.typeName == name
            default: return false
            }
        case .tuple(let elements):
            guard case .tuple(let tuple) = self, tuple.count == elements.count
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

    /// The raw value of a script enum's case, if its type has them.
    public var rawValue: Value? {
        guard case .enumValue(let value) = self else { return nil }
        return value.rawValue
    }

    /// The case of a script enum: its type's name, the case's name, its payload and the labels the
    /// payload is declared with.
    public var enumCase: (type: String, name: String, values: [Value], labels: [String?])? {
        guard case .enumValue(let value) = self else { return nil }
        return (value.type.name, value.name, value.values, value.definition?.labels ?? [])
    }
}
